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

/* --- transform_caps --- */

/* Every output frame is progressive, whatever came in: the src side says
 * so, and the sink side accepts any interlace mode. */
static GstCaps *
gst_vf_metal_deinterlace_transform_caps (GstBaseTransform * trans,
    GstPadDirection direction, GstCaps * caps, GstCaps * filter)
{
  GstCaps *ret = gst_caps_copy (caps);

  for (guint i = 0; i < gst_caps_get_size (ret); i++) {
    GstStructure *s = gst_caps_get_structure (ret, i);
    gst_structure_remove_field (s, "field-order");
    if (direction == GST_PAD_SINK) {
      gst_structure_set (s, "interlace-mode", G_TYPE_STRING, "progressive",
          NULL);
    } else {
      gst_structure_remove_field (s, "interlace-mode");
    }
  }

  if (filter) {
    GstCaps *tmp = gst_caps_intersect_full (filter, ret,
        GST_CAPS_INTERSECT_FIRST);
    gst_caps_unref (ret);
    ret = tmp;
  }

  GST_DEBUG_OBJECT (trans, "transformed %" GST_PTR_FORMAT " to %"
      GST_PTR_FORMAT, caps, ret);

  return ret;
}

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
    /* Auto: the frame flags carry the caps field-order, else the buffer's
     * TFF flag (gst_video_frame_map); progressive caps carry neither. */
    topFieldFirst = GST_VIDEO_FRAME_IS_TFF (inframe) ||
        GST_BUFFER_FLAG_IS_SET (inframe->buffer, GST_VIDEO_BUFFER_FLAG_TFF);
  }

  DeinterlaceParams params;
  params.method = (VfMetalDeinterlaceMethod)method;
  params.topFieldFirst = topFieldFirst;
  params.motionThreshold = motionThreshold;

  /* In a mixed stream a frame its buffer does not flag as interlaced is
   * progressive already: copy it rather than halve its vertical detail. */
  if (GST_VIDEO_INFO_INTERLACE_MODE (&inframe->info) ==
      GST_VIDEO_INTERLACE_MODE_MIXED && !GST_VIDEO_FRAME_IS_INTERLACED (inframe)) {
    GST_LOG_OBJECT (self, "progressive frame in a mixed stream, copied");
    if (!gst_video_frame_copy (outframe, inframe))
      return GST_FLOW_ERROR;
    /* weave/greedyh must not pair the next interlaced frame with one from
     * before this progressive run. */
    [renderer resetHistory];
  } else {
    GST_LOG_OBJECT (self, "deinterlacing, %s field first",
        topFieldFirst ? "top" : "bottom");
    @autoreleasepool {
      if (![renderer processFrame:inframe output:outframe params:&params]) {
        GST_WARNING_OBJECT (self, "Metal rendering failed");
        return GST_FLOW_ERROR;
      }
    }
  }

  /* The base class copied the input's field flags onto the output. */
  GST_BUFFER_FLAG_UNSET (outframe->buffer, GST_VIDEO_BUFFER_FLAG_INTERLACED |
      GST_VIDEO_BUFFER_FLAG_TFF | GST_VIDEO_BUFFER_FLAG_RFF |
      GST_VIDEO_BUFFER_FLAG_ONEFIELD);

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
      self->pending_method = g_value_get_enum (value);
      break;
    case PROP_FIELD_LAYOUT:
      self->pending_field_layout = g_value_get_enum (value);
      break;
    case PROP_MOTION_THRESHOLD:
      self->pending_motion_threshold = g_value_get_double (value);
      break;
    default:
      GST_OBJECT_UNLOCK (self);
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }
  /* dispatch_properties_changed commits it, with the rest of the batch */
  GST_OBJECT_UNLOCK (self);
}

/* GObject calls this once per batch of writes, after the last one: right
 * after a single g_object_set_property (), at the end of a g_object_set ()
 * with several properties, or at the g_object_thaw_notify () that ends a
 * freeze. Committing here means the streaming thread never sees settings
 * that were never set together. */
static void
gst_vf_metal_deinterlace_dispatch_properties_changed (GObject * object,
    guint n_pspecs, GParamSpec ** pspecs)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (object);

  GST_OBJECT_LOCK (self);
  self->method = self->pending_method;
  self->field_layout = self->pending_field_layout;
  self->motion_threshold = self->pending_motion_threshold;
  GST_OBJECT_UNLOCK (self);

  G_OBJECT_CLASS (parent_class)->dispatch_properties_changed (object,
      n_pspecs, pspecs);
}

static void
gst_vf_metal_deinterlace_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalDeinterlace *self = GST_VF_METAL_DEINTERLACE (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_METHOD:
      g_value_set_enum (value, self->pending_method);
      break;
    case PROP_FIELD_LAYOUT:
      g_value_set_enum (value, self->pending_field_layout);
      break;
    case PROP_MOTION_THRESHOLD:
      g_value_set_double (value, self->pending_motion_threshold);
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
  GstBaseTransformClass *basetransform_class = (GstBaseTransformClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_deinterlace_set_property;
  gobject_class->get_property = gst_vf_metal_deinterlace_get_property;
  gobject_class->finalize = gst_vf_metal_deinterlace_finalize;
  gobject_class->dispatch_properties_changed =
      gst_vf_metal_deinterlace_dispatch_properties_changed;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_deinterlace_change_state);

  basetransform_class->transform_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_deinterlace_transform_caps);

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
  self->pending_method = self->method;
  self->pending_field_layout = self->field_layout;
  self->pending_motion_threshold = self->motion_threshold;

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
