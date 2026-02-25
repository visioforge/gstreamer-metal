/* GStreamer Metal video convert and scale element
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
 * SECTION:element-vfmetalconvertscale
 * @title: vfmetalconvertscale
 *
 * Metal-accelerated video format conversion and scaling element.
 * Combines the functionality of videoconvert + videoscale in a single
 * GPU pass. Supports BGRA, RGBA, NV12, I420, UYVY, and YUY2 with
 * bilinear or nearest-neighbor interpolation and optional letterboxing.
 *
 * When input and output format and dimensions are identical, the element
 * operates in passthrough mode (zero-copy).
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
 *   vfmetalconvertscale ! video/x-raw,format=BGRA,width=640,height=480 ! autovideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetalconvertscale.h"
#include "metalconvertscalerenderer.h"

GST_DEBUG_CATEGORY (gst_vf_metal_convertscale_debug);
#define GST_CAT_DEFAULT gst_vf_metal_convertscale_debug

#define VF_METAL_CONVERTSCALE_FORMATS "{ BGRA, RGBA, NV12, I420, UYVY, YUY2 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_CONVERTSCALE_FORMATS))
    );

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_CONVERTSCALE_FORMATS))
    );

enum
{
  PROP_0,
  PROP_METHOD,
  PROP_ADD_BORDERS,
  PROP_BORDER_COLOR,
};

#define DEFAULT_METHOD          0   /* bilinear */
#define DEFAULT_ADD_BORDERS     FALSE
#define DEFAULT_BORDER_COLOR    0xFF000000  /* opaque black */

/* Scaling method enum type */
#define GST_TYPE_VF_METAL_SCALE_METHOD (gst_vf_metal_scale_method_get_type())

GType
gst_vf_metal_scale_method_get_type (void)
{
  static gsize type_value = 0;
  static const GEnumValue methods[] = {
    {0, "Bilinear interpolation", "bilinear"},
    {1, "Nearest-neighbor", "nearest"},
    {0, NULL, NULL}
  };

  if (g_once_init_enter (&type_value)) {
    GType t = g_enum_register_static ("GstVfMetalScaleMethod", methods);
    g_once_init_leave (&type_value, t);
  }
  return (GType) type_value;
}

/* --- GType boilerplate --- */

#define gst_vf_metal_convertscale_parent_class parent_class
G_DEFINE_TYPE (GstVfMetalConvertScale, gst_vf_metal_convertscale,
    GST_TYPE_BASE_TRANSFORM);

GST_ELEMENT_REGISTER_DEFINE (vfmetalconvertscale, "vfmetalconvertscale",
    GST_RANK_NONE, GST_TYPE_VF_METAL_CONVERTSCALE);

/* --- Caps negotiation --- */

static GstCaps *
gst_vf_metal_convertscale_transform_caps (GstBaseTransform * trans,
    GstPadDirection direction, GstCaps * caps, GstCaps * filter)
{
  GstCaps *result;
  GstStructure *s;
  gint i, n;

  result = gst_caps_new_empty ();
  n = gst_caps_get_size (caps);

  for (i = 0; i < n; i++) {
    s = gst_caps_get_structure (caps, i);
    s = gst_structure_copy (s);

    /* Remove format, width, height constraints — we can convert any to any */
    gst_structure_remove_fields (s, "format", "width", "height",
        "pixel-aspect-ratio", "colorimetry", "chroma-site", NULL);

    /* Set all supported formats */
    GValue formats = G_VALUE_INIT;
    GValue val = G_VALUE_INIT;
    g_value_init (&formats, GST_TYPE_LIST);
    g_value_init (&val, G_TYPE_STRING);

    const char *fmt_list[] = {
        "BGRA", "RGBA", "NV12", "I420", "UYVY", "YUY2", NULL
    };
    for (int f = 0; fmt_list[f]; f++) {
      g_value_set_string (&val, fmt_list[f]);
      gst_value_list_append_value (&formats, &val);
    }
    gst_structure_set_value (s, "format", &formats);
    g_value_unset (&formats);
    g_value_unset (&val);

    /* Allow any width/height */
    gst_structure_set (s,
        "width", GST_TYPE_INT_RANGE, 1, G_MAXINT,
        "height", GST_TYPE_INT_RANGE, 1, G_MAXINT,
        NULL);

    gst_caps_append_structure (result, s);
  }

  if (filter) {
    GstCaps *intersection =
        gst_caps_intersect_full (result, filter, GST_CAPS_INTERSECT_FIRST);
    gst_caps_unref (result);
    result = intersection;
  }

  return result;
}

