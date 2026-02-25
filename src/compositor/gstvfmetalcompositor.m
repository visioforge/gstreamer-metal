/* GStreamer Metal video compositor element
 *
 * Copyright (C) 2026 Roman Miniailov
 * Author: Roman Miniailov <miniailovr@gmail.com>
 *
 * Based on GStreamer compositor by:
 *   Wim Taymans <wim@fluendo.com>
 *   Sebastian Dröge <sebastian.droege@collabora.co.uk>
 *   Mathieu Duponchelle <mathieu.duponchelle@opencreed.com>
 *   Thibault Saunier <tsaunier@gnome.org>
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
 * SECTION:element-vfmetalcompositor
 * @title: vfmetalcompositor
 *
 * Metal-accelerated compositor that can accept BGRA and RGBA video streams.
 * For each of the requested sink pads it will compare the incoming geometry
 * and framerate to define the output parameters. Output video frames will
 * have the geometry of the biggest incoming video stream and the framerate
 * of the fastest incoming one.
 *
 * Individual parameters for each input stream can be configured on the
 * #GstVfMetalCompositorPad:
 *
 * * "xpos": The x-coordinate position of the top-left corner
 * * "ypos": The y-coordinate position of the top-left corner
 * * "width": The width of the picture (input will be scaled)
 * * "height": The height of the picture (input will be scaled)
 * * "alpha": The transparency of the picture; between 0.0 and 1.0
 * * "zorder": The z-order position of the picture in the composition
 *
 * ## Sample pipelines
 * |[
 * gst-launch-1.0 \
 *   videotestsrc pattern=snow ! video/x-raw,format=BGRA,width=320,height=240 ! \
 *   vfmetalcompositor name=comp sink_0::alpha=0.7 sink_1::xpos=160 sink_1::ypos=120 ! \
 *   videoconvert ! autovideosink \
 *   videotestsrc pattern=smpte ! video/x-raw,format=BGRA,width=320,height=240 ! comp.
 * ]|
 */

#import <Foundation/Foundation.h>
#include "gstvfmetalcompositor.h"
#include "metalcomprenderer.h"

GST_DEBUG_CATEGORY (gst_vf_metal_compositor_debug);
#define GST_CAT_DEFAULT gst_vf_metal_compositor_debug

#define VF_METAL_COMPOSITOR_SINK_FORMATS "{ BGRA, RGBA, NV12, I420 }"
#define VF_METAL_COMPOSITOR_SRC_FORMATS  "{ BGRA, RGBA, NV12, I420 }"

static GstStaticPadTemplate src_factory = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_COMPOSITOR_SRC_FORMATS))
    );

static GstStaticPadTemplate sink_factory = GST_STATIC_PAD_TEMPLATE ("sink_%u",
    GST_PAD_SINK,
    GST_PAD_REQUEST,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE (VF_METAL_COMPOSITOR_SINK_FORMATS))
    );

static void gst_vf_metal_compositor_child_proxy_init (gpointer g_iface,
    gpointer iface_data);

/* --- Enum GType registration --- */

#define GST_TYPE_VF_METAL_COMPOSITOR_OPERATOR (gst_vf_metal_compositor_operator_get_type())
GType
gst_vf_metal_compositor_operator_get_type (void)
{
  static gsize type_value = 0;
  static const GEnumValue values[] = {
    {VF_METAL_COMPOSITOR_OPERATOR_SOURCE, "Source", "source"},
    {VF_METAL_COMPOSITOR_OPERATOR_OVER, "Over", "over"},
    {VF_METAL_COMPOSITOR_OPERATOR_ADD, "Add", "add"},
    {0, NULL, NULL},
  };
  if (g_once_init_enter (&type_value)) {
    GType t = g_enum_register_static ("GstVfMetalCompositorOperator", values);
    g_once_init_leave (&type_value, t);
  }
  return type_value;
}

#define GST_TYPE_VF_METAL_COMPOSITOR_BACKGROUND (gst_vf_metal_compositor_background_get_type())
static GType
gst_vf_metal_compositor_background_get_type (void)
{
  static gsize type_value = 0;
  static const GEnumValue values[] = {
    {VF_METAL_COMPOSITOR_BACKGROUND_CHECKER, "Checker pattern", "checker"},
    {VF_METAL_COMPOSITOR_BACKGROUND_BLACK, "Black", "black"},
    {VF_METAL_COMPOSITOR_BACKGROUND_WHITE, "White", "white"},
    {VF_METAL_COMPOSITOR_BACKGROUND_TRANSPARENT,
        "Transparent Background to enable further compositing", "transparent"},
    {0, NULL, NULL},
  };
  if (g_once_init_enter (&type_value)) {
    GType t = g_enum_register_static ("GstVfMetalCompositorBackground", values);
    g_once_init_leave (&type_value, t);
  }
  return type_value;
}

