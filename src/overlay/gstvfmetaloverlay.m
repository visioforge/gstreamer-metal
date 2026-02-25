/* GStreamer Metal overlay element
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
 * SECTION:element-vfmetaloverlay
 * @title: vfmetaloverlay
 *
 * Metal-accelerated image overlay element. Composites a PNG or JPEG
 * image onto video frames on the GPU. When no overlay image is loaded,
 * operates in passthrough mode (zero-copy).
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
 *   vfmetaloverlay location=/path/to/logo.png x=10 y=10 alpha=0.8 ! autovideosink
 * ]|
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
 *   vfmetaloverlay location=/path/to/watermark.png relative-x=0.9 relative-y=0.05 ! autovideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetaloverlay.h"
#include "metaloverlayrenderer.h"

GST_DEBUG_CATEGORY (gst_vf_metal_overlay_debug);
#define GST_CAT_DEFAULT gst_vf_metal_overlay_debug

#define VF_METAL_OVERLAY_FORMATS "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_OVERLAY_FORMATS))
    );

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_OVERLAY_FORMATS))
    );

enum
{
  PROP_0,
  PROP_LOCATION,
  PROP_X,
  PROP_Y,
  PROP_WIDTH,
  PROP_HEIGHT,
  PROP_ALPHA,
  PROP_RELATIVE_X,
  PROP_RELATIVE_Y,
};

#define DEFAULT_X           0
#define DEFAULT_Y           0
#define DEFAULT_WIDTH       0
#define DEFAULT_HEIGHT      0
#define DEFAULT_ALPHA       1.0
#define DEFAULT_RELATIVE    -1.0

/* --- GType boilerplate --- */

#define gst_vf_metal_overlay_parent_class parent_class
G_DEFINE_TYPE (GstVfMetalOverlay, gst_vf_metal_overlay,
    GST_TYPE_VIDEO_FILTER);

GST_ELEMENT_REGISTER_DEFINE (vfmetaloverlay, "vfmetaloverlay",
    GST_RANK_NONE, GST_TYPE_VF_METAL_OVERLAY);

/* --- Passthrough check --- */

static void
gst_vf_metal_overlay_update_passthrough (GstVfMetalOverlay * self)
{
  gboolean passthrough = !self->image_loaded;

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), passthrough);
  GST_DEBUG_OBJECT (self, "passthrough = %s", passthrough ? "TRUE" : "FALSE");
}

/* --- Load overlay image --- */

static void
gst_vf_metal_overlay_load_image (GstVfMetalOverlay * self)
{
  if (!self->renderer)
    return;

  @autoreleasepool {
    MetalOverlayRenderer *renderer =
        (__bridge MetalOverlayRenderer *)self->renderer;

    if (!self->location || *self->location == '\0') {
      [renderer clearImage];
      self->image_loaded = FALSE;
    } else {
      if ([renderer loadImageFromFile:self->location]) {
        self->image_loaded = TRUE;
        GST_INFO_OBJECT (self, "Loaded overlay image: %s", self->location);
      } else {
        self->image_loaded = FALSE;
        GST_WARNING_OBJECT (self, "Failed to load overlay image: %s",
            self->location);
      }
    }
  }

  gst_vf_metal_overlay_update_passthrough (self);
}

/* --- set_info --- */

static gboolean
gst_vf_metal_overlay_set_info (GstVideoFilter * filter,
    GstCaps * incaps, GstVideoInfo * in_info,
    GstCaps * outcaps, GstVideoInfo * out_info)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (filter);

  GST_DEBUG_OBJECT (self, "set_info: in=%" GST_PTR_FORMAT
      " out=%" GST_PTR_FORMAT, incaps, outcaps);

  if (!self->renderer) return FALSE;

  @autoreleasepool {
    MetalOverlayRenderer *renderer =
        (__bridge MetalOverlayRenderer *)self->renderer;
    if (![renderer configureWithInputInfo:in_info outputInfo:out_info]) {
      GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
      return FALSE;
    }
  }

  return TRUE;
}

/* --- transform_frame --- */

static GstFlowReturn
gst_vf_metal_overlay_transform_frame (GstVideoFilter * filter,
    GstVideoFrame * inframe, GstVideoFrame * outframe)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (filter);

  if (!self->renderer) {
    GST_WARNING_OBJECT (self, "No Metal renderer");
    return GST_FLOW_ERROR;
  }

  MetalOverlayRenderer *renderer =
      (__bridge MetalOverlayRenderer *)self->renderer;

  int frameW = GST_VIDEO_FRAME_WIDTH (inframe);
  int frameH = GST_VIDEO_FRAME_HEIGHT (inframe);

  /* Snapshot properties under lock */
  OverlayParams params;
  GST_OBJECT_LOCK (self);
  params.alpha = self->alpha;
  params.width = (float)self->width;
  params.height = (float)self->height;
  gdouble rel_x = self->relative_x;
  gdouble rel_y = self->relative_y;
  int abs_x = self->x;
  int abs_y = self->y;
  GST_OBJECT_UNLOCK (self);

  /* Resolve position: relative overrides absolute */
  if (rel_x >= 0.0) {
    params.x = (float)(rel_x * frameW);
  } else {
    params.x = (float)abs_x;
  }

  if (rel_y >= 0.0) {
    params.y = (float)(rel_y * frameH);
  } else {
    params.y = (float)abs_y;
  }

  @autoreleasepool {
    if (![renderer processFrame:inframe output:outframe params:&params]) {
      GST_WARNING_OBJECT (self, "Metal rendering failed");
      return GST_FLOW_ERROR;
    }
  }

  return GST_FLOW_OK;
}

/* --- Properties --- */