static GstCaps *
gst_vf_metal_convertscale_fixate_caps (GstBaseTransform * trans,
    GstPadDirection direction, GstCaps * caps, GstCaps * othercaps)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (trans);
  GstStructure *ins, *outs;
  const GValue *from_par, *to_par;
  gint from_w, from_h, from_par_n, from_par_d;
  gint to_par_n, to_par_d;
  gint from_dar_n, from_dar_d;
  gint w = 0, h = 0;

  othercaps = gst_caps_truncate (othercaps);
  othercaps = gst_caps_make_writable (othercaps);

  GST_DEBUG_OBJECT (self, "fixating othercaps %" GST_PTR_FORMAT
      " based on caps %" GST_PTR_FORMAT, othercaps, caps);

  ins = gst_caps_get_structure (caps, 0);
  outs = gst_caps_get_structure (othercaps, 0);

  /* Try to preserve format if possible */
  {
    const GValue *format = gst_structure_get_value (ins, "format");
    if (format && G_VALUE_HOLDS_STRING (format)) {
      gst_structure_fixate_field_string (outs, "format",
          g_value_get_string (format));
    }
  }

  /* Get input dimensions */
  gst_structure_get_int (ins, "width", &from_w);
  gst_structure_get_int (ins, "height", &from_h);

  from_par = gst_structure_get_value (ins, "pixel-aspect-ratio");
  to_par = gst_structure_get_value (outs, "pixel-aspect-ratio");

  if (from_par && GST_VALUE_HOLDS_FRACTION (from_par)) {
    from_par_n = gst_value_get_fraction_numerator (from_par);
    from_par_d = gst_value_get_fraction_denominator (from_par);
  } else {
    from_par_n = from_par_d = 1;
  }

  if (to_par && GST_VALUE_HOLDS_FRACTION (to_par)) {
    to_par_n = gst_value_get_fraction_numerator (to_par);
    to_par_d = gst_value_get_fraction_denominator (to_par);
  } else {
    to_par_n = to_par_d = 1;
  }

  /* Compute input display aspect ratio (DAR) = (width * PAR_n) / (height * PAR_d) */
  if (!gst_util_fraction_multiply (from_w, from_h, from_par_n, from_par_d,
          &from_dar_n, &from_dar_d)) {
    from_dar_n = from_w;
    from_dar_d = from_h;
  }

  /* Fixate output dimensions preserving DAR, adjusted for output PAR */
  {
    gboolean w_fixed = gst_structure_get_int (outs, "width", &w);
    gboolean h_fixed = gst_structure_get_int (outs, "height", &h);

    if (!w_fixed && !h_fixed) {
      /* Neither fixed — keep input width, compute height from DAR + output PAR */
      gst_structure_fixate_field_nearest_int (outs, "width", from_w);
      gst_structure_get_int (outs, "width", &w);
      h = (gint) gst_util_uint64_scale_int (w, from_dar_d * to_par_n,
          from_dar_n * to_par_d);
      gst_structure_fixate_field_nearest_int (outs, "height", MAX (h, 1));
    } else if (w_fixed && !h_fixed) {
      /* Width fixed — compute height from DAR + output PAR */
      h = (gint) gst_util_uint64_scale_int (w, from_dar_d * to_par_n,
          from_dar_n * to_par_d);
      gst_structure_fixate_field_nearest_int (outs, "height", MAX (h, 1));
    } else if (!w_fixed && h_fixed) {
      /* Height fixed — compute width from DAR + output PAR */
      w = (gint) gst_util_uint64_scale_int (h, from_dar_n * to_par_d,
          from_dar_d * to_par_n);
      gst_structure_fixate_field_nearest_int (outs, "width", MAX (w, 1));
    }
    /* else: both fixed, nothing to do */
  }

  /* Fixate remaining fields */
  othercaps = gst_caps_fixate (othercaps);

  return othercaps;
}

