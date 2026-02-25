/* GStreamer Metal deinterlace element
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
 * SECTION:element-vfmetaldeinterlace
 * @title: vfmetaldeinterlace
 *
 * Metal-accelerated video deinterlacing element supporting bob, weave,
 * linear, and greedy-H (motion-adaptive) algorithms.
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480,interlace-mode=interleaved ! \
 *   vfmetaldeinterlace method=bob ! autovideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetaldeinterlace.h"
#include "metaldeinterlacerenderer.h"

GST_DEBUG_CATEGORY (gst_vf_metal_deinterlace_debug);
#define GST_CAT_DEFAULT gst_vf_metal_deinterlace_debug

#define VF_METAL_DEINTERLACE_FORMATS "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_DEINTERLACE_FORMATS))
    );

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_DEINTERLACE_FORMATS))
    );

enum
{
  PROP_0,
  PROP_METHOD,
  PROP_FIELD_LAYOUT,
  PROP_MOTION_THRESHOLD,
};

#define DEFAULT_METHOD          0   /* bob */
#define DEFAULT_FIELD_LAYOUT    0   /* auto */
#define DEFAULT_MOTION_THRESHOLD 0.1

/* Deinterlace method enum */
#define GST_TYPE_VF_METAL_DEINTERLACE_METHOD \
    (gst_vf_metal_deinterlace_method_get_type())

GType
gst_vf_metal_deinterlace_method_get_type (void)
{
  static gsize method_type = 0;
  static const GEnumValue methods[] = {
    {0, "Bob (field interpolation)", "bob"},
    {1, "Weave (field merge from two frames)", "weave"},
    {2, "Linear (3-tap vertical filter)", "linear"},
    {3, "Greedy-H (motion-adaptive)", "greedyh"},
    {0, NULL, NULL}
  };

  if (g_once_init_enter (&method_type)) {
    GType t = g_enum_register_static ("GstVfMetalDeinterlaceMethod", methods);
    g_once_init_leave (&method_type, t);
  }
  return (GType) method_type;
}

/* Field layout enum */
#define GST_TYPE_VF_METAL_DEINTERLACE_FIELD_LAYOUT \
    (gst_vf_metal_deinterlace_field_layout_get_type())

GType
gst_vf_metal_deinterlace_field_layout_get_type (void)
{
  static gsize layout_type = 0;
  static const GEnumValue layouts[] = {
    {0, "Auto-detect from caps", "auto"},
    {1, "Top field first", "top-field-first"},
    {2, "Bottom field first", "bottom-field-first"},
    {0, NULL, NULL}
  };

  if (g_once_init_enter (&layout_type)) {
    GType t = g_enum_register_static ("GstVfMetalDeinterlaceFieldLayout", layouts);
    g_once_init_leave (&layout_type, t);
  }
  return (GType) layout_type;
}

/* --- GType boilerplate --- */

#define gst_vf_metal_deinterlace_parent_class parent_class
G_DEFINE_TYPE (GstVfMetalDeinterlace, gst_vf_metal_deinterlace,
    GST_TYPE_VIDEO_FILTER);

GST_ELEMENT_REGISTER_DEFINE (vfmetaldeinterlace, "vfmetaldeinterlace",
    GST_RANK_NONE, GST_TYPE_VF_METAL_DEINTERLACE);

/* --- set_info --- */

static gboolean
gst_vf_metal_deinterlace_set_info (GstVideoFilter * filter,
    GstCaps * incaps, GstVideoInfo * in_info,
    GstCaps * outcaps, GstVideoInfo * out_info)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (filter);

  if (!self->renderer) return FALSE;

  @autoreleasepool {
    MetalDeinterlaceRenderer *renderer =
        (__bridge MetalDeinterlaceRenderer *)self->renderer;
    if (![renderer configureWithInfo:in_info]) {
      GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
      return FALSE;
    }
  }

  return TRUE;
}

/* --- transform_frame --- */

