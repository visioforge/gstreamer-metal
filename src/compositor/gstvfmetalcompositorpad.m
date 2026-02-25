/* GStreamer Metal video compositor pad
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

#include "gstvfmetalcompositor.h"

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_compositor_debug);
#define GST_CAT_DEFAULT gst_vf_metal_compositor_debug

/* --- Pad property IDs --- */

enum
{
  PROP_PAD_0,
  PROP_PAD_XPOS,
  PROP_PAD_YPOS,
  PROP_PAD_WIDTH,
  PROP_PAD_HEIGHT,
  PROP_PAD_ALPHA,
  PROP_PAD_OPERATOR,
  PROP_PAD_SIZING_POLICY,
  PROP_PAD_ZORDER,
};

#define DEFAULT_PAD_XPOS   0
#define DEFAULT_PAD_YPOS   0
#define DEFAULT_PAD_WIDTH  -1
#define DEFAULT_PAD_HEIGHT -1
#define DEFAULT_PAD_ALPHA  1.0
#define DEFAULT_PAD_OPERATOR VF_METAL_COMPOSITOR_OPERATOR_OVER
#define DEFAULT_PAD_SIZING_POLICY VF_METAL_COMPOSITOR_SIZING_POLICY_NONE
#define DEFAULT_PAD_ZORDER 0

/* --- Forward declarations for enum types defined in the element file --- */

#define GST_TYPE_VF_METAL_COMPOSITOR_OPERATOR (gst_vf_metal_compositor_operator_get_type())
GType gst_vf_metal_compositor_operator_get_type (void);

#define GST_TYPE_VF_METAL_COMPOSITOR_SIZING_POLICY (gst_vf_metal_compositor_sizing_policy_get_type())
GType gst_vf_metal_compositor_sizing_policy_get_type (void);

/* Re-declare gst_vf_metal_compositor_pad_get_output_size from the element file */
extern void gst_vf_metal_compositor_pad_get_output_size (GstVfMetalCompositor * comp,
    GstVfMetalCompositorPad * comp_pad, gint out_par_n, gint out_par_d,
    gint * width, gint * height, gint * x_offset, gint * y_offset);

/* --- GType boilerplate --- */

G_DEFINE_TYPE (GstVfMetalCompositorPad, gst_vf_metal_compositor_pad,
    GST_TYPE_VIDEO_AGGREGATOR_PAD);

/* --- Properties --- */