#define GST_TYPE_VF_METAL_COMPOSITOR_SIZING_POLICY (gst_vf_metal_compositor_sizing_policy_get_type())
GType
gst_vf_metal_compositor_sizing_policy_get_type (void)
{
  static gsize type_value = 0;
  static const GEnumValue values[] = {
    {VF_METAL_COMPOSITOR_SIZING_POLICY_NONE,
        "None: Image is scaled to fill configured destination rectangle without "
          "padding or keeping the aspect ratio", "none"},
    {VF_METAL_COMPOSITOR_SIZING_POLICY_KEEP_ASPECT_RATIO,
          "Keep Aspect Ratio: Image is scaled to fit destination rectangle "
          "with preserved aspect ratio. Resulting image will be centered "
          "with padding if necessary",
        "keep-aspect-ratio"},
    {0, NULL, NULL},
  };
  if (g_once_init_enter (&type_value)) {
    GType t =
        g_enum_register_static ("GstVfMetalCompositorSizingPolicy", values);
    g_once_init_leave (&type_value, t);
  }
  return type_value;
}

/* --- Element property IDs --- */

enum
{
  PROP_0,
  PROP_BACKGROUND,
  PROP_ZERO_SIZE_IS_UNSCALED,
  PROP_IGNORE_INACTIVE_PADS,
};

#define DEFAULT_BACKGROUND VF_METAL_COMPOSITOR_BACKGROUND_CHECKER
#define DEFAULT_ZERO_SIZE_IS_UNSCALED TRUE

/* --- Forward declarations --- */

void gst_vf_metal_compositor_pad_get_output_size (GstVfMetalCompositor * comp,
    GstVfMetalCompositorPad * comp_pad, gint out_par_n, gint out_par_d,
    gint * width, gint * height, gint * x_offset, gint * y_offset);
gboolean gst_vf_metal_compositor_pad_obscures_rectangle (GstVideoAggregator * vagg,
    GstVideoAggregatorPad * pad, const GstVideoRectangle rect);
static gboolean _should_draw_background (GstVideoAggregator * vagg);

/* --- GType boilerplate --- */

#define gst_vf_metal_compositor_parent_class parent_class
G_DEFINE_TYPE_WITH_CODE (GstVfMetalCompositor, gst_vf_metal_compositor,
    GST_TYPE_VIDEO_AGGREGATOR,
    G_IMPLEMENT_INTERFACE (GST_TYPE_CHILD_PROXY,
        gst_vf_metal_compositor_child_proxy_init));

GST_ELEMENT_REGISTER_DEFINE (vfmetalcompositor, "vfmetalcompositor",
    GST_RANK_PRIMARY + 2, GST_TYPE_VF_METAL_COMPOSITOR);

/* --- Geometry helpers (ported from original compositor) --- */

static gboolean
is_point_contained (const GstVideoRectangle rect, const gint px, const gint py)
{
  if ((px >= rect.x) && (px < rect.x + rect.w) &&
      (py >= rect.y) && (py < rect.y + rect.h))
    return TRUE;
  return FALSE;
}

static gboolean
is_rectangle_contained (const GstVideoRectangle rect1,
    const GstVideoRectangle rect2)
{
  if ((rect2.x <= rect1.x) && (rect2.y <= rect1.y) &&
      ((rect2.x + rect2.w) >= (rect1.x + rect1.w)) &&
      ((rect2.y + rect2.h) >= (rect1.y + rect1.h)))
    return TRUE;
  return FALSE;
}

