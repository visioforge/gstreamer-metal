/* vfmetaloverlay: a position and a size written in one batch (between
 * g_object_freeze_notify() and g_object_thaw_notify()) take effect
 * together. A buffer that arrives between two writes of the batch is drawn
 * with the old rectangle; it never shows the new position with the old size.
 *
 * GstHarness pushes on the calling thread, so the buffer "in the gap" is
 * deterministic. argv[1] is a solid red PNG, argv[2] a path that does not
 * exist yet. Exit code 0 means every check passed.
 *
 * Also: the image survives a restart (READY and back), and a location whose
 * load failed is loaded again when it is written again. */

#include <stdio.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>
#include <glib/gstdio.h>

#define W 64
#define H 64

static int failures = 0;

/* Pushes one black BGRA frame; returns the output, or NULL. */
static GstBuffer *
push_black (GstHarness * h)
{
  GstBuffer *in = gst_harness_create_buffer (h, W * H * 4);
  gst_buffer_memset (in, 0, 0, W * H * 4);
  if (gst_harness_push (h, in) != GST_FLOW_OK)
    return NULL;
  return gst_harness_pull (h);
}

static gboolean
is_red (GstBuffer * buf, int x, int y)
{
  guint8 px[4];
  gst_buffer_extract (buf, (y * W + x) * 4, px, 4);
  return px[2] > 200 && px[0] < 50 && px[1] < 50;
}

static void
check (const char *what, GstBuffer * buf, int x, int y, gboolean red)
{
  gboolean actual = buf && is_red (buf, x, y);
  if (actual == red) {
    printf ("  PASS  %s: (%d,%d) %s\n", what, x, y, red ? "red" : "black");
  } else {
    printf ("  FAIL  %s: (%d,%d) expected %s\n", what, x, y,
        red ? "red" : "black");
    failures++;
  }
}

int
main (int argc, char **argv)
{
  gst_init (&argc, &argv);
  if (argc < 3) {
    printf ("usage: %s <red.png> <missing.png>\n", argv[0]);
    return 2;
  }

  GstHarness *h = gst_harness_new ("vfmetaloverlay");
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");

  g_object_set (h->element, "location", argv[1], "x", 0, "y", 0,
      "width", 16, "height", 16, NULL);
  GstBuffer *out = push_black (h);
  check ("16x16 at 0,0", out, 8, 8, TRUE);
  check ("16x16 at 0,0", out, 40, 40, FALSE);
  gst_clear_buffer (&out);

  /* Move to 32,32 and grow to 24x24: the rectangle 32..56. */
  g_object_freeze_notify (G_OBJECT (h->element));
  g_object_set (h->element, "x", 32, "y", 32, NULL);
  out = push_black (h);
  check ("buffer between two writes of a batch", out, 8, 8, TRUE);
  check ("buffer between two writes of a batch", out, 40, 40, FALSE);
  gst_clear_buffer (&out);
  g_object_set (h->element, "width", 24, "height", 24, NULL);
  g_object_thaw_notify (G_OBJECT (h->element));

  out = push_black (h);
  check ("after the batch", out, 8, 8, FALSE);
  check ("after the batch", out, 52, 52, TRUE);
  gst_clear_buffer (&out);

  /* A single write is its own batch and applies on the next buffer. */
  g_object_set (h->element, "x", 0, NULL);
  out = push_black (h);
  check ("single write", out, 8, 40, TRUE);
  gst_clear_buffer (&out);

  /* A restart keeps the image: the same location is not loaded again. */
  gst_element_set_state (h->element, GST_STATE_READY);
  gst_element_set_state (h->element, GST_STATE_PLAYING);
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");
  g_object_set (h->element, "location", argv[1], NULL);
  out = push_black (h);
  check ("after a restart", out, 8, 40, TRUE);
  gst_clear_buffer (&out);

  /* A location that failed to load is tried again when written again. */
  g_object_set (h->element, "location", argv[2], NULL);
  out = push_black (h);
  check ("missing file", out, 8, 40, FALSE);
  gst_clear_buffer (&out);
  gchar *png = NULL;
  gsize len = 0;
  if (!g_file_get_contents (argv[1], &png, &len, NULL) ||
      !g_file_set_contents (argv[2], png, len, NULL)) {
    printf ("  FAIL  could not write %s\n", argv[2]);
    failures++;
  }
  g_free (png);
  g_object_set (h->element, "location", argv[2], NULL);
  out = push_black (h);
  check ("the same location once the file exists", out, 8, 40, TRUE);
  gst_clear_buffer (&out);
  g_unlink (argv[2]);

  gst_harness_teardown (h);

  printf (failures ? "=== FAILED ===\n" : "=== PASSED ===\n");
  return failures ? 1 : 0;
}
