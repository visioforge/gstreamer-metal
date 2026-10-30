/* GStreamer Metal video filter element
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
 * SECTION:element-vfmetalvideofilter
 * @title: vfmetalvideofilter
 *
 * Metal-accelerated video filter element providing brightness, contrast,
 * saturation, hue, gamma, sharpness/blur, sepia, invert, film grain,
 * vignette, chroma key, and 3D LUT color grading in a single GPU pass.
 *
 * When all properties are at their default values, the element operates
 * in passthrough mode (zero-copy, no GPU work).
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
 *   vfmetalvideofilter brightness=0.3 contrast=1.5 ! autovideosink
 * ]|
 * |[
 * gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
 *   vfmetalvideofilter saturation=0 sepia=1.0 ! autovideosink
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetalvideofilter.h"
#include "metalvideofilterrenderer.h"

#include <math.h>

GST_DEBUG_CATEGORY (gst_vf_metal_video_filter_debug);
#define GST_CAT_DEFAULT gst_vf_metal_video_filter_debug

#define VF_METAL_VIDEO_FILTER_FORMATS "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_VIDEO_FILTER_FORMATS))
    );

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_VIDEO_FILTER_FORMATS))
    );

enum
{
  PROP_0,
  PROP_BRIGHTNESS,
  PROP_CONTRAST,
  PROP_SATURATION,
  PROP_HUE,
  PROP_GAMMA,
  PROP_SHARPNESS,
  PROP_SEPIA,
  PROP_INVERT,
  PROP_NOISE,
  PROP_VIGNETTE,
  PROP_CHROMA_KEY_ENABLED,
  PROP_CHROMA_KEY_COLOR,
  PROP_CHROMA_KEY_TOLERANCE,
  PROP_CHROMA_KEY_SMOOTHNESS,
  PROP_LUT_FILE,
};

/* Defaults */
#define DEFAULT_BRIGHTNESS      0.0
#define DEFAULT_CONTRAST        1.0
#define DEFAULT_SATURATION      1.0
#define DEFAULT_HUE             0.0
#define DEFAULT_GAMMA           1.0
#define DEFAULT_SHARPNESS       0.0
#define DEFAULT_SEPIA           0.0
#define DEFAULT_INVERT          FALSE
#define DEFAULT_NOISE           0.0
#define DEFAULT_VIGNETTE        0.0
#define DEFAULT_CHROMA_KEY_ENABLED    FALSE
#define DEFAULT_CHROMA_KEY_COLOR      0xFF00FF00
#define DEFAULT_CHROMA_KEY_TOLERANCE  0.2
#define DEFAULT_CHROMA_KEY_SMOOTHNESS 0.1

/* --- GType boilerplate --- */

#define gst_vf_metal_video_filter_parent_class parent_class
G_DEFINE_TYPE (GstVfMetalVideoFilter, gst_vf_metal_video_filter,
    GST_TYPE_VIDEO_FILTER);

GST_ELEMENT_REGISTER_DEFINE (vfmetalvideofilter, "vfmetalvideofilter",
    GST_RANK_NONE, GST_TYPE_VF_METAL_VIDEO_FILTER);

/* --- Passthrough check --- */

#define FLOAT_EQ(a, b) (fabs((a) - (b)) < 1e-6)

static void
gst_vf_metal_video_filter_update_passthrough (GstVfMetalVideoFilter * self)
{
  /* Two threads committing at once must not set passthrough in the opposite
   * order from the one they read the settings in. set_passthrough takes the
   * object lock, so the pair needs a lock of its own. */
  g_mutex_lock (&self->passthrough_lock);
  GST_OBJECT_LOCK (self);
  gboolean passthrough =
      FLOAT_EQ(self->brightness, DEFAULT_BRIGHTNESS) &&
      FLOAT_EQ(self->contrast, DEFAULT_CONTRAST) &&
      FLOAT_EQ(self->saturation, DEFAULT_SATURATION) &&
      FLOAT_EQ(self->hue, DEFAULT_HUE) &&
      FLOAT_EQ(self->gamma, DEFAULT_GAMMA) &&
      FLOAT_EQ(self->sharpness, DEFAULT_SHARPNESS) &&
      FLOAT_EQ(self->sepia, DEFAULT_SEPIA) &&
      (self->invert == DEFAULT_INVERT) &&
      FLOAT_EQ(self->noise, DEFAULT_NOISE) &&
      FLOAT_EQ(self->vignette, DEFAULT_VIGNETTE) &&
      (!self->chroma_key_enabled) &&
      !self->lut_active;
  GST_OBJECT_UNLOCK (self);

  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), passthrough);
  GST_DEBUG_OBJECT (self, "passthrough = %s", passthrough ? "TRUE" : "FALSE");
  g_mutex_unlock (&self->passthrough_lock);
}

