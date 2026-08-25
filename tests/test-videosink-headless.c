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
 * The pipeline is deliberately longer than the sink's own wait, so the error is
 * reached rather than raced: 300 frames at 30 fps is ten seconds of media, and
 * the sink gives the window five.
 *
 * PASS: the sink itself reports GST_RESOURCE_ERROR_NOT_FOUND.
 * FAIL: nothing arrives within the window -- that is the hang; or EOS, which
 *       means the sink did render and this process' precondition (no Cocoa run
 *       loop) does not hold, so the test proved nothing; or an error from
 *       somewhere else, which would be a different defect wearing this PASS.
 */

#include <gst/gst.h>

#define WAIT_SECONDS 30

int
main (int argc, char *argv[])
{
  GstElement *pipeline, *sink;
  GstBus *bus;
  GstMessage *msg;
  GError *err = NULL;
  gchar *dbg = NULL;
  int ret = 1;

  gst_init (&argc, &argv);

  pipeline = gst_parse_launch ("videotestsrc num-buffers=300 ! "
      "video/x-raw,format=BGRA,width=320,height=240 ! "
      "vfmetalvideosink name=sink", NULL);
  if (pipeline == NULL) {
    g_printerr ("FAIL: could not build the pipeline\n");
    return 1;
  }

  sink = gst_bin_get_by_name (GST_BIN (pipeline), "sink");
  g_assert (sink != NULL);

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

  if (GST_MESSAGE_TYPE (msg) == GST_MESSAGE_EOS) {
    g_printerr ("FAIL: reached EOS, so the sink rendered -- this process does "
        "service its main queue, and the test could not measure what it is "
        "for\n");
    goto done;
  }

  gst_message_parse_error (msg, &err, &dbg);

  if (GST_MESSAGE_SRC (msg) != GST_OBJECT (sink)) {
    g_printerr ("FAIL: the error came from %s, not from the sink: %s\n",
        GST_OBJECT_NAME (GST_MESSAGE_SRC (msg)), err->message);
    goto done;
  }

  if (err->domain != GST_RESOURCE_ERROR
      || err->code != GST_RESOURCE_ERROR_NOT_FOUND) {
    g_printerr ("FAIL: the sink failed for some other reason (%s, code %d): "
        "%s\n", g_quark_to_string (err->domain), err->code, err->message);
    goto done;
  }

  g_print ("PASS: the sink reported an error instead of hanging: %s\n",
      err->message);
  if (dbg)
    g_print ("      %s\n", dbg);
  ret = 0;

done:
  g_clear_error (&err);
  g_free (dbg);
  gst_message_unref (msg);
  gst_element_set_state (pipeline, GST_STATE_NULL);
  gst_object_unref (sink);
  gst_object_unref (bus);
  gst_object_unref (pipeline);

  return ret;
}
