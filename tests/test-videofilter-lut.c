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
 * GstHarness pushes on the calling thread, so this proves the LUT reaches
 * the renderer, not that the old cross-thread race is gone: that race is not
 * reproducible deterministically. */

#include <stdio.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>
#include <glib/gstdio.h>
#include <unistd.h>

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
  g_remove (missing);

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
  g_remove (lut);
  g_free (lut);
  g_free (missing);

  printf (failures ? "=== FAILED ===\n" : "=== PASSED ===\n");
  return failures ? 1 : 0;
}