/* --- set_info (called when caps are negotiated) --- */

static gboolean
gst_vf_metal_video_filter_set_info (GstVideoFilter * filter,
    GstCaps * incaps, GstVideoInfo * in_info,
    GstCaps * outcaps, GstVideoInfo * out_info)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (filter);

  GST_DEBUG_OBJECT (self, "set_info: in=%" GST_PTR_FORMAT
      " out=%" GST_PTR_FORMAT, incaps, outcaps);

  if (!self->renderer)
    return FALSE;

  @autoreleasepool {
    MetalVideoFilterRenderer *renderer =
        (__bridge MetalVideoFilterRenderer *)self->renderer;
    if (![renderer configureWithInputInfo:in_info outputInfo:out_info]) {
      GST_ERROR_OBJECT (self, "Failed to configure Metal renderer");
      return FALSE;
    }
  }

  return TRUE;
}

/* --- transform_frame --- */

static GstFlowReturn
gst_vf_metal_video_filter_transform_frame (GstVideoFilter * filter,
    GstVideoFrame * inframe, GstVideoFrame * outframe)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (filter);

  if (!self->renderer) {
    GST_WARNING_OBJECT (self, "No Metal renderer available");
    return GST_FLOW_ERROR;
  }

  MetalVideoFilterRenderer *renderer =
      (__bridge MetalVideoFilterRenderer *)self->renderer;

  /* Build params struct — snapshot properties under lock */
  VideoFilterParams params;
  GST_OBJECT_LOCK (self);
  params.brightness = (float)self->brightness;
  params.contrast = (float)self->contrast;
  params.saturation = (float)self->saturation;
  params.hue = (float)(self->hue * M_PI);  /* map [-1,1] to [-pi,pi] */
  params.gamma = (float)self->gamma;
  params.sharpness = (float)self->sharpness;
  params.sepia = (float)self->sepia;
  params.noise = (float)self->noise;
  params.vignette = (float)self->vignette;
  params.invert = self->invert ? 1 : 0;
  params.chromaKeyEnabled = self->chroma_key_enabled ? 1 : 0;

  /* Extract RGB from ARGB color */
  params.chromaKeyR = ((self->chroma_key_color >> 16) & 0xFF) / 255.0f;
  params.chromaKeyG = ((self->chroma_key_color >> 8) & 0xFF) / 255.0f;
  params.chromaKeyB = (self->chroma_key_color & 0xFF) / 255.0f;
  params.chromaKeyTolerance = (float)self->chroma_key_tolerance;
  params.chromaKeySmoothness = (float)self->chroma_key_smoothness;
  /* A LUT committed with these parameters takes effect with them */
  [renderer applyStagedLUT];
  GST_OBJECT_UNLOCK (self);
  params.frameIndex = (uint32_t)(self->frame_count++);

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
gst_vf_metal_video_filter_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_BRIGHTNESS:
      self->pending_brightness = g_value_get_double (value);
      break;
    case PROP_CONTRAST:
      self->pending_contrast = g_value_get_double (value);
      break;
    case PROP_SATURATION:
      self->pending_saturation = g_value_get_double (value);
      break;
    case PROP_HUE:
      self->pending_hue = g_value_get_double (value);
      break;
    case PROP_GAMMA:
      self->pending_gamma = g_value_get_double (value);
      break;
    case PROP_SHARPNESS:
      self->pending_sharpness = g_value_get_double (value);
      break;
    case PROP_SEPIA:
      self->pending_sepia = g_value_get_double (value);
      break;
    case PROP_INVERT:
      self->pending_invert = g_value_get_boolean (value);
      break;
    case PROP_NOISE:
      self->pending_noise = g_value_get_double (value);
      break;
    case PROP_VIGNETTE:
      self->pending_vignette = g_value_get_double (value);
      break;
    case PROP_CHROMA_KEY_ENABLED:
      self->pending_chroma_key_enabled = g_value_get_boolean (value);
      break;
    case PROP_CHROMA_KEY_COLOR:
      self->pending_chroma_key_color = g_value_get_uint (value);
      break;
    case PROP_CHROMA_KEY_TOLERANCE:
      self->pending_chroma_key_tolerance = g_value_get_double (value);
      break;
    case PROP_CHROMA_KEY_SMOOTHNESS:
      self->pending_chroma_key_smoothness = g_value_get_double (value);
      break;
    case PROP_LUT_FILE:
      g_free (self->pending_lut_file);
      self->pending_lut_file = g_value_dup_string (value);
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
gst_vf_metal_video_filter_dispatch_properties_changed (GObject * object,
    guint n_pspecs, GParamSpec ** pspecs)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (object);

  /* A lut-file write with a new path, or the same one after a load that
   * failed: (re)load it. The same path loaded already is not read again, and
   * a batch without lut-file never reads the file. */
  gboolean lut_written = FALSE;
  for (guint i = 0; i < n_pspecs; i++)
    lut_written |= pspecs[i]->owner_type == GST_TYPE_VF_METAL_VIDEO_FILTER &&
        pspecs[i]->param_id == PROP_LUT_FILE;

  GST_OBJECT_LOCK (self);
  gboolean reload = lut_written &&
      (g_strcmp0 (self->lut_file, self->pending_lut_file) != 0 ||
      (!self->lut_loaded && self->pending_lut_file &&
      *self->pending_lut_file != '\0'));
  gchar *lut_file = NULL;
  guint lut_load = 0;
  if (reload) {
    g_free (self->lut_file);
    self->lut_file = g_strdup (self->pending_lut_file);
    lut_file = g_strdup (self->lut_file);
    lut_load = ++self->lut_load;
  }
  GST_OBJECT_UNLOCK (self);

  MetalVideoFilterRenderer *renderer =
      (__bridge MetalVideoFilterRenderer *)self->renderer;

  /* The file is read here, outside the lock; the renderer only gets the
   * texture on the streaming thread (transform_frame), with the parameters
   * committed below. Frames drawn while the file loads keep the old LUT and
   * the old look. A failed load keeps the old LUT. */
  gboolean clear = !lut_file || lut_file[0] == '\0';
  id<MTLTexture> lut = nil;
  int lut_size = 0;
  if (reload && renderer && !clear) {
    @autoreleasepool {
      lut = [MetalVideoFilterRenderer lutTextureFromFile:lut_file
                                                    size:&lut_size];
    }
    if (!lut)
      GST_WARNING_OBJECT (self, "Failed to load LUT: %s", lut_file);
  }

  GST_OBJECT_LOCK (self);
  /* A reload started while this file loaded wins, even for the same path */
  if (reload && lut_load == self->lut_load) {
    self->lut_loaded = lut != nil;
    if (renderer && (lut || clear)) {
      [renderer stageLUT:lut size:lut_size];
      self->lut_active = lut != nil;
    }
  }
  g_free (lut_file);
  self->brightness = self->pending_brightness;
  self->contrast = self->pending_contrast;
  self->saturation = self->pending_saturation;
  self->hue = self->pending_hue;
  self->gamma = self->pending_gamma;
  self->sharpness = self->pending_sharpness;
  self->sepia = self->pending_sepia;
  self->invert = self->pending_invert;
  self->noise = self->pending_noise;
  self->vignette = self->pending_vignette;
  self->chroma_key_enabled = self->pending_chroma_key_enabled;
  self->chroma_key_color = self->pending_chroma_key_color;
  self->chroma_key_tolerance = self->pending_chroma_key_tolerance;
  self->chroma_key_smoothness = self->pending_chroma_key_smoothness;
  GST_OBJECT_UNLOCK (self);

  gst_vf_metal_video_filter_update_passthrough (self);

  G_OBJECT_CLASS (parent_class)->dispatch_properties_changed (object,
      n_pspecs, pspecs);
}

