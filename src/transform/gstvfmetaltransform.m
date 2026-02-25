/* GStreamer Metal video transform element
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
 * SECTION:element-vfmetaltransform
 * @title: vfmetaltransform
 *
 * Metal-accelerated video transform element providing flip, rotate,
 * and crop operations. When identity transform with no crop, operates
 * in passthrough mode (zero-copy).
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
 *   vfmetaltransform method=clockwise ! autovideosink
 * ]|
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
 *   vfmetaltransform method=horizontal-flip crop-left=100 crop-right=100 ! autovideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetaltransform.h"
#include "metaltransformrenderer.h"

GST_DEBUG_CATEGORY (gst_vf_metal_transform_debug);
#define GST_CAT_DEFAULT gst_vf_metal_transform_debug

#define VF_METAL_TRANSFORM_FORMATS "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_TRANSFORM_FORMATS))
    );

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_TRANSFORM_FORMATS))
    );

enum
{
  PROP_0,
  PROP_METHOD,
  PROP_CROP_TOP,
  PROP_CROP_BOTTOM,
  PROP_CROP_LEFT,
  PROP_CROP_RIGHT,
};

#define DEFAULT_METHOD      0   /* identity */
#define DEFAULT_CROP        0

/* Transform method enum type */
#define GST_TYPE_VF_METAL_TRANSFORM_METHOD \
    (gst_vf_metal_transform_method_get_type())

GType
gst_vf_metal_transform_method_get_type (void)
{
  static gsize method_type = 0;
  static const GEnumValue methods[] = {
    {0, "Identity (no rotation)", "none"},
    {1, "Rotate clockwise 90 degrees", "clockwise"},
    {2, "Rotate 180 degrees", "rotate-180"},
    {3, "Rotate counter-clockwise 90 degrees", "counterclockwise"},
    {4, "Flip horizontally", "horizontal-flip"},
    {5, "Flip vertically", "vertical-flip"},
    {6, "Flip across upper left/lower right diagonal", "upper-left-diagonal"},
    {7, "Flip across upper right/lower left diagonal", "upper-right-diagonal"},
    {0, NULL, NULL}
  };

  if (g_once_init_enter (&method_type)) {
    GType t = g_enum_register_static ("GstVfMetalTransformMethod", methods);
    g_once_init_leave (&method_type, t);
  }
  return (GType) method_type;
}

/* --- GType boilerplate --- */

#define gst_vf_metal_transform_parent_class parent_class
G_DEFINE_TYPE (GstVfMetalTransform, gst_vf_metal_transform,
    GST_TYPE_VIDEO_FILTER);

GST_ELEMENT_REGISTER_DEFINE (vfmetaltransform, "vfmetaltransform",
    GST_RANK_NONE, GST_TYPE_VF_METAL_TRANSFORM);

/* --- Passthrough check --- */

static void
gst_vf_metal_transform_update_passthrough (GstVfMetalTransform * self)
{
  GST_OBJECT_LOCK (self);
  gboolean passthrough =
      (self->method == 0) &&
      (self->crop_top == 0) &&
      (self->crop_bottom == 0) &&
      (self->crop_left == 0) &&
      (self->crop_right == 0);
  GST_OBJECT_UNLOCK (self);

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), passthrough);
  GST_DEBUG_OBJECT (self, "passthrough = %s", passthrough ? "TRUE" : "FALSE");
}

/* --- set_info --- */

static gboolean
gst_vf_metal_transform_set_info (GstVideoFilter * filter,
    GstCaps * incaps, GstVideoInfo * in_info,
    GstCaps * outcaps, GstVideoInfo * out_info)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (filter);

  GST_DEBUG_OBJECT (self, "set_info: in=%" GST_PTR_FORMAT
      " out=%" GST_PTR_FORMAT, incaps, outcaps);

  if (!self->renderer) return FALSE;

  @autoreleasepool {
    MetalTransformRenderer *renderer =
        (__bridge MetalTransformRenderer *)self->renderer;
    if (![renderer configureWithInputInfo:in_info outputInfo:out_info]) {
      GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
      return FALSE;
    }
  }

  return TRUE;
}

/* --- transform_frame --- */

