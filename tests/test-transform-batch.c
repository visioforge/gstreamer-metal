/* vfmetaltransform: the method and the crops written in one batch (one
 * g_object_set() call, or between g_object_freeze_notify() and
 * g_object_thaw_notify()) take effect together. A buffer that arrives
 * between two writes of the batch keeps the old output size; it never
 * renegotiates to a half-applied state. A single write still takes effect
 * on the next buffer.
 *
 * GstHarness pushes on the calling thread, so the buffer "in the gap" is
 * deterministic. Exit code 0 means every check passed. */

#include <stdio.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>

static int failures = 0;

/* Pushes one 1920x1080 BGRA frame and returns the width it came out at. */
static gint
push_and_get_width (GstHarness * h)
{
  GstBuffer *in = gst_harness_create_buffer (h, 1920 * 1080 * 4);
  if (gst_harness_push (h, in) != GST_FLOW_OK)
    return -1;

  GstBuffer *out = gst_harness_pull (h);
  if (!out)
    return -1;
  gst_buffer_unref (out);

  GstCaps *caps = gst_pad_get_current_caps (h->sinkpad);
  gint width = -1;
  if (caps) {
    gst_structure_get_int (gst_caps_get_structure (caps, 0), "width", &width);
    gst_caps_unref (caps);
  }
  return width;
}

static void
check_width (const char *what, gint actual, gint expected)
{
  if (actual == expected) {
    printf ("  PASS  %s: %d\n", what, actual);
  } else {
    printf ("  FAIL  %s: %d, expected %d\n", what, actual, expected);
    failures++;
  }
}

int
main (int argc, char **argv)
{
  gst_init (&argc, &argv);

  GstHarness *h = gst_harness_new ("vfmetaltransform");
  gst_harness_set_src_caps_str (h,
      "video/x-raw,format=BGRA,width=1920,height=1080,framerate=30/1");

  g_object_set (h->element, "crop-left", 100, NULL);
  check_width ("crop-left=100", push_and_get_width (h), 1820);

  /* Move the crop from the left edge to the right one: same size. */
  g_object_freeze_notify (G_OBJECT (h->element));
  g_object_set (h->element, "crop-left", 0, NULL);
  check_width ("buffer between two writes of a batch",
      push_and_get_width (h), 1820);
  g_object_set (h->element, "crop-right", 100, NULL);
  g_object_thaw_notify (G_OBJECT (h->element));
  check_width ("after the batch", push_and_get_width (h), 1820);

  /* Both writes in one g_object_set() call. */
  g_object_set (h->element, "crop-right", 0, "crop-left", 100, NULL);
  check_width ("one g_object_set() call", push_and_get_width (h), 1820);

  /* A single write is its own batch and renegotiates. */
  g_object_set (h->element, "crop-left", 0, NULL);
  check_width ("single write", push_and_get_width (h), 1920);

  gst_harness_teardown (h);

  printf (failures ? "=== FAILED ===\n" : "=== PASSED ===\n");
  return failures ? 1 : 0;
}