static gboolean
gst_vf_metal_convertscale_set_caps (GstBaseTransform * trans,
    GstCaps * incaps, GstCaps * outcaps)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (trans);

  GST_DEBUG_OBJECT (self, "set_caps: in=%" GST_PTR_FORMAT
      " out=%" GST_PTR_FORMAT, incaps, outcaps);

  if (!gst_video_info_from_caps (&self->in_info, incaps)) {
    GST_ERROR_OBJECT (self, "Failed to parse input caps");
    return FALSE;
  }

  if (!gst_video_info_from_caps (&self->out_info, outcaps)) {
    GST_ERROR_OBJECT (self, "Failed to parse output caps");
    return FALSE;
  }

  self->negotiated = TRUE;

  /* Check passthrough: same format + same size = zero-copy */
  GstVideoFormat inFmt = GST_VIDEO_INFO_FORMAT (&self->in_info);
  GstVideoFormat outFmt = GST_VIDEO_INFO_FORMAT (&self->out_info);
  gint inW = GST_VIDEO_INFO_WIDTH (&self->in_info);
  gint inH = GST_VIDEO_INFO_HEIGHT (&self->in_info);
  gint outW = GST_VIDEO_INFO_WIDTH (&self->out_info);
  gint outH = GST_VIDEO_INFO_HEIGHT (&self->out_info);

  gboolean passthrough = (inFmt == outFmt && inW == outW && inH == outH);
  gst_base_transform_set_passthrough (trans, passthrough);

  GST_DEBUG_OBJECT (self, "passthrough = %s, %s %dx%d -> %s %dx%d",
      passthrough ? "TRUE" : "FALSE",
      gst_video_format_to_string (inFmt), inW, inH,
      gst_video_format_to_string (outFmt), outW, outH);

  if (!passthrough && self->renderer) {
    @autoreleasepool {
      MetalConvertScaleRenderer *renderer =
          (__bridge MetalConvertScaleRenderer *)self->renderer;
      if (![renderer configureWithInputInfo:&self->in_info
                                 outputInfo:&self->out_info
                                     method:(VfMetalScaleMethod)self->method
                                 addBorders:self->add_borders
                                borderColor:self->border_color]) {
        GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
        return FALSE;
      }
    }
  }

  return TRUE;
}

static gboolean
gst_vf_metal_convertscale_get_unit_size (GstBaseTransform * trans,
    GstCaps * caps, gsize * size)
{
  GstVideoInfo info;

  if (!gst_video_info_from_caps (&info, caps)) {
    GST_ERROR_OBJECT (trans, "Failed to parse caps for unit size");
    return FALSE;
  }

  *size = GST_VIDEO_INFO_SIZE (&info);
  return TRUE;
}

/* --- transform --- */

static GstFlowReturn
gst_vf_metal_convertscale_transform (GstBaseTransform * trans,
    GstBuffer * inbuf, GstBuffer * outbuf)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (trans);
  GstVideoFrame inframe, outframe;

  if (!self->negotiated) {
    GST_ERROR_OBJECT (self, "Not yet negotiated");
    return GST_FLOW_NOT_NEGOTIATED;
  }

  if (!self->renderer) {
    GST_WARNING_OBJECT (self, "No Metal renderer available");
    return GST_FLOW_ERROR;
  }

  if (!gst_video_frame_map (&inframe, &self->in_info, inbuf, GST_MAP_READ)) {
    GST_ERROR_OBJECT (self, "Failed to map input buffer");
    return GST_FLOW_ERROR;
  }

  if (!gst_video_frame_map (&outframe, &self->out_info, outbuf,
          GST_MAP_WRITE)) {
    gst_video_frame_unmap (&inframe);
    GST_ERROR_OBJECT (self, "Failed to map output buffer");
    return GST_FLOW_ERROR;
  }

  MetalConvertScaleRenderer *renderer =
      (__bridge MetalConvertScaleRenderer *)self->renderer;

  @autoreleasepool {
    if (![renderer processFrame:&inframe output:&outframe]) {
      gst_video_frame_unmap (&outframe);
      gst_video_frame_unmap (&inframe);
      GST_WARNING_OBJECT (self, "Metal rendering failed");
      return GST_FLOW_ERROR;
    }
  }

  gst_video_frame_unmap (&outframe);
  gst_video_frame_unmap (&inframe);

  return GST_FLOW_OK;
}

/* --- Properties --- */