void
gst_vf_metal_compositor_pad_get_output_size (GstVfMetalCompositor * comp,
    GstVfMetalCompositorPad * comp_pad, gint out_par_n, gint out_par_d,
    gint * width, gint * height, gint * x_offset, gint * y_offset)
{
  GstVideoAggregatorPad *vagg_pad = GST_VIDEO_AGGREGATOR_PAD (comp_pad);
  gint pad_width, pad_height;
  guint dar_n, dar_d;

  *x_offset = 0;
  *y_offset = 0;
  *width = 0;
  *height = 0;

  if (!vagg_pad->info.finfo
      || vagg_pad->info.finfo->format == GST_VIDEO_FORMAT_UNKNOWN) {
    GST_DEBUG_OBJECT (comp_pad, "Have no caps yet");
    return;
  }

  if (comp->zero_size_is_unscaled) {
    pad_width =
        comp_pad->width <=
        0 ? GST_VIDEO_INFO_WIDTH (&vagg_pad->info) : comp_pad->width;
    pad_height =
        comp_pad->height <=
        0 ? GST_VIDEO_INFO_HEIGHT (&vagg_pad->info) : comp_pad->height;
  } else {
    pad_width =
        comp_pad->width <
        0 ? GST_VIDEO_INFO_WIDTH (&vagg_pad->info) : comp_pad->width;
    pad_height =
        comp_pad->height <
        0 ? GST_VIDEO_INFO_HEIGHT (&vagg_pad->info) : comp_pad->height;
  }

  if (pad_width == 0 || pad_height == 0)
    return;

  if (!gst_video_calculate_display_ratio (&dar_n, &dar_d, pad_width, pad_height,
          GST_VIDEO_INFO_PAR_N (&vagg_pad->info),
          GST_VIDEO_INFO_PAR_D (&vagg_pad->info), out_par_n, out_par_d)) {
    GST_WARNING_OBJECT (comp_pad, "Cannot calculate display aspect ratio");
    return;
  }

  GST_LOG_OBJECT (comp_pad, "scaling %ux%u by %u/%u (%u/%u / %u/%u)",
      pad_width, pad_height, dar_n, dar_d,
      GST_VIDEO_INFO_PAR_N (&vagg_pad->info),
      GST_VIDEO_INFO_PAR_D (&vagg_pad->info), out_par_n, out_par_d);

  switch (comp_pad->sizing_policy) {
    case VF_METAL_COMPOSITOR_SIZING_POLICY_NONE:
      if (pad_height % dar_n == 0) {
        pad_width = gst_util_uint64_scale_int (pad_height, dar_n, dar_d);
      } else if (pad_width % dar_d == 0) {
        pad_height = gst_util_uint64_scale_int (pad_width, dar_d, dar_n);
      } else {
        pad_width = gst_util_uint64_scale_int (pad_height, dar_n, dar_d);
      }
      break;
    case VF_METAL_COMPOSITOR_SIZING_POLICY_KEEP_ASPECT_RATIO:
    {
      gint from_dar_n, from_dar_d, to_dar_n, to_dar_d, num, den;

      if (!gst_util_fraction_multiply (GST_VIDEO_INFO_WIDTH (&vagg_pad->info),
              GST_VIDEO_INFO_HEIGHT (&vagg_pad->info),
              GST_VIDEO_INFO_PAR_N (&vagg_pad->info),
              GST_VIDEO_INFO_PAR_D (&vagg_pad->info), &from_dar_n,
              &from_dar_d)) {
        from_dar_n = from_dar_d = -1;
      }

      if (!gst_util_fraction_multiply (pad_width, pad_height,
              out_par_n, out_par_d, &to_dar_n, &to_dar_d)) {
        to_dar_n = to_dar_d = -1;
      }

      if (from_dar_n != to_dar_n || from_dar_d != to_dar_d) {
        if (from_dar_n != -1 && from_dar_d != -1
            && gst_util_fraction_multiply (from_dar_n, from_dar_d,
                out_par_d, out_par_n, &num, &den)) {
          GstVideoRectangle src_rect, dst_rect, rst_rect;

          src_rect.h = gst_util_uint64_scale_int (pad_width, den, num);
          if (src_rect.h == 0) {
            pad_width = 0;
            pad_height = 0;
            break;
          }

          src_rect.x = src_rect.y = 0;
          src_rect.w = pad_width;

          dst_rect.x = dst_rect.y = 0;
          dst_rect.w = pad_width;
          dst_rect.h = pad_height;

          gst_video_center_rect (&src_rect, &dst_rect, &rst_rect, TRUE);

          GST_LOG_OBJECT (comp_pad,
              "Re-calculated size %dx%d -> %dx%d (x-offset %d, y-offset %d)",
              pad_width, pad_height, rst_rect.w, rst_rect.h, rst_rect.x,
              rst_rect.y);

          *x_offset = rst_rect.x;
          *y_offset = rst_rect.y;
          pad_width = rst_rect.w;
          pad_height = rst_rect.h;
        } else {
          GST_WARNING_OBJECT (comp_pad, "Failed to calculate output size");
          *x_offset = 0;
          *y_offset = 0;
          pad_width = 0;
          pad_height = 0;
        }
      }
      break;
    }
  }

  *width = pad_width;
  *height = pad_height;
}

/* Call this with the lock taken */
gboolean
gst_vf_metal_compositor_pad_obscures_rectangle (GstVideoAggregator * vagg,
    GstVideoAggregatorPad * pad, const GstVideoRectangle rect)
{
  GstVideoRectangle pad_rect;
  GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (pad);
  gint x_offset, y_offset;

  if (!gst_video_aggregator_pad_has_current_buffer (pad))
    return FALSE;

  if (cpad->alpha != 1.0 || GST_VIDEO_INFO_HAS_ALPHA (&pad->info))
    return FALSE;

  pad_rect.x = cpad->xpos;
  pad_rect.y = cpad->ypos;
  gst_vf_metal_compositor_pad_get_output_size (GST_VF_METAL_COMPOSITOR (vagg), cpad,
      GST_VIDEO_INFO_PAR_N (&vagg->info), GST_VIDEO_INFO_PAR_D (&vagg->info),
      &(pad_rect.w), &(pad_rect.h), &x_offset, &y_offset);
  pad_rect.x += x_offset;
  pad_rect.y += y_offset;

  if (!is_rectangle_contained (rect, pad_rect))
    return FALSE;

  GST_DEBUG_OBJECT (pad, "Pad %s %ix%i@(%i,%i) obscures rect %ix%i@(%i,%i)",
      GST_PAD_NAME (pad), pad_rect.w, pad_rect.h, pad_rect.x, pad_rect.y,
      rect.w, rect.h, rect.x, rect.y);

  return TRUE;
}