static void
gst_vf_metal_video_filter_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (object);

  GST_OBJECT_LOCK (self);
  switch (prop_id) {
    case PROP_BRIGHTNESS:
      g_value_set_double (value, self->pending_brightness);
      break;
    case PROP_CONTRAST:
      g_value_set_double (value, self->pending_contrast);
      break;
    case PROP_SATURATION:
      g_value_set_double (value, self->pending_saturation);
      break;
    case PROP_HUE:
      g_value_set_double (value, self->pending_hue);
      break;
    case PROP_GAMMA:
      g_value_set_double (value, self->pending_gamma);
      break;
    case PROP_SHARPNESS:
      g_value_set_double (value, self->pending_sharpness);
      break;
    case PROP_SEPIA:
      g_value_set_double (value, self->pending_sepia);
      break;
    case PROP_INVERT:
      g_value_set_boolean (value, self->pending_invert);
      break;
    case PROP_NOISE:
      g_value_set_double (value, self->pending_noise);
      break;
    case PROP_VIGNETTE:
      g_value_set_double (value, self->pending_vignette);
      break;
    case PROP_CHROMA_KEY_ENABLED:
      g_value_set_boolean (value, self->pending_chroma_key_enabled);
      break;
    case PROP_CHROMA_KEY_COLOR:
      g_value_set_uint (value, self->pending_chroma_key_color);
      break;
    case PROP_CHROMA_KEY_TOLERANCE:
      g_value_set_double (value, self->pending_chroma_key_tolerance);
      break;
    case PROP_CHROMA_KEY_SMOOTHNESS:
      g_value_set_double (value, self->pending_chroma_key_smoothness);
      break;
    case PROP_LUT_FILE:
      g_value_set_string (value, self->pending_lut_file);
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
gst_vf_metal_video_filter_change_state (GstElement * element,
    GstStateChange transition)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (element);
  GstStateChangeReturn ret;

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  switch (transition) {
    case GST_STATE_CHANGE_PAUSED_TO_READY:
      if (self->renderer) {
        @autoreleasepool {
          MetalVideoFilterRenderer *renderer =
              (__bridge MetalVideoFilterRenderer *)self->renderer;
          [renderer cleanup];
        }
      }
      self->frame_count = 0;
      break;
    default:
      break;
  }

  return ret;
}

