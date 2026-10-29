/* vfmetalconvertscale: a property written while the element is streaming
 * takes effect on the next buffer. The renderer is reconfigured on the
 * streaming thread, at the top of transform, never from the thread that
 * wrote the property (visioforge/MediaFrameworkDotnet#3508).
 *
 * A white 1920x1080 frame is scaled to 640x640. Without borders the top row
 * is white; after add-borders=TRUE with a red border-color the letterbox
 * puts red there. Exit code 0 means every check passed. */

#include <stdio.h>
#include <string.h>
#include <gst/gst.h>
#include <gst/check/gstharness.h>

#define IN_W 1920
#define IN_H 1080
#define OUT_W 640
#define OUT_H 640

static int failures = 0;

/* Pushes one white frame and returns the BGRA pixel at the middle of the
 * output's top row as 0xAARRGGBB, or 0 on failure. */
static guint32
push_and_get_top_pixel (GstHarness * h)
{
  GstBuffer *in = gst_harness_create_buffer (h, IN_W * IN_H * 4);
  gst_buffer_memset (in, 0, 0xFF, IN_W * IN_H * 4);
  if (gst_harness_push (h, in) != GST_FLOW_OK)
    return 0;

  GstBuffer *out = gst_harness_pull (h);
  if (!out)
    return 0;

  guint8 px[4] = { 0 };
  gst_buffer_extract (out, (OUT_W / 2) * 4, px, 4);
  gst_buffer_unref (out);

  return ((guint32) px[3] << 24) | ((guint32) px[2] << 16) |
      ((guint32) px[1] << 8) | px[0];
}

static void
check_pixel (const char *what, guint32 actual, guint32 expected)
{
  if (actual == expected) {
    printf ("  PASS  %s: 0x%08X\n", what, actual);
  } else {
    printf ("  FAIL  %s: 0x%08X, expected 0x%08X\n", what, actual, expected);
    failures++;
  }
}

int
main (int argc, char **argv)
{
  gst_init (&argc, &argv);

  GstHarness *h = gst_harness_new ("vfmetalconvertscale");
  gst_harness_set_caps_str (h,
      "video/x-raw,format=BGRA,width=1920,height=1080,framerate=30/1",
      "video/x-raw,format=BGRA,width=640,height=640,framerate=30/1");

  check_pixel ("no borders", push_and_get_top_pixel (h), 0xFFFFFFFF);

  g_object_set (h->element, "add-borders", TRUE,
      "border-color", 0xFFFF0000, NULL);
  check_pixel ("add-borders set while streaming",
      push_and_get_top_pixel (h), 0xFFFF0000);

  g_object_set (h->element, "add-borders", FALSE, NULL);
  check_pixel ("add-borders cleared while streaming",
      push_and_get_top_pixel (h), 0xFFFFFFFF);

  gst_harness_teardown (h);

  printf (failures ? "=== FAILED ===\n" : "=== PASSED ===\n");
  return failures ? 1 : 0;
}
