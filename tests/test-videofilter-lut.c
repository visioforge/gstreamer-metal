/* vfmetalvideofilter: a lut-file written while the element is streaming
 * takes effect on the next buffer. The file is read on the writing thread;
 * the renderer installs the texture on the streaming thread, before a frame
 * (visioforge/MediaFrameworkDotnet#3508).
 *
 * A white frame goes through an inverting 2x2x2 .cube LUT and comes out
 * black. A path that fails to load keeps the LUT already in use; an empty
 * path drops it. saturation=2 keeps the element out of passthrough (it
 * leaves white white), so every frame goes through the renderer. Exit code
 * 0 means every check passed.
 *
 * With every other property at its default, passthrough follows the LUT in
 * use, not the path: a path that fails to load leaves the element in
 * passthrough (#3520), and one that fails after a good LUT keeps it out.
 *
 * GstHarness pushes on the calling thread, so this proves the LUT reaches
 * the renderer, not that the old cross-thread race is gone: that race is not
 * reproducible deterministically.
 *
 * A clear that turns passthrough on releases the old LUT texture with the
 * next buffer, although no frame is rendered (measured as GPU memory). */

#include <stdio.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>
#include <gst/base/gstbasetransform.h>
#include <glib/gstdio.h>
#include <unistd.h>
#import <Metal/Metal.h>

#define W 64
#define H 64

static int failures = 0;

/* Pushes one white frame and returns the RGB of its first pixel as
 * 0xRRGGBB, or -1 on failure. */
static gint
push_and_get_rgb (GstHarness * h)
{
  GstBuffer *in = gst_harness_create_buffer (h, W * H * 4);
  gst_buffer_memset (in, 0, 0xFF, W * H * 4);
  if (gst_harness_push (h, in) != GST_FLOW_OK)
    return -1;

  GstBuffer *out = gst_harness_pull (h);
  if (!out)
    return -1;

  guint8 px[4] = { 0 };
  gst_buffer_extract (out, 0, px, 4);
  gst_buffer_unref (out);

  /* BGRA */
  return (px[2] << 16) | (px[1] << 8) | px[0];
}

static void
check_rgb (const char *what, gint actual, gint expected)
{
  if (actual == expected) {
    printf ("  PASS  %s: 0x%06X\n", what, actual);
  } else {
    printf ("  FAIL  %s: 0x%06X, expected 0x%06X\n", what, actual, expected);
    failures++;
  }
}

/* Bytes allocated on every Metal device: the element picks one itself */
static guint64
gpu_bytes (void)
{
  guint64 total = 0;
  for (id<MTLDevice> dev in MTLCopyAllDevices ())
    total += dev.currentAllocatedSize;
  return total;
}

static void
check_passthrough (const char *what, GstHarness * h, gboolean expected)
{
  gboolean actual = gst_base_transform_is_passthrough (
      GST_BASE_TRANSFORM (h->element));
  if (actual == expected) {
    printf ("  PASS  %s: passthrough %s\n", what, actual ? "on" : "off");
  } else {
    printf ("  FAIL  %s: passthrough %s, expected %s\n", what,
        actual ? "on" : "off", expected ? "on" : "off");
    failures++;
  }
}