static void
gst_vf_metal_overlay_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_LOCATION:
      g_free (self->location);
      self->location = g_value_dup_string (value);
      break;
    case PROP_X:
      self->x = g_value_get_int (value);
      break;
    case PROP_Y:
      self->y = g_value_get_int (value);
      break;
    case PROP_WIDTH:
      self->width = g_value_get_int (value);
      break;
    case PROP_HEIGHT:
      self->height = g_value_get_int (value);
      break;
    case PROP_ALPHA:
      self->alpha = g_value_get_double (value);
      break;
    case PROP_RELATIVE_X:
      self->relative_x = g_value_get_double (value);
      break;
    case PROP_RELATIVE_Y:
      self->relative_y = g_value_get_double (value);
      break;
    default:
      GST_OBJECT_UNLOCK (self);
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }
  GST_OBJECT_UNLOCK (self);

  /* Image loading outside lock (involves Metal GPU operations) */
  if (prop_id == PROP_LOCATION) {
    gst_vf_metal_overlay_load_image (self);
  }
}

static void
gst_vf_metal_overlay_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_LOCATION:
      g_value_set_string (value, self->location);
      break;
    case PROP_X:
      g_value_set_int (value, self->x);
      break;
    case PROP_Y:
      g_value_set_int (value, self->y);
      break;
    case PROP_WIDTH:
      g_value_set_int (value, self->width);
      break;
    case PROP_HEIGHT:
      g_value_set_int (value, self->height);
      break;
    case PROP_ALPHA:
      g_value_set_double (value, self->alpha);
      break;
    case PROP_RELATIVE_X:
      g_value_set_double (value, self->relative_x);
      break;
    case PROP_RELATIVE_Y:
      g_value_set_double (value, self->relative_y);
      break;
    default:
      GST_OBJECT_UNLOCK (self);
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }
  GST_OBJECT_UNLOCK (self);
}

/* --- State change --- */

static GstStateChangeReturn
gst_vf_metal_overlay_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (element);
  GstStateChangeReturn ret;

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalOverlayRenderer *renderer =
              (__bridge MetalOverlayRenderer *)self->renderer;
          [renderer cleanup];
        }
      }
      break;
    default:
      break;
  }

  return ret;
}

/* --- Finalize --- */

static void
gst_vf_metal_overlay_finalize (GObject * object)
{
  GstVfMetalOverlay *self = GST_VF_METAL_OVERLAY (object);

  g_free (self->location);
  self->location = NULL;

  if (self->renderer) {
    @autoreleasepool {
      MetalOverlayRenderer *renderer =
          (__bridge_transfer MetalOverlayRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- class_init --- */

static void
gst_vf_metal_overlay_class_init (GstVfMetalOverlayClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_overlay_set_property;
  gobject_class->get_property = gst_vf_metal_overlay_get_property;
  gobject_class->finalize = gst_vf_metal_overlay_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_overlay_change_state);

  gstvideofilter_class->set_info =
      GST_DEBUG_FUNCPTR (gst_vf_metal_overlay_set_info);
  gstvideofilter_class->transform_frame =
      GST_DEBUG_FUNCPTR (gst_vf_metal_overlay_transform_frame);

  /* --- Install properties --- */

  g_object_class_install_property (gobject_class, PROP_LOCATION,
      g_param_spec_string ("location", "Location",
          "Path to overlay image file (PNG or JPEG)",
          NULL,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_X,
      g_param_spec_int ("x", "X Position",
          "Overlay X position in pixels",
          0, G_MAXINT, DEFAULT_X,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_Y,
      g_param_spec_int ("y", "Y Position",
          "Overlay Y position in pixels",
          0, G_MAXINT, DEFAULT_Y,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_WIDTH,
      g_param_spec_int ("width", "Width",
          "Overlay width in pixels (0 = original image width)",
          0, G_MAXINT, DEFAULT_WIDTH,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_HEIGHT,
      g_param_spec_int ("height", "Height",
          "Overlay height in pixels (0 = original image height)",
          0, G_MAXINT, DEFAULT_HEIGHT,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_ALPHA,
      g_param_spec_double ("alpha", "Alpha",
          "Overlay opacity (0.0 = transparent, 1.0 = opaque)",
          0.0, 1.0, DEFAULT_ALPHA,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_RELATIVE_X,
      g_param_spec_double ("relative-x", "Relative X",
          "Overlay X position as fraction of video width (-1 = use pixel x)",
          -1.0, 1.0, DEFAULT_RELATIVE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_RELATIVE_Y,
      g_param_spec_double ("relative-y", "Relative Y",
          "Overlay Y position as fraction of video height (-1 = use pixel y)",
          -1.0, 1.0, DEFAULT_RELATIVE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  /* Pad templates */
  gst_element_class_add_static_pad_template (gstelement_class, &sink_template);
  gst_element_class_add_static_pad_template (gstelement_class, &src_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Overlay",
      "Filter/Effect/Video",
      "Metal-accelerated image overlay compositing",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_overlay_debug,
      "vfmetaloverlay", 0, "Metal video overlay");
}

/* --- init --- */

static void
gst_vf_metal_overlay_init (GstVfMetalOverlay * self)
{
  self->location = NULL;
  self->x = DEFAULT_X;
  self->y = DEFAULT_Y;
  self->width = DEFAULT_WIDTH;
  self->height = DEFAULT_HEIGHT;
  self->alpha = DEFAULT_ALPHA;
  self->relative_x = DEFAULT_RELATIVE;
  self->relative_y = DEFAULT_RELATIVE;
  self->image_loaded = FALSE;

  @autoreleasepool {
    MetalOverlayRenderer *renderer =
        [[MetalOverlayRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self, "Failed to create Metal renderer");
    }
  }

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), TRUE);
}