/* --- Finalize --- */

static void
gst_vf_metal_video_filter_finalize (GObject * object)
{
  GstVfMetalVideoFilter *self = GST_VF_METAL_VIDEO_FILTER (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalVideoFilterRenderer *renderer =
          (__bridge_transfer MetalVideoFilterRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  g_free (self->lut_file);
  self->lut_file = NULL;
  g_free (self->pending_lut_file);
  self->pending_lut_file = NULL;
  g_mutex_clear (&self->passthrough_lock);

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- class_init --- */

static void
gst_vf_metal_video_filter_class_init (GstVfMetalVideoFilterClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstVideoFilterClass *gstvideofilter_class = (GstVideoFilterClass *) klass;

  gobject_class->set_property = gst_vf_metal_video_filter_set_property;
  gobject_class->get_property = gst_vf_metal_video_filter_get_property;
  gobject_class->finalize = gst_vf_metal_video_filter_finalize;
  gobject_class->dispatch_properties_changed =
      gst_vf_metal_video_filter_dispatch_properties_changed;

  gstelement_class->change_state =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_filter_change_state);

  gstvideofilter_class->set_info =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_filter_set_info);
  gstvideofilter_class->transform_frame =
      GST_DEBUG_FUNCPTR (gst_vf_metal_video_filter_transform_frame);

  /* --- Install properties --- */

  g_object_class_install_property (gobject_class, PROP_BRIGHTNESS,
      g_param_spec_double ("brightness", "Brightness",
          "Brightness adjustment (-1.0 to 1.0)",
          -1.0, 1.0, DEFAULT_BRIGHTNESS,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_CONTRAST,
      g_param_spec_double ("contrast", "Contrast",
          "Contrast adjustment (0.0 to 2.0, 1.0 = normal)",
          0.0, 2.0, DEFAULT_CONTRAST,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_SATURATION,
      g_param_spec_double ("saturation", "Saturation",
          "Color saturation (0.0 = grayscale, 1.0 = normal, 2.0 = oversaturated)",
          0.0, 2.0, DEFAULT_SATURATION,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_HUE,
      g_param_spec_double ("hue", "Hue",
          "Hue rotation (-1.0 to 1.0, mapped to -180 to +180 degrees)",
          -1.0, 1.0, DEFAULT_HUE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_GAMMA,
      g_param_spec_double ("gamma", "Gamma",
          "Gamma correction (0.01 to 10.0, 1.0 = normal)",
          0.01, 10.0, DEFAULT_GAMMA,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_SHARPNESS,
      g_param_spec_double ("sharpness", "Sharpness",
          "Sharpness adjustment (-1.0 = maximum blur, 0.0 = none, 1.0 = maximum sharpen)",
          -1.0, 1.0, DEFAULT_SHARPNESS,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_SEPIA,
      g_param_spec_double ("sepia", "Sepia",
          "Sepia tone mix amount (0.0 = none, 1.0 = full sepia)",
          0.0, 1.0, DEFAULT_SEPIA,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_INVERT,
      g_param_spec_boolean ("invert", "Invert",
          "Invert all colors (negative image)",
          DEFAULT_INVERT,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_NOISE,
      g_param_spec_double ("noise", "Noise",
          "Film grain / noise amount (0.0 = none, 1.0 = maximum)",
          0.0, 1.0, DEFAULT_NOISE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_VIGNETTE,
      g_param_spec_double ("vignette", "Vignette",
          "Vignette darkness (0.0 = none, 1.0 = maximum darkening at edges)",
          0.0, 1.0, DEFAULT_VIGNETTE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  g_object_class_install_property (gobject_class, PROP_CHROMA_KEY_ENABLED,
      g_param_spec_boolean ("chroma-key-enabled", "Chroma Key Enabled",
          "Enable chroma key (green screen) removal",
          DEFAULT_CHROMA_KEY_ENABLED,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CHROMA_KEY_COLOR,
      g_param_spec_uint ("chroma-key-color", "Chroma Key Color",
          "Chroma key color in ARGB format (default: green 0xFF00FF00)",
          0, G_MAXUINT32, DEFAULT_CHROMA_KEY_COLOR,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CHROMA_KEY_TOLERANCE,
      g_param_spec_double ("chroma-key-tolerance", "Chroma Key Tolerance",
          "Color distance threshold for chroma key (0.0 to 1.0)",
          0.0, 1.0, DEFAULT_CHROMA_KEY_TOLERANCE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CHROMA_KEY_SMOOTHNESS,
      g_param_spec_double ("chroma-key-smoothness", "Chroma Key Smoothness",
          "Edge softness for chroma key transition (0.0 to 1.0)",
          0.0, 1.0, DEFAULT_CHROMA_KEY_SMOOTHNESS,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_LUT_FILE,
      g_param_spec_string ("lut-file", "LUT File",
          "Path to a .cube or .png 3D LUT file for color grading",
          NULL,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  /* Pad templates */
  gst_element_class_add_static_pad_template (gstelement_class, &sink_template);
  gst_element_class_add_static_pad_template (gstelement_class, &src_template);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Filter",
      "Filter/Effect/Video",
      "Metal-accelerated video filter with color adjustments, effects, "
      "chroma key, and 3D LUT support",
      "VisioForge <support@visioforge.com>");

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_video_filter_debug,
      "vfmetalvideofilter", 0, "Metal video filter");
}

/* --- init --- */

static void
gst_vf_metal_video_filter_init (GstVfMetalVideoFilter * self)
{
  self->brightness = DEFAULT_BRIGHTNESS;
  self->contrast = DEFAULT_CONTRAST;
  self->saturation = DEFAULT_SATURATION;
  self->hue = DEFAULT_HUE;
  self->gamma = DEFAULT_GAMMA;
  self->sharpness = DEFAULT_SHARPNESS;
  self->sepia = DEFAULT_SEPIA;
  self->invert = DEFAULT_INVERT;
  self->noise = DEFAULT_NOISE;
  self->vignette = DEFAULT_VIGNETTE;
  self->chroma_key_enabled = DEFAULT_CHROMA_KEY_ENABLED;
  self->chroma_key_color = DEFAULT_CHROMA_KEY_COLOR;
  self->chroma_key_tolerance = DEFAULT_CHROMA_KEY_TOLERANCE;
  self->chroma_key_smoothness = DEFAULT_CHROMA_KEY_SMOOTHNESS;
  self->lut_file = NULL;
  self->pending_brightness = self->brightness;
  self->pending_contrast = self->contrast;
  self->pending_saturation = self->saturation;
  self->pending_hue = self->hue;
  self->pending_gamma = self->gamma;
  self->pending_sharpness = self->sharpness;
  self->pending_sepia = self->sepia;
  self->pending_invert = self->invert;
  self->pending_noise = self->noise;
  self->pending_vignette = self->vignette;
  self->pending_chroma_key_enabled = self->chroma_key_enabled;
  self->pending_chroma_key_color = self->chroma_key_color;
  self->pending_chroma_key_tolerance = self->chroma_key_tolerance;
  self->pending_chroma_key_smoothness = self->chroma_key_smoothness;
  self->pending_lut_file = NULL;
  self->lut_loaded = FALSE;
  self->lut_active = FALSE;
  self->frame_count = 0;
  g_mutex_init (&self->passthrough_lock);

  @autoreleasepool {
    MetalVideoFilterRenderer *renderer =
        [[MetalVideoFilterRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self,
          "Failed to create Metal renderer — no Metal device");
    }
  }

  /* Start in passthrough mode (all defaults) */
  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), TRUE);
}