static void
gst_vf_metal_convertscale_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (object);

  switch (prop_id) {
    case PROP_METHOD:
      self->method = g_value_get_enum (value);
      break;
    case PROP_ADD_BORDERS:
      self->add_borders = g_value_get_boolean (value);
      break;
    case PROP_BORDER_COLOR:
      self->border_color = g_value_get_uint (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      return;
  }

  /* Reconfigure if caps already negotiated */
  if (self->negotiated && self->renderer) {
    @autoreleasepool {
      MetalConvertScaleRenderer *renderer =
          (__bridge MetalConvertScaleRenderer *)self->renderer;
      [renderer configureWithInputInfo:&self->in_info
                            outputInfo:&self->out_info
                                method:(VfMetalScaleMethod)self->method
                            addBorders:self->add_borders
                           borderColor:self->border_color];
    }
  }
}

static void
gst_vf_metal_convertscale_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (object);

  switch (prop_id) {
    case PROP_METHOD:
      g_value_set_enum (value, self->method);
      break;
    case PROP_ADD_BORDERS:
      g_value_set_boolean (value, self->add_borders);
      break;
    case PROP_BORDER_COLOR:
      g_value_set_uint (value, self->border_color);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

/* --- State change --- */

static GstStateChangeReturn
gst_vf_metal_convertscale_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (element);
  GstStateChangeReturn ret;

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalConvertScaleRenderer *renderer =
              (__bridge MetalConvertScaleRenderer *)self->renderer;
          [renderer cleanup];
        }
      }
      self->negotiated = FALSE;
      break;
    default:
      break;
  }

  return ret;
}

/* --- Finalize --- */

static void
gst_vf_metal_convertscale_finalize (GObject * object)
{
  GstVfMetalConvertScale *self = GST_VF_METAL_CONVERTSCALE (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalConvertScaleRenderer *renderer =
          (__bridge_transfer MetalConvertScaleRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- class_init --- */

static void
gst_vf_metal_convertscale_class_init (GstVfMetalConvertScaleClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstBaseTransformClass *basetransform_class =
      (GstBaseTransformClass *) klass;

  gobject_class->set_property = gst_vf_metal_convertscale_set_property;
  gobject_class->get_property = gst_vf_metal_convertscale_get_property;
  gobject_class->finalize = gst_vf_metal_convertscale_finalize;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_change_state);

  basetransform_class->transform_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_transform_caps);
  basetransform_class->fixate_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_fixate_caps);
  basetransform_class->set_caps =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_set_caps);
  basetransform_class->get_unit_size =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_get_unit_size);
  basetransform_class->transform =
      GST_DEBUG_FUNCPTR (gst_vf_metal_convertscale_transform);

  /* We handle passthrough ourselves */
  basetransform_class->passthrough_on_same_caps = FALSE;

  /* --- Install properties --- */

  g_object_class_install_property (gobject_class, PROP_METHOD,
      g_param_spec_enum ("method", "Method",
          "Scaling interpolation method",
          GST_TYPE_VF_METAL_SCALE_METHOD, DEFAULT_METHOD,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_ADD_BORDERS,
      g_param_spec_boolean ("add-borders", "Add Borders",
          "Add letterbox/pillarbox borders to preserve aspect ratio",
          DEFAULT_ADD_BORDERS,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_BORDER_COLOR,
      g_param_spec_uint ("border-color", "Border Color",
          "Border color in ARGB format (default: opaque black 0xFF000000)",
          0, G_MAXUINT32, DEFAULT_BORDER_COLOR,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  /* Pad templates */
  gst_element_class_add_static_pad_template (gstelement_class, &sink_template);
  gst_element_class_add_static_pad_template (gstelement_class, &src_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Convert and Scale",
      "Filter/Converter/Video/Scaler",
      "Metal-accelerated video format conversion and scaling",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_convertscale_debug,
      "vfmetalconvertscale", 0, "Metal video convert and scale");
}

/* --- init --- */

static void
gst_vf_metal_convertscale_init (GstVfMetalConvertScale * self)
{
  self->method = DEFAULT_METHOD;
  self->add_borders = DEFAULT_ADD_BORDERS;
  self->border_color = DEFAULT_BORDER_COLOR;
  self->negotiated = FALSE;

  @autoreleasepool {
    MetalConvertScaleRenderer *renderer =
        [[MetalConvertScaleRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self,
          "Failed to create Metal renderer — no Metal device");
    }
  }
}