int
main (int argc, char **argv)
{
  gst_init (&argc, &argv);

  gchar *name = g_strdup_printf ("vfmetal-invert-%d.cube", (int) getpid ());
  gchar *lut = g_build_filename (g_get_tmp_dir (), name, NULL);
  g_free (name);
  name = g_strdup_printf ("vfmetal-missing-%d.cube", (int) getpid ());
  gchar *missing = g_build_filename (g_get_tmp_dir (), name, NULL);
  g_free (name);
  name = g_strdup_printf ("vfmetal-big-%d.cube", (int) getpid ());
  gchar *big = g_build_filename (g_get_tmp_dir (), name, NULL);
  g_free (name);
  name = g_strdup_printf ("vfmetal-late-%d.cube", (int) getpid ());
  gchar *late = g_build_filename (g_get_tmp_dir (), name, NULL);
  g_free (name);
  FILE *f = fopen (lut, "w");
  if (!f) {
    printf ("  FAIL  cannot write %s\n", lut);
    return 1;
  }
  fprintf (f, "LUT_3D_SIZE 2\n");
  for (int b = 0; b < 2; b++)
    for (int g = 0; g < 2; g++)
      for (int r = 0; r < 2; r++)
        fprintf (f, "%d %d %d\n", 1 - r, 1 - g, 1 - b);
  fclose (f);
  /* An identity 64^3 LUT: at least 1 MB of texture, white stays white */
  f = fopen (big, "w");
  if (!f) {
    printf ("  FAIL  cannot write %s\n", big);
    return 1;
  }
  fprintf (f, "LUT_3D_SIZE 64\n");
  for (int b = 0; b < 64; b++)
    for (int g = 0; g < 64; g++)
      for (int r = 0; r < 64; r++)
        fprintf (f, "%f %f %f\n", r / 63.0, g / 63.0, b / 63.0);
  fclose (f);
  g_remove (missing);
  g_remove (late);

  GstHarness *h = gst_harness_new ("vfmetalvideofilter");
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");
  g_object_set (h->element, "saturation", 2.0, NULL);

  check_rgb ("no LUT", push_and_get_rgb (h), 0xFFFFFF);

  g_object_set (h->element, "lut-file", lut, NULL);
  check_rgb ("LUT set while streaming", push_and_get_rgb (h), 0x000000);

  g_object_set (h->element, "lut-file", missing, NULL);
  check_rgb ("a LUT that fails to load keeps the old one",
      push_and_get_rgb (h), 0x000000);

  g_object_set (h->element, "lut-file", "", NULL);
  check_rgb ("LUT cleared while streaming", push_and_get_rgb (h), 0xFFFFFF);

  gst_harness_teardown (h);

  /* Every other property at its default: only the LUT can leave passthrough */
  h = gst_harness_new ("vfmetalvideofilter");
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");

  g_object_set (h->element, "lut-file", missing, NULL);
  check_passthrough ("a LUT that fails to load, none before", h, TRUE);

  g_object_set (h->element, "lut-file", lut, NULL);
  check_passthrough ("LUT loaded", h, FALSE);
  check_rgb ("LUT loaded, defaults", push_and_get_rgb (h), 0x000000);

  g_object_set (h->element, "lut-file", missing, NULL);
  check_passthrough ("a LUT that fails to load after a good one", h, FALSE);
  check_rgb ("the old LUT stays, defaults", push_and_get_rgb (h), 0x000000);

  g_object_set (h->element, "lut-file", "", NULL);
  check_passthrough ("LUT cleared", h, TRUE);

  g_object_set (h->element, "lut-file", missing, NULL);
  check_passthrough ("a LUT that fails to load after a clear", h, TRUE);

  /* The clear was staged while in passthrough; the first rendered frame
   * applies it before drawing. brightness leaves white white. */
  g_object_set (h->element, "brightness", 0.1, NULL);
  check_passthrough ("brightness set", h, FALSE);
  check_rgb ("the staged clear is applied", push_and_get_rgb (h), 0xFFFFFF);

  /* A path that failed is read again only when lut-file itself is written:
   * the file appears afterwards, an unrelated write leaves it unread. */
  if (g_file_test (late, G_FILE_TEST_EXISTS)) {
    printf ("  FAIL  %s exists before the test writes it\n", late);
    failures++;
  }
  g_object_set (h->element, "lut-file", late, NULL);
  gchar *cube = NULL;
  gsize cube_len = 0;
  if (g_file_get_contents (lut, &cube, &cube_len, NULL) &&
      g_file_set_contents (late, cube, cube_len, NULL)) {
    g_object_set (h->element, "brightness", 0.2, NULL);
    check_rgb ("an unrelated write does not retry a failed path",
        push_and_get_rgb (h), 0xFFFFFF);
    g_object_set (h->element, "lut-file", late, NULL);
    check_rgb ("writing the failed path again retries it",
        push_and_get_rgb (h), 0x000000);
  } else {
    printf ("  FAIL  cannot write %s\n", late);
    failures++;
  }
  g_free (cube);

  gst_harness_teardown (h);

  /* A clear that turns passthrough on drops the texture with the next
   * buffer; transform_frame no longer runs to install the staged clear. */
  h = gst_harness_new ("vfmetalvideofilter");
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");
  g_object_set (h->element, "lut-file", big, NULL);
  check_rgb ("big LUT loaded", push_and_get_rgb (h), 0xFFFFFF);
  guint64 with_lut = gpu_bytes ();
  g_object_set (h->element, "lut-file", "", NULL);
  check_passthrough ("big LUT cleared", h, TRUE);
  check_rgb ("passthrough after the clear", push_and_get_rgb (h), 0xFFFFFF);
  guint64 cleared = gpu_bytes ();
  if (cleared + 512 * 1024 <= with_lut) {
    printf ("  PASS  the cleared LUT texture is released: %llu -> %llu bytes\n",
        (unsigned long long) with_lut, (unsigned long long) cleared);
  } else {
    printf ("  FAIL  the cleared LUT texture is kept: %llu -> %llu bytes\n",
        (unsigned long long) with_lut, (unsigned long long) cleared);
    failures++;
  }
  gst_harness_teardown (h);

  g_remove (lut);
  g_remove (big);
  g_free (big);
  g_remove (late);
  g_free (lut);
  g_free (missing);
  g_free (late);

  printf (failures ? "=== FAILED ===\n" : "=== PASSED ===\n");
  return failures ? 1 : 0;
}
