/* GStreamer Metal video sink element
 *
 * Copyright (C) 2026 Roman Miniailov
 * Author: Roman Miniailov <miniailovr@gmail.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

/**
 * SECTION:element-vfmetalvideosink
 * @title: vfmetalvideosink
 *
 * Metal-accelerated video sink element that renders video frames using
 * Apple's Metal framework. Supports BGRA, RGBA, NV12, and I420 input
 * formats with GPU-accelerated YUV-to-RGB conversion.
 *
 * ## Sample pipeline
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
 *   vfmetalvideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetalvideosink.h"
#include "metalvideosinkrenderer.h"

#include <gst/video/videooverlay.h>
#include <gst/video/navigation.h>

GST_DEBUG_CATEGORY (gst_vf_metal_video_sink_debug);
#define GST_CAT_DEFAULT gst_vf_metal_video_sink_debug

#define VF_METAL_VIDEO_SINK_FORMATS "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_VIDEO_SINK_FORMATS))
    );

enum
{
  PROP_0,
  PROP_FORCE_ASPECT_RATIO,
  PROP_ENABLE_NAVIGATION_EVENTS,
};

#define DEFAULT_FORCE_ASPECT_RATIO TRUE
#define DEFAULT_ENABLE_NAVIGATION_EVENTS TRUE

/* --- Forward declarations --- */

static void gst_vf_metal_video_sink_video_overlay_init (
    GstVideoOverlayInterface * iface);
static void gst_vf_metal_video_sink_navigation_init (
    GstNavigationInterface * iface);

/* --- GType boilerplate --- */

#define gst_vf_metal_video_sink_parent_class parent_class
G_DEFINE_TYPE_WITH_CODE (GstVfMetalVideoSink, gst_vf_metal_video_sink,
    GST_TYPE_VIDEO_SINK,
    G_IMPLEMENT_INTERFACE (GST_TYPE_VIDEO_OVERLAY,
        gst_vf_metal_video_sink_video_overlay_init)
    G_IMPLEMENT_INTERFACE (GST_TYPE_NAVIGATION,
        gst_vf_metal_video_sink_navigation_init));

GST_ELEMENT_REGISTER_DEFINE (vfmetalvideosink, "vfmetalvideosink",
    GST_RANK_MARGINAL, GST_TYPE_VF_METAL_VIDEO_SINK);

/* --- set_caps --- */

static gboolean
gst_vf_metal_video_sink_set_caps (GstBaseSink * bsink, GstCaps * caps)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (bsink);
  GstVideoInfo info;

  GST_DEBUG_OBJECT (self, "set_caps: %" GST_PTR_FORMAT, caps);

  if (!gst_video_info_from_caps (&info, caps))
    return FALSE;

  self->info = info;
  self->have_info = TRUE;

  GST_VIDEO_SINK_WIDTH (self) = GST_VIDEO_INFO_WIDTH (&info);
  GST_VIDEO_SINK_HEIGHT (self) = GST_VIDEO_INFO_HEIGHT (&info);

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      if (![renderer configureWithVideoInfo:&info]) {
        GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
        return FALSE;
      }
    }
  }

  return TRUE;
}

/* --- show_frame --- */

static GstFlowReturn
gst_vf_metal_video_sink_show_frame (GstVideoSink * vsink, GstBuffer * buf)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (vsink);
  GstVideoFrame frame;

  if (!self->renderer || !self->have_info) {
    GST_WARNING_OBJECT (self, "Not configured yet");
    return GST_FLOW_OK;
  }

  MetalVideoSinkRenderer *renderer =
      (__bridge MetalVideoSinkRenderer *)self->renderer;

  /* Ensure window exists (lazy creation on first frame) */
  @autoreleasepool {
    [renderer ensureWindowWithHandle:self->window_handle
                               width:GST_VIDEO_SINK_WIDTH (self)
                              height:GST_VIDEO_SINK_HEIGHT (self)];
  }

  /* Refresh cached drawable size from view bounds (dispatched to main thread) */
  @autoreleasepool {
    [renderer updateDrawableSize];
  }

  /* Map the buffer */
  if (!gst_video_frame_map (&frame, &self->info, buf, GST_MAP_READ)) {
    GST_WARNING_OBJECT (self, "Could not map video frame");
    return GST_FLOW_ERROR;
  }

  /* Render */
  @autoreleasepool {
    if (![renderer renderFrame:&frame]) {
      GST_WARNING_OBJECT (self, "Metal rendering failed");
    }
  }

  gst_video_frame_unmap (&frame);
  return GST_FLOW_OK;
}

