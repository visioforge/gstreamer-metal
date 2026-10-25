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

/* --- transform_caps --- */

static gboolean
gst_vf_metal_transform_method_swaps_axes (int method)
{
  return method == VF_METAL_TRANSFORM_90R || method == VF_METAL_TRANSFORM_90L ||
      method == VF_METAL_TRANSFORM_UL_LR || method == VF_METAL_TRANSFORM_UR_LL;
}

/* Shifts a width or height value (an int, an int range or a list of them)
 * by @delta. Values that would leave [1, G_MAXINT] are dropped, and FALSE
 * means none is left. A range keeps its step when the shift preserves the
 * alignment. */
static gboolean
gst_vf_metal_transform_shift_dimension (const GValue * src, gint64 delta,
    GValue * dest)
{
  if (G_VALUE_HOLDS_INT (src)) {
    gint64 v = (gint64) g_value_get_int (src) + delta;
    if (v < 1 || v > G_MAXINT)
      return FALSE;
    g_value_init (dest, G_TYPE_INT);
    g_value_set_int (dest, (gint) v);
    return TRUE;
  }

  if (GST_VALUE_HOLDS_INT_RANGE (src)) {
    gint64 step = gst_value_get_int_range_step (src);
    if (delta % step != 0)
      step = 1;
    gint64 min = (gint64) gst_value_get_int_range_min (src) + delta;
    gint64 max = (gint64) gst_value_get_int_range_max (src) + delta;
    if (min < 1)
      min = step;
    if (max > G_MAXINT)
      max = (G_MAXINT / step) * step;
    if (min > max)
      return FALSE;
    if (min == max) {
      g_value_init (dest, G_TYPE_INT);
      g_value_set_int (dest, (gint) min);
    } else {
      g_value_init (dest, GST_TYPE_INT_RANGE);
      gst_value_set_int_range_step (dest, (gint) min, (gint) max, (gint) step);
    }
    return TRUE;
  }

  if (GST_VALUE_HOLDS_LIST (src)) {
    GValue list = G_VALUE_INIT;
    g_value_init (&list, GST_TYPE_LIST);
    for (guint i = 0; i < gst_value_list_get_size (src); i++) {
      GValue v = G_VALUE_INIT;
      if (gst_vf_metal_transform_shift_dimension (
              gst_value_list_get_value (src, i), delta, &v))
        gst_value_list_append_and_take_value (&list, &v);
    }
    if (gst_value_list_get_size (&list) == 0) {
      g_value_unset (&list);
      return FALSE;
    }
    *dest = list;
    return TRUE;
  }

  return FALSE;
}

/* The crop is in input coordinates and comes first, the rotation second:
 * sink -> src removes the crop, then swaps the axes; src -> sink undoes the
 * swap, then adds the crop back. The shape of videocrop ! videoflip. */
static GstCaps *
gst_vf_metal_transform_transform_caps (GstBaseTransform * trans,
    GstPadDirection direction, GstCaps * caps, GstCaps * filter)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (trans);
  GstCaps *ret = gst_caps_new_empty ();

  GST_OBJECT_LOCK (self);
  gboolean swap = gst_vf_metal_transform_method_swaps_axes (self->method);
  gint64 dx = (gint64) self->crop_left + self->crop_right;
  gint64 dy = (gint64) self->crop_top + self->crop_bottom;
  GST_OBJECT_UNLOCK (self);

  if (direction == GST_PAD_SINK) {
    dx = -dx;
    dy = -dy;
  }

  for (guint i = 0; i < gst_caps_get_size (caps); i++) {
    GstStructure *s = gst_structure_copy (gst_caps_get_structure (caps, i));
    const GValue *w = gst_structure_get_value (s, "width");
    const GValue *h = gst_structure_get_value (s, "height");
    /* The input frame's axes: on the src side they are swapped. */
    const GValue *in_w = (direction == GST_PAD_SRC && swap) ? h : w;
    const GValue *in_h = (direction == GST_PAD_SRC && swap) ? w : h;
    GValue new_w = G_VALUE_INIT, new_h = G_VALUE_INIT;

    if ((in_w && !gst_vf_metal_transform_shift_dimension (in_w, dx, &new_w)) ||
        (in_h && !gst_vf_metal_transform_shift_dimension (in_h, dy, &new_h))) {
      if (G_IS_VALUE (&new_w))
        g_value_unset (&new_w);
      GST_DEBUG_OBJECT (self, "no size left in %" GST_PTR_FORMAT, s);
      gst_structure_free (s);
      continue;
    }

    /* new_w/new_h are along the input's axes; sink -> src swaps them. */
    gboolean out_swap = direction == GST_PAD_SINK && swap;
    GValue *out_w = out_swap ? &new_h : &new_w;
    GValue *out_h = out_swap ? &new_w : &new_h;
    gst_structure_remove_fields (s, "width", "height", NULL);
    if (G_IS_VALUE (out_w))
      gst_structure_take_value (s, "width", out_w);
    if (G_IS_VALUE (out_h))
      gst_structure_take_value (s, "height", out_h);

    gint par_n, par_d;
    if (swap && gst_structure_get_fraction (s, "pixel-aspect-ratio",
            &par_n, &par_d) && par_n != par_d && par_n != 0) {
      gst_structure_set (s, "pixel-aspect-ratio", GST_TYPE_FRACTION,
          par_d, par_n, NULL);
    }

    gst_caps_append_structure_full (ret, s,
        gst_caps_features_copy (gst_caps_get_features (caps, i)));
  }

  if (filter) {
    GstCaps *tmp = gst_caps_intersect_full (filter, ret,
        GST_CAPS_INTERSECT_FIRST);
    gst_caps_unref (ret);
    ret = tmp;
  }

  GST_DEBUG_OBJECT (self, "transformed %" GST_PTR_FORMAT " to %"
      GST_PTR_FORMAT, caps, ret);

  return ret;
}