static GstFlowReturn
gst_vf_metal_transform_transform_frame (GstVideoFilter * filter,
    GstVideoFrame * inframe, GstVideoFrame * outframe)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (filter);

  if (!self->renderer) {
    GST_WARNING_OBJECT (self, "No Metal renderer");
    return GST_FLOW_ERROR;
  }

  MetalTransformRenderer *renderer =
      (__bridge MetalTransformRenderer *)self->renderer;

  /* Snapshot properties under lock */
  TransformParams params;
  GST_OBJECT_LOCK (self);
  params.method = (VfMetalTransformMethod)self->method;
  params.cropTop = self->crop_top;
  params.cropBottom = self->crop_bottom;
  params.cropLeft = self->crop_left;
  params.cropRight = self->crop_right;
  GST_OBJECT_UNLOCK (self);

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
gst_vf_metal_transform_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_METHOD:
      self->method = g_value_get_enum (value);
      break;
    case PROP_CROP_TOP:
      self->crop_top = g_value_get_int (value);
      break;
    case PROP_CROP_BOTTOM:
      self->crop_bottom = g_value_get_int (value);
      break;
    case PROP_CROP_LEFT:
      self->crop_left = g_value_get_int (value);
      break;
    case PROP_CROP_RIGHT:
      self->crop_right = g_value_get_int (value);
      break;
    default:
      GST_OBJECT_UNLOCK (self);
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }
  GST_OBJECT_UNLOCK (self);

  gst_vf_metal_transform_update_passthrough (self);
}

static void
gst_vf_metal_transform_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_METHOD:
      g_value_set_enum (value, self->method);
      break;
    case PROP_CROP_TOP:
      g_value_set_int (value, self->crop_top);
      break;
    case PROP_CROP_BOTTOM:
      g_value_set_int (value, self->crop_bottom);
      break;
    case PROP_CROP_LEFT:
      g_value_set_int (value, self->crop_left);
      break;
    case PROP_CROP_RIGHT:
      g_value_set_int (value, self->crop_right);
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
gst_vf_metal_transform_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (element);
  GstStateChangeReturn ret;

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalTransformRenderer *renderer =
              (__bridge MetalTransformRenderer *)self->renderer;
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
gst_vf_metal_transform_finalize (GObject * object)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalTransformRenderer *renderer =
          (__bridge_transfer MetalTransformRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- class_init --- */

static void
gst_vf_metal_transform_class_init (GstVfMetalTransformClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_transform_set_property;
  gobject_class->get_property = gst_vf_metal_transform_get_property;
  gobject_class->finalize = gst_vf_metal_transform_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_change_state);

  gstvideofilter_class->set_info =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_set_info);
  gstvideofilter_class->transform_frame =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_transform_frame);

  /* --- Install properties --- */

  g_object_class_install_property (gobject_class, PROP_METHOD,
      g_param_spec_enum ("method", "Method",
          "Video transform method (flip/rotate)",
          GST_TYPE_VF_METAL_TRANSFORM_METHOD, DEFAULT_METHOD,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CROP_TOP,
      g_param_spec_int ("crop-top", "Crop Top",
          "Pixels to crop from the top edge",
          0, G_MAXINT, DEFAULT_CROP,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CROP_BOTTOM,
      g_param_spec_int ("crop-bottom", "Crop Bottom",
          "Pixels to crop from the bottom edge",
          0, G_MAXINT, DEFAULT_CROP,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CROP_LEFT,
      g_param_spec_int ("crop-left", "Crop Left",
          "Pixels to crop from the left edge",
          0, G_MAXINT, DEFAULT_CROP,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CROP_RIGHT,
      g_param_spec_int ("crop-right", "Crop Right",
          "Pixels to crop from the right edge",
          0, G_MAXINT, DEFAULT_CROP,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  /* Pad templates */
  gst_element_class_add_static_pad_template (gstelement_class, &sink_template);
  gst_element_class_add_static_pad_template (gstelement_class, &src_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Transform",
      "Filter/Effect/Video",
      "Metal-accelerated video flip, rotate, and crop",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_transform_debug,
      "vfmetaltransform", 0, "Metal video transform");
}

/* --- init --- */

static void
gst_vf_metal_transform_init (GstVfMetalTransform * self)
{
  self->method = DEFAULT_METHOD;
  self->crop_top = DEFAULT_CROP;
  self->crop_bottom = DEFAULT_CROP;
  self->crop_left = DEFAULT_CROP;
  self->crop_right = DEFAULT_CROP;

  @autoreleasepool {
    MetalTransformRenderer *renderer =
        [[MetalTransformRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self, "Failed to create Metal renderer");
    }
  }

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), TRUE);
}
