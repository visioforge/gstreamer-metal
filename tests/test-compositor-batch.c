/* vfmetalcompositor: a pad's position and size written in one batch (between
 * g_object_freeze_notify() and g_object_thaw_notify() on the pad) take effect
 * together. A frame aggregated between two writes of the batch is drawn with
 * the old rectangle; it never shows the new position with the old size
 * (MediaFrameworkDotnet#3507).
 *
 * While the pad is frozen nothing is committed, so the frame pulled in the
 * gap is deterministic even though the aggregator runs on its own thread.
 * Exit code 0 means every check passed. */

#include <stdio.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>

#define W 64
#define H 64
#define IN 16

static int failures = 0;
static GstClockTime pts = 0;

/* Pushes one red IN x IN BGRA frame; returns the composited output, or NULL. */
static GstBuffer *
push_red (GstHarness * h)
{
  GstBuffer *in = gst_harness_create_buffer (h, IN * IN * 4);
  GstMapInfo map;
  gst_buffer_map (in, &map, GST_MAP_WRITE);
  for (gsize i = 0; i < map.size; i += 4) {
    map.data[i] = 0;
    map.data[i + 1] = 0;
    map.data[i + 2] = 255;
    map.data[i + 3] = 255;
  }
  gst_buffer_unmap (in, &map);
  GST_BUFFER_PTS (in) = pts;
  GST_BUFFER_DURATION (in) = GST_SECOND / 30;
  pts += GST_SECOND / 30;
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
    printf ("  PASS  %s: (%d,%d) %s\n", what, x, y, red ? "red" : "not red");
  } else {
    printf ("  FAIL  %s: (%d,%d) expected %s\n", what, x, y,
        red ? "red" : "not red");
    failures++;
  }
}

int
main (int argc, char **argv)
{
  gst_init (&argc, &argv);

  GstHarness *h = gst_harness_new_with_padnames ("vfmetalcompositor",
      "sink_%u", "src");
  g_object_set (h->element, "background", 1 /* black */, NULL);
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=16,height=16,framerate=30/1");
  gst_harness_set_sink_caps_str (h,
      "video/x-raw,format=BGRA,width=64,height=64,framerate=30/1");

  GstPad *pad = GST_PAD_PEER (h->srcpad);
  g_object_set (pad, "xpos", 0, "ypos", 0, "width", 16, "height", 16, NULL);
  GstBuffer *out = push_red (h);
  check ("16x16 at 0,0", out, 8, 8, TRUE);
  check ("16x16 at 0,0", out, 40, 40, FALSE);
  gst_clear_buffer (&out);

  /* Move to 32,32 and grow to 24x24: the rectangle 32..56. */
  g_object_freeze_notify (G_OBJECT (pad));
  g_object_set (pad, "xpos", 32, "ypos", 32, NULL);
  out = push_red (h);
  check ("frame between two writes of a batch", out, 8, 8, TRUE);
  check ("frame between two writes of a batch", out, 40, 40, FALSE);
  gst_clear_buffer (&out);
  g_object_set (pad, "width", 24, "height", 24, NULL);
  g_object_thaw_notify (G_OBJECT (pad));

  out = push_red (h);
  check ("after the batch", out, 8, 8, FALSE);
  check ("after the batch", out, 52, 52, TRUE);
  gst_clear_buffer (&out);

  /* A single write is its own batch and applies on the next frame. */
  g_object_set (pad, "xpos", 0, NULL);
  out = push_red (h);
  check ("single write", out, 8, 40, TRUE);
  gst_clear_buffer (&out);

  /* A read-back returns what was written, committed or not. */
  gint xpos = -1;
  g_object_freeze_notify (G_OBJECT (pad));
  g_object_set (pad, "xpos", 20, NULL);
  g_object_get (pad, "xpos", &xpos, NULL);
  g_object_thaw_notify (G_OBJECT (pad));
  if (xpos == 20) {
    printf ("  PASS  read-back in a batch: xpos %d\n", xpos);
  } else {
    printf ("  FAIL  read-back in a batch: xpos %d, expected 20\n", xpos);
    failures++;
  }

  gst_harness_teardown (h);
  return failures == 0 ? 0 : 1;
}