/* --- Applying the properties --- */

/* Makes the live properties the ones transform_frame renders with. Called
 * with the object lock held; returns whether they make a passthrough. */
static gboolean
gst_vf_metal_transform_apply_locked (GstVfMetalTransform * self)
{
  self->applied_method = self->method;
  self->applied_crop_top = self->crop_top;
  self->applied_crop_bottom = self->crop_bottom;
  self->applied_crop_left = self->crop_left;
  self->applied_crop_right = self->crop_right;
  return self->method == 0 && self->crop_top == 0 && self->crop_bottom == 0 &&
      self->crop_left == 0 && self->crop_right == 0;
}

/* A change that leaves the output size alone renegotiates to the same caps,
 * and basetransform skips set_info for those: apply it here, on the
 * streaming thread, before the buffer. A change of size waits for set_info. */
static void
gst_vf_metal_transform_before_transform (GstBaseTransform * trans,
    GstBuffer * buffer)
{
  GstVfMetalTransform *self = GST_VF_METAL_TRANSFORM (trans);
  GstVideoFilter *filter = GST_VIDEO_FILTER (trans);

  if (!filter->negotiated)
    return;

  GST_OBJECT_LOCK (self);
  if (self->method == self->applied_method &&
      self->crop_top == self->applied_crop_top &&
      self->crop_bottom == self->applied_crop_bottom &&
      self->crop_left == self->applied_crop_left &&
      self->crop_right == self->applied_crop_right) {
    GST_OBJECT_UNLOCK (self);
    return;
  }

  gint64 w = (gint64) GST_VIDEO_INFO_WIDTH (&filter->in_info) -
      self->crop_left - self->crop_right;
  gint64 h = (gint64) GST_VIDEO_INFO_HEIGHT (&filter->in_info) -
      self->crop_top - self->crop_bottom;
  if (gst_vf_metal_transform_method_swaps_axes (self->method)) {
    gint64 t = w;
    w = h;
    h = t;
  }
  /* A swap of axes on a non-square PAR inverts the PAR: new caps too. */
  gboolean par_changes =
      gst_vf_metal_transform_method_swaps_axes (self->method) !=
      gst_vf_metal_transform_method_swaps_axes (self->applied_method) &&
      GST_VIDEO_INFO_PAR_N (&filter->in_info) !=
      GST_VIDEO_INFO_PAR_D (&filter->in_info);
  if (par_changes || w != GST_VIDEO_INFO_WIDTH (&filter->out_info) ||
      h != GST_VIDEO_INFO_HEIGHT (&filter->out_info)) {
    GST_OBJECT_UNLOCK (self);
    return;
  }

  gboolean passthrough = gst_vf_metal_transform_apply_locked (self);
  GST_OBJECT_UNLOCK (self);

  gst_base_transform_set_passthrough (trans, passthrough);
  GST_DEBUG_OBJECT (self, "applied at the same size, passthrough = %s",
      passthrough ? "TRUE" : "FALSE");
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

  /* The caps were negotiated for the properties as they are now. A change
   * that lands between negotiation and here may not fit these caps: never
   * pass a buffer through to caps of another size (the pending reconfigure
   * renegotiates on the next buffer). */
  GST_OBJECT_LOCK (self);
  gboolean passthrough = gst_vf_metal_transform_apply_locked (self) &&
      GST_VIDEO_INFO_WIDTH (in_info) == GST_VIDEO_INFO_WIDTH (out_info) &&
      GST_VIDEO_INFO_HEIGHT (in_info) == GST_VIDEO_INFO_HEIGHT (out_info);
  GST_OBJECT_UNLOCK (self);

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), passthrough);
  GST_DEBUG_OBJECT (self, "passthrough = %s", passthrough ? "TRUE" : "FALSE");

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

  /* The properties the output caps were negotiated for */
  TransformParams params;
  GST_OBJECT_LOCK (self);
  params.method = (VfMetalTransformMethod)self->applied_method;
  params.cropTop = self->applied_crop_top;
  params.cropBottom = self->applied_crop_bottom;
  params.cropLeft = self->applied_crop_left;
  params.cropRight = self->applied_crop_right;
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
  gint *field;

  switch (prop_id) {
    case PROP_METHOD:
      field = &self->method;
      break;
    case PROP_CROP_TOP:
      field = &self->crop_top;
      break;
    case PROP_CROP_BOTTOM:
      field = &self->crop_bottom;
      break;
    case PROP_CROP_LEFT:
      field = &self->crop_left;
      break;
    case PROP_CROP_RIGHT:
      field = &self->crop_right;
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }

  gint v = prop_id == PROP_METHOD ? g_value_get_enum (value) :
      g_value_get_int (value);
  GST_OBJECT_LOCK (self);
  gboolean changed = *field != v;
  *field = v;
  GST_OBJECT_UNLOCK (self);

  /* The method and the crop decide the output size and the passthrough:
   * renegotiate; set_info or before_transform applies them. */
  if (changed)
    gst_base_transform_reconfigure_src (GST_BASE_TRANSFORM (self));
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
  GstBaseTransformClass *basetransform_class = (GstBaseTransformClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_transform_set_property;
  gobject_class->get_property = gst_vf_metal_transform_get_property;
  gobject_class->finalize = gst_vf_metal_transform_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_change_state);

  basetransform_class->transform_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_transform_caps);
  basetransform_class->before_transform =
      GST_DEBUG_FUNCPTR (gst_vf_metal_transform_before_transform);

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