static GstFlowReturn
gst_vf_metal_deinterlace_transform_frame (GstVideoFilter * filter,
    GstVideoFrame * inframe, GstVideoFrame * outframe)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (filter);

  if (!self->renderer) {
    GST_WARNING_OBJECT (self, "No Metal renderer");
    return GST_FLOW_ERROR;
  }

  MetalDeinterlaceRenderer *renderer =
      (__bridge MetalDeinterlaceRenderer *)self->renderer;

  /* Snapshot properties under lock */
  GST_OBJECT_LOCK (self);
  int fieldLayout = self->field_layout;
  int method = self->method;
  float motionThreshold = (float)self->motion_threshold;
  GST_OBJECT_UNLOCK (self);

  /* Determine field order */
  int topFieldFirst = 1;  /* default */
  if (fieldLayout == 1) {
    topFieldFirst = 1;
  } else if (fieldLayout == 2) {
    topFieldFirst = 0;
  } else {
    /* Auto: check buffer flags */
    GstBuffer *buf = inframe->buffer;
    if (buf) {
      if (GST_BUFFER_FLAG_IS_SET (buf, GST_VIDEO_BUFFER_FLAG_TFF)) {
        topFieldFirst = 1;
      } else {
        topFieldFirst = 0;
      }
    }
  }

  DeinterlaceParams params;
  params.method = (VfMetalDeinterlaceMethod)method;
  params.topFieldFirst = topFieldFirst;
  params.motionThreshold = motionThreshold;

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
gst_vf_metal_deinterlace_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_METHOD:
      self->method = g_value_get_enum (value);
      break;
    case PROP_FIELD_LAYOUT:
      self->field_layout = g_value_get_enum (value);
      break;
    case PROP_MOTION_THRESHOLD:
      self->motion_threshold = g_value_get_double (value);
      break;
    default:
      GST_OBJECT_UNLOCK (self);
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }
  GST_OBJECT_UNLOCK (self);
}

static void
gst_vf_metal_deinterlace_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_METHOD:
      g_value_set_enum (value, self->method);
      break;
    case PROP_FIELD_LAYOUT:
      g_value_set_enum (value, self->field_layout);
      break;
    case PROP_MOTION_THRESHOLD:
      g_value_set_double (value, self->motion_threshold);
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
gst_vf_metal_deinterlace_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (element);
  GstStateChangeReturn ret;

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalDeinterlaceRenderer *renderer =
              (__bridge MetalDeinterlaceRenderer *)self->renderer;
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
gst_vf_metal_deinterlace_finalize (GObject * object)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalDeinterlaceRenderer *renderer =
          (__bridge_transfer MetalDeinterlaceRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- class_init --- */

static void
gst_vf_metal_deinterlace_class_init (GstVfMetalDeinterlaceClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_deinterlace_set_property;
  gobject_class->get_property = gst_vf_metal_deinterlace_get_property;
  gobject_class->finalize = gst_vf_metal_deinterlace_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_deinterlace_change_state);

  gstvideofilter_class->set_info =
      GST_DEBUG_FUNCPTR (gst_vf_metal_deinterlace_set_info);
  gstvideofilter_class->transform_frame =
      GST_DEBUG_FUNCPTR (gst_vf_metal_deinterlace_transform_frame);

  g_object_class_install_property (gobject_class, PROP_METHOD,
      g_param_spec_enum ("method", "Method",
          "Deinterlacing algorithm",
          GST_TYPE_VF_METAL_DEINTERLACE_METHOD, DEFAULT_METHOD,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_FIELD_LAYOUT,
      g_param_spec_enum ("field-layout", "Field Layout",
          "Field order (top-first or bottom-first)",
          GST_TYPE_VF_METAL_DEINTERLACE_FIELD_LAYOUT, DEFAULT_FIELD_LAYOUT,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_MOTION_THRESHOLD,
      g_param_spec_double ("motion-threshold", "Motion Threshold",
          "Motion detection threshold for greedy-H method (0.0 to 1.0)",
          0.0, 1.0, DEFAULT_MOTION_THRESHOLD,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_add_static_pad_template (gstelement_class, &sink_template);
  gst_element_class_add_static_pad_template (gstelement_class, &src_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Deinterlace",
      "Filter/Effect/Video/Deinterlace",
      "Metal-accelerated video deinterlacing with bob, weave, linear, "
      "and greedy-H algorithms",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_deinterlace_debug,
      "vfmetaldeinterlace", 0, "Metal video deinterlace");
}

static void
gst_vf_metal_deinterlace_init (GstVfMetalDeinterlace * self)
{
  self->method = DEFAULT_METHOD;
  self->field_layout = DEFAULT_FIELD_LAYOUT;
  self->motion_threshold = DEFAULT_MOTION_THRESHOLD;

  @autoreleasepool {
    MetalDeinterlaceRenderer *renderer =
        [[MetalDeinterlaceRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self, "Failed to create Metal renderer");
    }
  }
}
