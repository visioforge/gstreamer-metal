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

  /* The values written last, committed or not, as in vfmetaloverlay */
  GST_OBJECT_LOCK (pad);
  switch (prop_id) {
    case PROP_PAD_XPOS:
      g_value_set_int (value, pad->pending.xpos);
      break;
    case PROP_PAD_YPOS:
      g_value_set_int (value, pad->pending.ypos);
      break;
    case PROP_PAD_WIDTH:
      g_value_set_int (value, pad->pending.width);
      break;
    case PROP_PAD_HEIGHT:
      g_value_set_int (value, pad->pending.height);
      break;
    case PROP_PAD_ALPHA:
      g_value_set_double (value, pad->pending.alpha);
      break;
    case PROP_PAD_OPERATOR:
      g_value_set_enum (value, pad->pending.op);
      break;
    case PROP_PAD_SIZING_POLICY:
      g_value_set_enum (value, pad->pending.sizing_policy);
      break;
    case PROP_PAD_ZORDER:
      g_value_set_uint (value, pad->pending.zorder);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
  GST_OBJECT_UNLOCK (pad);
}

static void
gst_vf_metal_compositor_pad_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstVfMetalCompositorPad *pad = GST_VF_METAL_COMPOSITOR_PAD (object);

  /* Every property goes to pending; dispatch_properties_changed commits
   * them with the rest of the batch */
  switch (prop_id) {
    case PROP_PAD_XPOS:
      GST_OBJECT_LOCK (pad);
      pad->pending.xpos = g_value_get_int (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_YPOS:
      GST_OBJECT_LOCK (pad);
      pad->pending.ypos = g_value_get_int (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_WIDTH:
      GST_OBJECT_LOCK (pad);
      pad->pending.width = g_value_get_int (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_HEIGHT:
      GST_OBJECT_LOCK (pad);
      pad->pending.height = g_value_get_int (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_ALPHA:
      GST_OBJECT_LOCK (pad);
      pad->pending.alpha = g_value_get_double (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_OPERATOR:
    {
      GstVfMetalCompositorOperator op = g_value_get_enum (value);
      GST_OBJECT_LOCK (pad);
      pad->pending.op = op;
      GST_OBJECT_UNLOCK (pad);
      /* A negotiation hint, not a drawn value: it applies at the write */
      gst_video_aggregator_pad_set_needs_alpha (GST_VIDEO_AGGREGATOR_PAD (pad),
          op == VF_METAL_COMPOSITOR_OPERATOR_ADD);
      break;
    }
    case PROP_PAD_SIZING_POLICY:
      GST_OBJECT_LOCK (pad);
      pad->pending.sizing_policy = g_value_get_enum (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    case PROP_PAD_ZORDER:
      GST_OBJECT_LOCK (pad);
      pad->pending.zorder = g_value_get_uint (value);
      GST_OBJECT_UNLOCK (pad);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

/* GObject calls this once per batch of writes, after the last one: right
 * after a single g_object_set_property (), at the end of a g_object_set ()
 * with several properties, or at the g_object_thaw_notify () that ends a
 * freeze. The batch becomes the one the next output frame snapshots, so no
 * frame is drawn with a position and a size that were never set together. */
static void
gst_vf_metal_compositor_pad_dispatch_properties_changed (GObject * object,
    guint n_pspecs, GParamSpec ** pspecs)
{
  GstVfMetalCompositorPad *pad = GST_VF_METAL_COMPOSITOR_PAD (object);

  /* Only a batch that wrote a pad property commits: a caps notify or a
   * parent class property takes no lock */
  gboolean batched = FALSE;
  for (guint i = 0; i < n_pspecs; i++) {
    if (pspecs[i]->owner_type != GST_TYPE_VF_METAL_COMPOSITOR_PAD)
      continue;
    switch (pspecs[i]->param_id) {
      case PROP_PAD_XPOS:
      case PROP_PAD_YPOS:
      case PROP_PAD_WIDTH:
      case PROP_PAD_HEIGHT:
      case PROP_PAD_ALPHA:
      case PROP_PAD_OPERATOR:
      case PROP_PAD_SIZING_POLICY:
      case PROP_PAD_ZORDER:
        batched = TRUE;
        break;
      default:
        break;
    }
  }

  if (batched) {
    GST_OBJECT_LOCK (pad);
    pad->committed = pad->pending;
    GST_OBJECT_UNLOCK (pad);
  }

  G_OBJECT_CLASS (gst_vf_metal_compositor_pad_parent_class)->
      dispatch_properties_changed (object, n_pspecs, pspecs);
}

void
gst_vf_metal_compositor_snapshot_pads (GstElement * element)
{
  /* Element lock (held by the caller), then pad lock */
  gboolean resort = FALSE;
  for (GList * l = element->sinkpads; l; l = l->next) {
    GstVfMetalCompositorPad *pad = l->data;

    GST_OBJECT_LOCK (pad);
    pad->xpos = pad->committed.xpos;
    pad->ypos = pad->committed.ypos;
    pad->width = pad->committed.width;
    pad->height = pad->committed.height;
    pad->alpha = pad->committed.alpha;
    pad->sizing_policy = pad->committed.sizing_policy;
    pad->op = pad->committed.op;
    if (pad->zorder != pad->committed.zorder) {
      pad->zorder = pad->committed.zorder;
      resort = TRUE;
    }
    GST_OBJECT_UNLOCK (pad);
  }

  /* gst_element_foreach_sink_pad () walks a copy, so a frame being
   * prepared keeps its pads */
  if (resort)
    element->sinkpads = g_list_sort (element->sinkpads,
        (GCompareFunc) pad_zorder_compare);
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
  GstVfMetalCompositor *comp = GST_VF_METAL_COMPOSITOR (vagg);
  gint width, height;
  gboolean frame_obscured = FALSE;
  GList *l;
  GstVideoRectangle frame_rect;

  /* The first pad of the frame snapshots them all: after the controller
   * sync, before any rectangle of this frame is read. A frame where no pad
   * gets here reads no rectangle either */
  if (comp->snapshot_pending) {
    comp->snapshot_pending = FALSE;
    GST_OBJECT_LOCK (vagg);
    gst_vf_metal_compositor_snapshot_pads (GST_ELEMENT (vagg));
    GST_OBJECT_UNLOCK (vagg);
  }

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
  gobject_class->dispatch_properties_changed =
      gst_vf_metal_compositor_pad_dispatch_properties_changed;

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
  pad->pending.xpos = pad->xpos;
  pad->pending.ypos = pad->ypos;
  pad->pending.width = pad->width;
  pad->pending.height = pad->height;
  pad->pending.alpha = pad->alpha;
  pad->pending.sizing_policy = pad->sizing_policy;
  pad->pending.zorder = pad->zorder;
  pad->pending.op = pad->op;
  pad->committed = pad->pending;
}