static gboolean
_should_draw_background (GstVideoAggregator * vagg)
{
  GstVideoRectangle bg_rect;
  gboolean draw = TRUE;
  GList *l;

  bg_rect.x = bg_rect.y = 0;

  GST_OBJECT_LOCK (vagg);
  bg_rect.w = GST_VIDEO_INFO_WIDTH (&vagg->info);
  bg_rect.h = GST_VIDEO_INFO_HEIGHT (&vagg->info);
  for (l = GST_ELEMENT (vagg)->sinkpads; l; l = l->next) {
    if (gst_aggregator_pad_is_inactive (GST_AGGREGATOR_PAD (l->data))
        || gst_video_aggregator_pad_get_prepared_frame (
               GST_VIDEO_AGGREGATOR_PAD (l->data)) == NULL)
      continue;

    if (gst_vf_metal_compositor_pad_obscures_rectangle (vagg, l->data, bg_rect)) {
      draw = FALSE;
      break;
    }
  }
  GST_OBJECT_UNLOCK (vagg);
  return draw;
}

/* --- Caps negotiation --- */

/* Override update_caps so that sink pads accept any input dimensions.
 * The default GstVideoAggregator implementation intersects all sink pad caps,
 * which forces all inputs to have the same width/height.  A compositor must
 * allow heterogeneous input sizes because it scales/positions each stream
 * independently via its pad properties (xpos, ypos, width, height). */
static GstCaps *
_update_caps (GstVideoAggregator * vagg, GstCaps * caps)
{
  GList *l;
  gint best_width = -1, best_height = -1;
  GstCaps *ret;

  GST_OBJECT_LOCK (vagg);
  for (l = GST_ELEMENT (vagg)->sinkpads; l; l = l->next) {
    GstVideoAggregatorPad *vaggpad = l->data;
    GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (vaggpad);
    gint this_width, this_height;

    if (!vaggpad->info.finfo
        || gst_aggregator_pad_is_inactive (GST_AGGREGATOR_PAD (vaggpad)))
      continue;

    /* Use configured pad output dimensions or input dimensions */
    this_width = cpad->width > 0
        ? cpad->width : GST_VIDEO_INFO_WIDTH (&vaggpad->info);
    this_height = cpad->height > 0
        ? cpad->height : GST_VIDEO_INFO_HEIGHT (&vaggpad->info);

    this_width += MAX (cpad->xpos, 0);
    this_height += MAX (cpad->ypos, 0);

    if (best_width < this_width)
      best_width = this_width;
    if (best_height < this_height)
      best_height = this_height;
  }
  GST_OBJECT_UNLOCK (vagg);

  if (best_width <= 0 || best_height <= 0) {
    /* No valid pads yet — return template caps with ranges */
    return gst_caps_ref (caps);
  }

  /* Build output caps with the computed dimensions and all supported formats.
   * Do not force BGRA even when inputs have alpha — the compositor renders
   * internally to BGRA and converts to the negotiated output format via
   * compute shaders, so any supported output format is valid.  Format
   * preference (BGRA) is handled in _fixate_caps instead. */
  ret = gst_caps_new_simple ("video/x-raw",
      "width", G_TYPE_INT, best_width,
      "height", G_TYPE_INT, best_height, NULL);
  {
    GstCaps *template_caps = gst_static_pad_template_get_caps (&src_factory);
    GstCaps *tmp = gst_caps_intersect (ret, template_caps);
    gst_caps_unref (ret);
    gst_caps_unref (template_caps);
    ret = tmp;
  }

  /* Intersect with downstream caps to ensure we're a valid subset */
  if (caps) {
    GstCaps *tmp = gst_caps_intersect (ret, caps);
    gst_caps_unref (ret);
    ret = tmp;
  }

  GST_DEBUG_OBJECT (vagg, "update_caps: %" GST_PTR_FORMAT, ret);

  return ret;
}

