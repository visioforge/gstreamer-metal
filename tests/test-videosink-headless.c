/* Headless regression for vfmetalvideosink (issue #878)
 *
 * Copyright (C) 2026 Roman Miniailov
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * The sink used to create its NSWindow with a dispatch_sync onto the main
 * queue, from the streaming thread.  A process whose main thread runs no Cocoa
 * run loop never services that queue, so the pipeline hung in preroll forever,
 * with no timeout and no error on the bus.
 *
 * This harness is deliberately NOT built on gst_macos_main(): that wrapper runs
 * NSApplication on the main thread, which services the queue and hides the
 * defect -- which is why gst-launch-1.0 cannot reproduce it.  Here the main
 * thread only waits on the bus, exactly like a test host or a console tool.
 *
 * PASS: an ERROR (headless) or EOS (a run loop happened to exist) arrives.
 * FAIL: neither arrives within the window -- that is the hang.
 */

#include <gst/gst.h>

#define WAIT_SECONDS 20

int
main (int argc, char *argv[])
{
  GstElement *pipeline;
  GstBus *bus;
  GstMessage *msg;
  int ret;

  gst_init (&argc, &argv);

  pipeline = gst_parse_launch ("videotestsrc num-buffers=30 ! "
      "video/x-raw,format=BGRA,width=320,height=240 ! vfmetalvideosink", NULL);
  if (pipeline == NULL) {
    g_printerr ("FAIL: could not build the pipeline\n");
    return 1;
  }

  bus = gst_element_get_bus (pipeline);
  gst_element_set_state (pipeline, GST_STATE_PLAYING);

  msg = gst_bus_timed_pop_filtered (bus, WAIT_SECONDS * GST_SECOND,
      GST_MESSAGE_ERROR | GST_MESSAGE_EOS);

  if (msg == NULL) {
    /* Leave the pipeline alone: taking a wedged graph to NULL blocks on the
     * same stream lock the hung streaming thread is holding. */
    g_printerr ("FAIL: neither ERROR nor EOS within %d s -- the sink is hung "
        "waiting on the main queue\n", WAIT_SECONDS);
    return 1;
  }

  if (GST_MESSAGE_TYPE (msg) == GST_MESSAGE_ERROR) {
    GError *err = NULL;
    gchar *dbg = NULL;

    gst_message_parse_error (msg, &err, &dbg);
    g_print ("PASS: reported an error instead of hanging: %s\n", err->message);
    if (dbg)
      g_print ("      %s\n", dbg);
    g_clear_error (&err);
    g_free (dbg);
  } else {
    g_print ("PASS: reached EOS -- this process does service the main queue\n");
  }

  ret = 0;
  gst_message_unref (msg);
  gst_element_set_state (pipeline, GST_STATE_NULL);
  gst_object_unref (bus);
  gst_object_unref (pipeline);

  return ret;
}