/* --- propose_allocation --- */

static gboolean
gst_vf_metal_video_sink_propose_allocation (GstBaseSink * bsink,
    GstQuery * query)
{
  GstCaps *caps;
  GstVideoInfo info;
  GstBufferPool *pool;
  guint size;
  GstStructure *structure;

  gst_query_parse_allocation (query, &caps, NULL);

  if (caps == NULL)
    return FALSE;

  if (!gst_video_info_from_caps (&info, caps))
    return FALSE;

  size = GST_VIDEO_INFO_SIZE (&info);

  pool = gst_video_buffer_pool_new ();
  structure = gst_buffer_pool_get_config (pool);
  gst_buffer_pool_config_set_params (structure, caps, size, 0, 0);

  if (!gst_buffer_pool_set_config (pool, structure)) {
    gst_object_unref (pool);
    return FALSE;
  }

  gst_query_add_allocation_pool (query, pool, size, 0, 0);
  gst_object_unref (pool);
  gst_query_add_allocation_meta (query, GST_VIDEO_META_API_TYPE, NULL);

  return TRUE;
}

/* --- State change --- */

static GstStateChangeReturn
gst_vf_metal_video_sink_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (element);
  GstStateChangeReturn ret;

  GST_DEBUG_OBJECT (self, "%s => %s",
      gst_element_state_get_name (GST_STATE_TRANSITION_CURRENT (transition)),
      gst_element_state_get_name (GST_STATE_TRANSITION_NEXT (transition)));

  switch (transition) {
    case GST_STATE_CHANGE_NULL_TO_READY:
      break;
    case GST_STATE_CHANGE_READY_TO_PAUSED:
      break;
    default:
      break;
  }

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalVideoSinkRenderer *renderer =
              (__bridge MetalVideoSinkRenderer *)self->renderer;
          [renderer closeWindow];
        }
      }
      self->have_info = FALSE;
      break;
    case GST_STATE_CHANGE_READY_TO_NULL:
      break;
    default:
      break;
  }

  return ret;
}

/* --- Properties --- */

static void
gst_vf_metal_video_sink_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (object);

  switch (prop_id) {
    case PROP_FORCE_ASPECT_RATIO:
      self->force_aspect_ratio = g_value_get_boolean (value);
      if (self->renderer) {
        @autoreleasepool {
          MetalVideoSinkRenderer *renderer =
              (__bridge MetalVideoSinkRenderer *)self->renderer;
          [renderer setForceAspectRatio:self->force_aspect_ratio];
        }
      }
      break;
    case PROP_ENABLE_NAVIGATION_EVENTS:
      self->handle_events = g_value_get_boolean (value);
      if (self->renderer) {
        @autoreleasepool {
          MetalVideoSinkRenderer *renderer =
              (__bridge MetalVideoSinkRenderer *)self->renderer;
          [renderer setHandleEvents:self->handle_events];
        }
      }
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_vf_metal_video_sink_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (object);

  switch (prop_id) {
    case PROP_FORCE_ASPECT_RATIO:
      g_value_set_boolean (value, self->force_aspect_ratio);
      break;
    case PROP_ENABLE_NAVIGATION_EVENTS:
      g_value_set_boolean (value, self->handle_events);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

/* --- Finalize --- */

static void
gst_vf_metal_video_sink_finalize (GObject * object)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge_transfer MetalVideoSinkRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* ============================================================= */
/*                     GstVideoOverlay interface                  */
/* ============================================================= */

static void
gst_vf_metal_video_sink_set_window_handle (GstVideoOverlay * overlay,
    guintptr handle)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (overlay);

  GST_DEBUG_OBJECT (self, "set_window_handle: %p", (void *)handle);
  self->window_handle = handle;

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      [renderer ensureWindowWithHandle:handle
                                 width:GST_VIDEO_SINK_WIDTH (self)
                                height:GST_VIDEO_SINK_HEIGHT (self)];
    }
  }
}

static void
gst_vf_metal_video_sink_expose (GstVideoOverlay * overlay)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (overlay);

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      [renderer expose];
    }
  }
}

static void
gst_vf_metal_video_sink_set_render_rectangle (GstVideoOverlay * overlay,
    gint x, gint y, gint width, gint height)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (overlay);

  self->have_render_rect = TRUE;
  self->render_rect.x = x;
  self->render_rect.y = y;
  self->render_rect.w = width;
  self->render_rect.h = height;

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      [renderer setRenderRectangleX:x y:y width:width height:height];
    }
  }
}