static GstCaps *
_fixate_caps (GstAggregator * agg, GstCaps * caps)
{
  GstVideoAggregator *vagg = GST_VIDEO_AGGREGATOR (agg);
  GList *l;
  gint best_width = -1, best_height = -1;
  gint best_fps_n = -1, best_fps_d = -1;
  gint par_n, par_d;
  gdouble best_fps = 0.;
  GstCaps *ret = NULL;
  GstStructure *s;

  ret = gst_caps_make_writable (caps);
  s = gst_caps_get_structure (ret, 0);

  if (gst_structure_has_field (s, "pixel-aspect-ratio")) {
    gst_structure_fixate_field_nearest_fraction (s, "pixel-aspect-ratio", 1, 1);
    gst_structure_get_fraction (s, "pixel-aspect-ratio", &par_n, &par_d);
  } else {
    par_n = par_d = 1;
  }

  GST_OBJECT_LOCK (vagg);
  for (l = GST_ELEMENT (vagg)->sinkpads; l; l = l->next) {
    GstVideoAggregatorPad *vaggpad = l->data;
    GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (vaggpad);
    gint this_width, this_height;
    gint width, height;
    gint fps_n, fps_d;
    gdouble cur_fps;
    gint x_offset, y_offset;

    if (gst_aggregator_pad_is_inactive (GST_AGGREGATOR_PAD (vaggpad)))
      continue;

    fps_n = GST_VIDEO_INFO_FPS_N (&vaggpad->info);
    fps_d = GST_VIDEO_INFO_FPS_D (&vaggpad->info);
    gst_vf_metal_compositor_pad_get_output_size (GST_VF_METAL_COMPOSITOR (vagg), cpad,
        par_n, par_d, &width, &height, &x_offset, &y_offset);

    if (width == 0 || height == 0)
      continue;

    this_width = width + MAX (cpad->xpos + 2 * x_offset, 0);
    this_height = height + MAX (cpad->ypos + 2 * y_offset, 0);

    if (best_width < this_width)
      best_width = this_width;
    if (best_height < this_height)
      best_height = this_height;

    if (fps_d == 0)
      cur_fps = 0.0;
    else
      gst_util_fraction_to_double (fps_n, fps_d, &cur_fps);

    if (best_fps < cur_fps) {
      best_fps = cur_fps;
      best_fps_n = fps_n;
      best_fps_d = fps_d;
    }
  }
  GST_OBJECT_UNLOCK (vagg);

  if (best_fps_n <= 0 || best_fps_d <= 0 || best_fps == 0.0) {
    best_fps_n = 25;
    best_fps_d = 1;
    best_fps = 25.0;
  }

  /* Prefer BGRA format for Metal output */
  gst_structure_fixate_field_string (s, "format", "BGRA");

  gst_structure_fixate_field_nearest_int (s, "width", best_width);
  gst_structure_fixate_field_nearest_int (s, "height", best_height);
  gst_structure_fixate_field_nearest_fraction (s, "framerate", best_fps_n,
      best_fps_d);
  ret = gst_caps_fixate (ret);

  return ret;
}

/* --- Negotiated caps --- */

static gboolean
_negotiated_caps (GstAggregator * agg, GstCaps * caps)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (agg);
  GstVideoInfo v_info;

  GST_DEBUG_OBJECT (agg, "Negotiated caps %" GST_PTR_FORMAT, caps);

  if (!gst_video_info_from_caps (&v_info, caps))
    return FALSE;

  if (!self->renderer) {
    GST_ERROR_OBJECT (agg, "Metal renderer not available");
    return FALSE;
  }

  MetalCompositorRenderer *renderer =
      (__bridge MetalCompositorRenderer *)self->renderer;
  if (![renderer configureWithWidth:GST_VIDEO_INFO_WIDTH (&v_info)
                             height:GST_VIDEO_INFO_HEIGHT (&v_info)
                             format:GST_VIDEO_INFO_FORMAT (&v_info)]) {
    GST_ERROR_OBJECT (agg, "Failed to configure Metal renderer");
    return FALSE;
  }

  return GST_AGGREGATOR_CLASS (parent_class)->negotiated_src_caps (agg, caps);
}

/* --- aggregate_frames --- */