static void
gst_vf_metal_compositor_pad_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstVfMetalCompositorPad *pad = GST_VF_METAL_COMPOSITOR_PAD (object);

  switch (prop_id) {
    case PROP_PAD_XPOS:
      g_value_set_int (value, pad->xpos);
      break;
    case PROP_PAD_YPOS:
      g_value_set_int (value, pad->ypos);
      break;
    case PROP_PAD_WIDTH:
      g_value_set_int (value, pad->width);
      break;
    case PROP_PAD_HEIGHT:
      g_value_set_int (value, pad->height);
      break;
    case PROP_PAD_ALPHA:
      g_value_set_double (value, pad->alpha);
      break;
    case PROP_PAD_OPERATOR:
      g_value_set_enum (value, pad->op);
      break;
    case PROP_PAD_SIZING_POLICY:
      g_value_set_enum (value, pad->sizing_policy);
      break;
    case PROP_PAD_ZORDER:
      g_value_set_uint (value, pad->zorder);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_vf_metal_compositor_pad_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalCompositorPad *pad = GST_VF_METAL_COMPOSITOR_PAD (object);

  switch (prop_id) {
    case PROP_PAD_XPOS:
      pad->xpos = g_value_get_int (value);
      break;
    case PROP_PAD_YPOS:
      pad->ypos = g_value_get_int (value);
      break;
    case PROP_PAD_WIDTH:
      pad->width = g_value_get_int (value);
      break;
    case PROP_PAD_HEIGHT:
      pad->height = g_value_get_int (value);
      break;
    case PROP_PAD_ALPHA:
      pad->alpha = g_value_get_double (value);
      break;
    case PROP_PAD_OPERATOR:
      pad->op = g_value_get_enum (value);
      gst_video_aggregator_pad_set_needs_alpha (GST_VIDEO_AGGREGATOR_PAD (pad),
          pad->op == VF_METAL_COMPOSITOR_OPERATOR_ADD);
      break;
    case PROP_PAD_SIZING_POLICY:
      pad->sizing_policy = g_value_get_enum (value);
      break;
    case PROP_PAD_ZORDER:
      pad->zorder = g_value_get_uint (value);
      {
        GstElement *element = gst_pad_get_parent_element (GST_PAD (pad));
        if (element) {
          GST_OBJECT_LOCK (element);
          element->sinkpads = g_list_sort (element->sinkpads,
              (GCompareFunc) pad_zorder_compare);
          GST_OBJECT_UNLOCK (element);
          gst_object_unref (element);
        }
      }
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

/* --- prepare_frame_start --- */

static GstVideoRectangle
pad_clamp_rectangle (gint x, gint y, gint w, gint h, gint outer_width,
    gint outer_height)
{
  gint x2 = x + w;
  gint y2 = y + h;
  GstVideoRectangle clamped;

  clamped.x = CLAMP (x, 0, outer_width);
  clamped.y = CLAMP (y, 0, outer_height);
  clamped.w = CLAMP (x2, 0, outer_width) - clamped.x;
  clamped.h = CLAMP (y2, 0, outer_height) - clamped.y;

  return clamped;
}

/* Re-declare gst_vf_metal_compositor_pad_obscures_rectangle from the element file */
extern gboolean gst_vf_metal_compositor_pad_obscures_rectangle (GstVideoAggregator * vagg,
    GstVideoAggregatorPad * pad, const GstVideoRectangle rect);

static void
gst_vf_metal_compositor_pad_prepare_frame_start (GstVideoAggregatorPad * pad,
    GstVideoAggregator * vagg, GstBuffer * buffer,
    GstVideoFrame * prepared_frame)
{
  GstVfMetalCompositorPad *cpad = GST_VF_METAL_COMPOSITOR_PAD (pad);
  gint width, height;
  gboolean frame_obscured = FALSE;
  GList *l;
  GstVideoRectangle frame_rect;

  /* Skip if fully transparent */
  if (cpad->alpha == 0.0) {
    GST_DEBUG_OBJECT (pad, "Pad has alpha 0.0, not preparing frame");
    return;
  }

  if (gst_aggregator_pad_is_inactive (GST_AGGREGATOR_PAD (pad)))
    return;

  /* Use the shared size calculation that handles DAR and sizing policy */
  gst_vf_metal_compositor_pad_get_output_size (GST_VF_METAL_COMPOSITOR (vagg), cpad,
      GST_VIDEO_INFO_PAR_N (&vagg->info),
      GST_VIDEO_INFO_PAR_D (&vagg->info),
      &width, &height, &cpad->x_offset, &cpad->y_offset);

  if (width == 0 || height == 0)
    return;

  frame_rect = pad_clamp_rectangle (cpad->xpos + cpad->x_offset,
      cpad->ypos + cpad->y_offset, width, height,
      GST_VIDEO_INFO_WIDTH (&vagg->info), GST_VIDEO_INFO_HEIGHT (&vagg->info));

  if (frame_rect.w == 0 || frame_rect.h == 0) {
    GST_DEBUG_OBJECT (pad, "Resulting frame is zero-width or zero-height "
        "(w: %i, h: %i), skipping", frame_rect.w, frame_rect.h);
    return;
  }

  /* Check if this frame is obscured by a higher-zorder frame */
  GST_OBJECT_LOCK (vagg);
  l = g_list_find (GST_ELEMENT (vagg)->sinkpads, pad);
  if (l)
    l = l->next;
  for (; l; l = l->next) {
    GstBuffer *pad_buffer;

    pad_buffer =
        gst_video_aggregator_pad_get_current_buffer (GST_VIDEO_AGGREGATOR_PAD
        (l->data));

    if (pad_buffer == NULL)
      continue;

    if (gst_buffer_get_size (pad_buffer) == 0 &&
        GST_BUFFER_FLAG_IS_SET (pad_buffer, GST_BUFFER_FLAG_GAP)) {
      continue;
    }

    if (gst_vf_metal_compositor_pad_obscures_rectangle (vagg, l->data, frame_rect)) {
      frame_obscured = TRUE;
      break;
    }
  }
  GST_OBJECT_UNLOCK (vagg);

  if (frame_obscured)
    return;

  /* Map the buffer into a GstVideoFrame. We don't chain up to the parent
   * class because GstVideoAggregatorPad's prepare_frame_start is NULL —
   * only GstVideoAggregatorConvertPad provides a default implementation.
   * We handle the mapping directly. */
  if (!gst_video_frame_map (prepared_frame, &pad->info, buffer, GST_MAP_READ)) {
    GST_WARNING_OBJECT (pad, "Could not map input buffer");
  }
}

/* --- prepare_frame_finish --- */

static void
gst_vf_metal_compositor_pad_prepare_frame_finish (GstVideoAggregatorPad * pad,
    GstVideoAggregator * vagg, GstVideoFrame * prepared_frame)
{
  /* Intentionally a no-op. Frame unmapping is handled by the inherited
   * clean_frame virtual method (GstVideoAggregatorPad default), which
   * is called after aggregate_frames completes. We must NOT unmap here
   * because gst_video_frame_unmap does not set frame->buffer to NULL,
   * so clean_frame would try to unmap again causing double-free. */
}

/* --- class_init --- */

static void
gst_vf_metal_compositor_pad_class_init (GstVfMetalCompositorPadClass * klass)
{
  GObjectClass *gobject_class = (GObjectClass *) klass;
  GstVideoAggregatorPadClass *vaggpadclass =
      (GstVideoAggregatorPadClass *) klass;

  gobject_class->set_property = gst_vf_metal_compositor_pad_set_property;
  gobject_class->get_property = gst_vf_metal_compositor_pad_get_property;

  g_object_class_install_property (gobject_class, PROP_PAD_XPOS,
      g_param_spec_int ("xpos", "X Position", "X Position of the picture",
          G_MININT, G_MAXINT, DEFAULT_PAD_XPOS,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_YPOS,
      g_param_spec_int ("ypos", "Y Position", "Y Position of the picture",
          G_MININT, G_MAXINT, DEFAULT_PAD_YPOS,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_WIDTH,
      g_param_spec_int ("width", "Width", "Width of the picture",
          G_MININT, G_MAXINT, DEFAULT_PAD_WIDTH,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_HEIGHT,
      g_param_spec_int ("height", "Height", "Height of the picture",
          G_MININT, G_MAXINT, DEFAULT_PAD_HEIGHT,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_ALPHA,
      g_param_spec_double ("alpha", "Alpha", "Alpha of the picture", 0.0, 1.0,
          DEFAULT_PAD_ALPHA,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_OPERATOR,
      g_param_spec_enum ("operator", "Operator",
          "Blending operator to use for blending this pad over the previous ones",
          GST_TYPE_VF_METAL_COMPOSITOR_OPERATOR, DEFAULT_PAD_OPERATOR,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_SIZING_POLICY,
      g_param_spec_enum ("sizing-policy", "Sizing policy",
          "Sizing policy to use for image scaling",
          GST_TYPE_VF_METAL_COMPOSITOR_SIZING_POLICY, DEFAULT_PAD_SIZING_POLICY,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_PAD_ZORDER,
      g_param_spec_uint ("zorder", "Z-Order", "Z Order of the picture",
          0, G_MAXUINT, DEFAULT_PAD_ZORDER,
          G_PARAM_READWRITE | GST_PARAM_CONTROLLABLE | G_PARAM_STATIC_STRINGS));

  vaggpadclass->prepare_frame_start =
      GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_pad_prepare_frame_start);
  vaggpadclass->prepare_frame_finish =
      GST_DEBUG_FUNCPTR (gst_vf_metal_compositor_pad_prepare_frame_finish);

  gst_type_mark_as_plugin_api (GST_TYPE_VF_METAL_COMPOSITOR_SIZING_POLICY, 0);
}

/* --- init --- */

static void
gst_vf_metal_compositor_pad_init (GstVfMetalCompositorPad * pad)
{
  pad->xpos = DEFAULT_PAD_XPOS;
  pad->ypos = DEFAULT_PAD_YPOS;
  pad->alpha = DEFAULT_PAD_ALPHA;
  pad->op = DEFAULT_PAD_OPERATOR;
  pad->width = DEFAULT_PAD_WIDTH;
  pad->height = DEFAULT_PAD_HEIGHT;
  pad->sizing_policy = DEFAULT_PAD_SIZING_POLICY;
  pad->zorder = DEFAULT_PAD_ZORDER;
}