static void
gst_vf_metal_video_sink_handle_events (GstVideoOverlay * overlay,
    gboolean handle_events)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (overlay);
  self->handle_events = handle_events;

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      [renderer setHandleEvents:handle_events];
    }
  }
}

static void
gst_vf_metal_video_sink_video_overlay_init (GstVideoOverlayInterface * iface)
{
  iface->set_window_handle = gst_vf_metal_video_sink_set_window_handle;
  iface->expose = gst_vf_metal_video_sink_expose;
  iface->set_render_rectangle = gst_vf_metal_video_sink_set_render_rectangle;
  iface->handle_events = gst_vf_metal_video_sink_handle_events;
}

/* ============================================================= */
/*                     GstNavigation interface                    */
/* ============================================================= */

static void
gst_vf_metal_video_sink_navigation_send_event (GstNavigation * navigation,
    GstStructure * structure)
{
  GstVfMetalVideoSink *self = GST_VF_METAL_VIDEO_SINK (navigation);
  GstEvent *event;
  gdouble x, y;

  /* Transform mouse coordinates from view space to video space */
  if (self->renderer &&
      gst_structure_get_double (structure, "pointer_x", &x) &&
      gst_structure_get_double (structure, "pointer_y", &y)) {

    @autoreleasepool {
      MetalVideoSinkRenderer *renderer =
          (__bridge MetalVideoSinkRenderer *)self->renderer;
      gdouble vx, vy;
      [renderer transformNavigationX:x y:y toVideoX:&vx videoY:&vy];

      gst_structure_set (structure,
          "pointer_x", G_TYPE_DOUBLE, vx,
          "pointer_y", G_TYPE_DOUBLE, vy, NULL);
    }
  }

  event = gst_event_new_navigation (structure);

  gst_event_ref (event);
  if (!gst_pad_push_event (GST_VIDEO_SINK_PAD (self), event)) {
    gst_element_post_message (GST_ELEMENT_CAST (self),
        gst_navigation_message_new_event (GST_OBJECT_CAST (self), event));
  }
  gst_event_unref (event);
}

static void
gst_vf_metal_video_sink_navigation_init (GstNavigationInterface * iface)
{
  iface->send_event = gst_vf_metal_video_sink_navigation_send_event;
}

/* ============================================================= */
/*                     class_init / init                           */
/* ============================================================= */

static void
gst_vf_metal_video_sink_class_init (GstVfMetalVideoSinkClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstBaseSinkClass *gstbasesink_class = (GstBaseSinkClass *) klass;
  GstVideoSinkClass *gstvideosink_class = (GstVideoSinkClass *) klass;

  gobject_class->set_property = gst_vf_metal_video_sink_set_property;
  gobject_class->get_property = gst_vf_metal_video_sink_get_property;
  gobject_class->finalize = gst_vf_metal_video_sink_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_sink_change_state);

  gstbasesink_class->set_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_sink_set_caps);
  gstbasesink_class->propose_allocation =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_sink_propose_allocation);

  gstvideosink_class->show_frame =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_sink_show_frame);

  g_object_class_install_property (gobject_class, PROP_FORCE_ASPECT_RATIO,
      g_param_spec_boolean ("force-aspect-ratio", "Force aspect ratio",
          "When enabled, scaling will respect original aspect ratio",
          DEFAULT_FORCE_ASPECT_RATIO,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_ENABLE_NAVIGATION_EVENTS,
      g_param_spec_boolean ("enable-navigation-events",
          "Enable navigation events",
          "When enabled, navigation events are forwarded upstream",
          DEFAULT_ENABLE_NAVIGATION_EVENTS,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_add_static_pad_template (gstelement_class,
      &sink_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Sink",
      "Sink/Video",
      "Metal-accelerated video sink",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_video_sink_debug,
      "vfmetalvideosink", 0, "Metal video sink");
}

static void
gst_vf_metal_video_sink_init (GstVfMetalVideoSink * self)
{
  self->force_aspect_ratio = DEFAULT_FORCE_ASPECT_RATIO;
  self->window_handle = 0;
  self->have_info = FALSE;
  self->have_render_rect = FALSE;
  self->handle_events = TRUE;

  @autoreleasepool {
    MetalVideoSinkRenderer *renderer =
        [[MetalVideoSinkRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self,
          "Failed to create Metal renderer — no Metal device");
    }
  }
}