static GstFlowReturn
gst_vf_metal_compositor_aggregate_frames (GstVideoAggregator * vagg,
    GstBuffer * outbuf)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (vagg);
  GList *l;
  GstVideoFrame out_frame;
  gboolean draw_background;
  guint n_pads = 0;

  if (!self->renderer) {
    GST_ERROR_OBJECT (vagg, "Metal renderer not available");
    return GST_FLOW_ERROR;
  }

  MetalCompositorRenderer *renderer =
      (__bridge MetalCompositorRenderer *)self->renderer;

  if (!gst_video_frame_map (&out_frame, &vagg->info, outbuf, GST_MAP_WRITE)) {
    GST_WARNING_OBJECT (vagg, "Could not map output buffer");
    return GST_FLOW_ERROR;
  }

  draw_background = _should_draw_background (vagg);

  GST_OBJECT_LOCK (vagg);
  for (l = GST_ELEMENT (vagg)->sinkpads; l; l = l->next) {
    GstVideoAggregatorPad *pad = l->data;
    if (gst_video_aggregator_pad_get_prepared_frame (pad))
      n_pads++;
  }

  if (n_pads == 0)
    draw_background = TRUE;

  MetalPadInput *inputs = g_new (MetalPadInput, MAX (n_pads, 1));
  guint i = 0;

  for (l = GST_ELEMENT (vagg)->sinkpads; l; l = l->next) {
    GstVideoAggregatorPad *pad = l->data;
    GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (pad);
    GstVideoFrame *prepared_frame =
        gst_video_aggregator_pad_get_prepared_frame (pad);

    if (prepared_frame) {
      gint width, height, x_offset, y_offset;

      gst_vf_metal_compositor_pad_get_output_size (self, cpad,
          GST_VIDEO_INFO_PAR_N (&vagg->info),
          GST_VIDEO_INFO_PAR_D (&vagg->info),
          &width, &height, &x_offset, &y_offset);

      inputs[i].frame = prepared_frame;
      inputs[i].xpos = cpad->xpos + x_offset;
      inputs[i].ypos = cpad->ypos + y_offset;
      inputs[i].width = width;
      inputs[i].height = height;
      inputs[i].alpha = cpad->alpha;

      switch (cpad->op) {
        case VF_METAL_COMPOSITOR_OPERATOR_SOURCE:
          inputs[i].blend_mode = METAL_BLEND_SOURCE;
          break;
        case VF_METAL_COMPOSITOR_OPERATOR_OVER:
          inputs[i].blend_mode = METAL_BLEND_OVER;
          break;
        case VF_METAL_COMPOSITOR_OPERATOR_ADD:
          inputs[i].blend_mode = METAL_BLEND_ADD;
          break;
      }
      i++;
    }
  }
  GST_OBJECT_UNLOCK (vagg);

  MetalBackgroundType bg = METAL_BG_BLACK;
  if (!draw_background) {
    bg = METAL_BG_TRANSPARENT;
  } else {
    switch (self->background) {
      case VF_METAL_COMPOSITOR_BACKGROUND_CHECKER:
        bg = METAL_BG_CHECKER;
        break;
      case VF_METAL_COMPOSITOR_BACKGROUND_BLACK:
        bg = METAL_BG_BLACK;
        break;
      case VF_METAL_COMPOSITOR_BACKGROUND_WHITE:
        bg = METAL_BG_WHITE;
        break;
      case VF_METAL_COMPOSITOR_BACKGROUND_TRANSPARENT:
        bg = METAL_BG_TRANSPARENT;
        break;
    }
  }

  @autoreleasepool {
    if (![renderer compositeWithInputs:inputs
                                 count:i
                            background:bg
                              outFrame:&out_frame]) {
      GST_ERROR_OBJECT (vagg, "Metal compositing failed");
      gst_video_frame_unmap (&out_frame);
      g_free (inputs);
      return GST_FLOW_ERROR;
    }
  }

  gst_video_frame_unmap (&out_frame);
  g_free (inputs);
  return GST_FLOW_OK;
}

/* --- Element stop --- */

static gboolean
gst_vf_metal_compositor_stop (GstAggregator * agg)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (agg);

  if (self->renderer) {
    @autoreleasepool {
      MetalCompositorRenderer *renderer =
          (__bridge MetalCompositorRenderer *)self->renderer;
      [renderer cleanup];
    }
  }

  return GST_AGGREGATOR_CLASS (parent_class)->stop (agg);
}

/* --- Navigation event forwarding --- */

typedef struct
{
  GstEvent *event;
  gboolean res;
} SrcPadMouseEventData;

static gboolean
src_pad_mouse_event (GstElement * element, GstPad * pad, gpointer user_data)
{
  GstVideoAggregator *vagg = GST_VIDEO_AGGREGATOR_CAST (element);
  GstVfMetalCompositor *comp = GST_VF_METAL_COMPOSITOR (element);
  GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (pad);
  SrcPadMouseEventData *data = user_data;
  GstStructure *st =
      gst_structure_copy (gst_event_get_structure (data->event));
  gdouble event_x, event_y;
  gint offset_x, offset_y;
  GstVideoRectangle rect;

  gst_structure_get (st, "pointer_x", G_TYPE_DOUBLE, &event_x,
      "pointer_y", G_TYPE_DOUBLE, &event_y, NULL);

  gst_vf_metal_compositor_pad_get_output_size (comp, cpad,
      GST_VIDEO_INFO_PAR_N (&vagg->info),
      GST_VIDEO_INFO_PAR_D (&vagg->info),
      &(rect.w), &(rect.h), &offset_x, &offset_y);
  rect.x = cpad->xpos + offset_x;
  rect.y = cpad->ypos + offset_y;

  if (is_point_contained (rect, event_x, event_y)) {
    GstVideoAggregatorPad *vpad = GST_VIDEO_AGGREGATOR_PAD_CAST (cpad);
    gdouble w, h, x, y;

    w = (gdouble) GST_VIDEO_INFO_WIDTH (&vpad->info);
    h = (gdouble) GST_VIDEO_INFO_HEIGHT (&vpad->info);
    x = (event_x - (gdouble) rect.x) * (w / (gdouble) rect.w);
    y = (event_y - (gdouble) rect.y) * (h / (gdouble) rect.h);

    gst_structure_set (st, "pointer_x", G_TYPE_DOUBLE, x,
        "pointer_y", G_TYPE_DOUBLE, y, NULL);
    data->res |= gst_pad_push_event (pad, gst_event_new_navigation (st));
  } else {
    gst_structure_free (st);
  }

  return TRUE;
}

static gboolean
_src_event (GstAggregator * agg, GstEvent * event)
{
  GstNavigationEventType event_type;

  switch (GST_EVENT_TYPE (event)) {
    case GST_EVENT_NAVIGATION:
    {
      event_type = gst_navigation_event_get_type (event);
      switch (event_type) {
        case GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS:
        case GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE:
        case GST_NAVIGATION_EVENT_MOUSE_MOVE:
        case GST_NAVIGATION_EVENT_MOUSE_SCROLL:
        {
          SrcPadMouseEventData d = {
            .event = event,
            .res = FALSE
          };
          gst_element_foreach_sink_pad (GST_ELEMENT_CAST (agg),
              src_pad_mouse_event, &d);
          gst_event_unref (event);
          return d.res;
        }
        default:
          break;
      }
    }
    default:
      break;
  }

  return GST_AGGREGATOR_CLASS (parent_class)->src_event (agg, event);
}

/* --- Sink query (buffer pool) --- */

static gboolean
_sink_query (GstAggregator * agg, GstAggregatorPad * bpad, GstQuery * query)
{
  switch (GST_QUERY_TYPE (query)) {
    case GST_QUERY_CAPS:{
      GstCaps *filter, *sinkcaps;

      gst_query_parse_caps (query, &filter);
      sinkcaps = gst_pad_get_pad_template_caps (GST_PAD (bpad));

      if (filter) {
        GstCaps *tmp = gst_caps_intersect (sinkcaps, filter);
        gst_caps_unref (sinkcaps);
        sinkcaps = tmp;
      }

      gst_query_set_caps_result (query, sinkcaps);
      gst_caps_unref (sinkcaps);
      return TRUE;
    }
    case GST_QUERY_ALLOCATION:{
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
    default:
      return GST_AGGREGATOR_CLASS (parent_class)->sink_query (agg, bpad, query);
  }
}

/* --- Pad management --- */

static GstPad *
gst_vf_metal_compositor_request_new_pad (GstElement * element,
    GstPadTemplate * templ, const gchar * req_name, const GstCaps * caps)
{
  GstPad *newpad;

  newpad = (GstPad *)
      GST_ELEMENT_CLASS (parent_class)->request_new_pad (element,
      templ, req_name, caps);

  if (newpad == NULL)
    goto could_not_create;

  /* Sort pads by zorder after adding */
  GST_OBJECT_LOCK (element);
  element->sinkpads = g_list_sort (element->sinkpads,
      (GCompareFunc) pad_zorder_compare);
  GST_OBJECT_UNLOCK (element);

  gst_child_proxy_child_added (GST_CHILD_PROXY (element), G_OBJECT (newpad),
      GST_OBJECT_NAME (newpad));

  return newpad;

could_not_create:
  {
    GST_DEBUG_OBJECT (element, "could not create/add pad");
    return NULL;
  }
}

static void
gst_vf_metal_compositor_release_pad (GstElement * element, GstPad * pad)
{
  GST_DEBUG_OBJECT (element, "release pad %s:%s", GST_DEBUG_PAD_NAME (pad));

  gst_child_proxy_child_removed (GST_CHILD_PROXY (element), G_OBJECT (pad),
      GST_OBJECT_NAME (pad));

  GST_ELEMENT_CLASS (parent_class)->release_pad (element, pad);
}

/* --- Element properties --- */

static void
gst_vf_metal_compositor_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (object);

  switch (prop_id) {
    case PROP_BACKGROUND:
      g_value_set_enum (value, self->background);
      break;
    case PROP_ZERO_SIZE_IS_UNSCALED:
      g_value_set_boolean (value, self->zero_size_is_unscaled);
      break;
    case PROP_IGNORE_INACTIVE_PADS:
      g_value_set_boolean (value,
          gst_aggregator_get_ignore_inactive_pads (GST_AGGREGATOR (object)));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_vf_metal_compositor_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (object);

  switch (prop_id) {
    case PROP_BACKGROUND:
      self->background = g_value_get_enum (value);
      break;
    case PROP_ZERO_SIZE_IS_UNSCALED:
      self->zero_size_is_unscaled = g_value_get_boolean (value);
      break;
    case PROP_IGNORE_INACTIVE_PADS:
      gst_aggregator_set_ignore_inactive_pads (GST_AGGREGATOR (object),
          g_value_get_boolean (value));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

/* --- Finalize --- */

static void
gst_vf_metal_compositor_finalize (GObject * object)
{
  GstVfMetalCompositor *self = GST_VF_METAL_COMPOSITOR (object);

  if (self->renderer) {
    @autoreleasepool {
      MetalCompositorRenderer *renderer =
          (__bridge_transfer MetalCompositorRenderer *)self->renderer;
      [renderer cleanup];
      self->renderer = NULL;
      (void)renderer;
    }
  }

  G_OBJECT_CLASS (parent_class)->finalize (object);
}

/* --- GstChildProxy implementation --- */

static GObject *
gst_vf_metal_compositor_child_proxy_get_child_by_index (
    GstChildProxy * child_proxy, guint index)
{
  GstVfMetalCompositor *comp = GST_VF_METAL_COMPOSITOR (child_proxy);
  GObject *obj = NULL;

  GST_OBJECT_LOCK (comp);
  obj = g_list_nth_data (GST_ELEMENT_CAST (comp)->sinkpads, index);
  if (obj)
    gst_object_ref (obj);
  GST_OBJECT_UNLOCK (comp);

  return obj;
}

static guint
gst_vf_metal_compositor_child_proxy_get_children_count (
    GstChildProxy * child_proxy)
{
  guint count = 0;
  GstVfMetalCompositor *comp = GST_VF_METAL_COMPOSITOR (child_proxy);

  GST_OBJECT_LOCK (comp);
  count = GST_ELEMENT_CAST (comp)->numsinkpads;
  GST_OBJECT_UNLOCK (comp);
  GST_INFO_OBJECT (comp, "Children Count: %d", count);

  return count;
}

static void
gst_vf_metal_compositor_child_proxy_init (gpointer g_iface,
    gpointer iface_data)
{
  GstChildProxyInterface *iface = g_iface;
  iface->get_child_by_index =
      gst_vf_metal_compositor_child_proxy_get_child_by_index;
  iface->get_children_count =
      gst_vf_metal_compositor_child_proxy_get_children_count;
}

/* --- class_init --- */

static void
gst_vf_metal_compositor_class_init (GstVfMetalCompositorClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstElementClass *gstelement_class = (GstElementClass *) klass;
  GstVideoAggregatorClass *videoaggregator_class =
      (GstVideoAggregatorClass *) klass;
  GstAggregatorClass *agg_class = (GstAggregatorClass *) klass;

  gobject_class->get_property = gst_vf_metal_compositor_get_property;
  gobject_class->set_property = gst_vf_metal_compositor_set_property;
  gobject_class->finalize = gst_vf_metal_compositor_finalize;

  gstelement_class->request_new_pad =
      GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_request_new_pad);
  gstelement_class->release_pad =
      GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_release_pad);

  agg_class->sink_query = GST_DEBUG_FUNCPTR (_sink_query);
  agg_class->src_event = GST_DEBUG_FUNCPTR (_src_event);
  agg_class->fixate_src_caps = GST_DEBUG_FUNCPTR (_fixate_caps);
  agg_class->negotiated_src_caps = GST_DEBUG_FUNCPTR (_negotiated_caps);
  agg_class->stop = GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_stop);

  videoaggregator_class->update_caps =
      GST_DEBUG_FUNCPTR (_update_caps);
  videoaggregator_class->aggregate_frames =
      GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_aggregate_frames);

  g_object_class_install_property (gobject_class, PROP_BACKGROUND,
      g_param_spec_enum ("background", "Background", "Background type",
          GST_TYPE_VF_METAL_COMPOSITOR_BACKGROUND,
          DEFAULT_BACKGROUND, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_ZERO_SIZE_IS_UNSCALED,
      g_param_spec_boolean ("zero-size-is-unscaled", "Zero size is unscaled",
          "If TRUE, then input video is unscaled in that dimension "
          "if width or height is 0 (for backwards compatibility)",
          DEFAULT_ZERO_SIZE_IS_UNSCALED,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class,
      PROP_IGNORE_INACTIVE_PADS, g_param_spec_boolean ("ignore-inactive-pads",
          "Ignore inactive pads",
          "Avoid timing out waiting for inactive pads", FALSE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_add_static_pad_template_with_gtype (gstelement_class,
      &src_factory, GST_TYPE_AGGREGATOR_PAD);
  gst_element_class_add_static_pad_template_with_gtype (gstelement_class,
      &sink_factory, GST_TYPE_VF_METAL_COMPOSITOR_PAD);

  gst_element_class_set_static_metadata (gstelement_class,
      "Metal Video Compositor",
      "Filter/Editor/Video/Compositor",
      "Metal-accelerated video compositor",
      "VisioForge <support@visioforge.com>");

  gst_type_mark_as_plugin_api (GST_TYPE_VF_METAL_COMPOSITOR_PAD, 0);
  gst_type_mark_as_plugin_api (GST_TYPE_VF_METAL_COMPOSITOR_OPERATOR, 0);
  gst_type_mark_as_plugin_api (GST_TYPE_VF_METAL_COMPOSITOR_BACKGROUND, 0);

  GST_DEBUG_CATEGORY_INIT (gst_vf_metal_compositor_debug,
      "vfmetalcompositor", 0, "Metal video compositor");
}

/* --- init --- */

static void
gst_vf_metal_compositor_init (GstVfMetalCompositor * self)
{
  self->background = DEFAULT_BACKGROUND;
  self->zero_size_is_unscaled = DEFAULT_ZERO_SIZE_IS_UNSCALED;

  @autoreleasepool {
    MetalCompositorRenderer *renderer =
        [[MetalCompositorRenderer alloc] init];
    if (renderer) {
      self->renderer = (__bridge_retained void *)renderer;
    } else {
      GST_ERROR_OBJECT (self, "Failed to create Metal renderer — no Metal device");
    }
  }
}
