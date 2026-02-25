/* GStreamer Metal video compositor element
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

#ifndef __GST_VF_METAL_COMPOSITOR_H__
#define __GST_VF_METAL_COMPOSITOR_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideoaggregator.h>

G_BEGIN_DECLS

/* --- Element type --- */
#define GST_TYPE_VF_METAL_COMPOSITOR (gst_vf_metal_compositor_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalCompositor, gst_vf_metal_compositor,
    GST, VF_METAL_COMPOSITOR, GstVideoAggregator)

/* --- Pad type --- */
#define GST_TYPE_VF_METAL_COMPOSITOR_PAD (gst_vf_metal_compositor_pad_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalCompositorPad, gst_vf_metal_compositor_pad,
    GST, VF_METAL_COMPOSITOR_PAD, GstVideoAggregatorPad)

/**
 * GstVfMetalCompositorBackground:
 * @VF_METAL_COMPOSITOR_BACKGROUND_CHECKER: checker pattern background
 * @VF_METAL_COMPOSITOR_BACKGROUND_BLACK: solid color black background
 * @VF_METAL_COMPOSITOR_BACKGROUND_WHITE: solid color white background
 * @VF_METAL_COMPOSITOR_BACKGROUND_TRANSPARENT: transparent background
 */
typedef enum
{
  VF_METAL_COMPOSITOR_BACKGROUND_CHECKER,
  VF_METAL_COMPOSITOR_BACKGROUND_BLACK,
  VF_METAL_COMPOSITOR_BACKGROUND_WHITE,
  VF_METAL_COMPOSITOR_BACKGROUND_TRANSPARENT,
} GstVfMetalCompositorBackground;

/**
 * GstVfMetalCompositorOperator:
 * @VF_METAL_COMPOSITOR_OPERATOR_SOURCE: Copy source over destination
 * @VF_METAL_COMPOSITOR_OPERATOR_OVER: Blend source over destination
 * @VF_METAL_COMPOSITOR_OPERATOR_ADD: Add source and destination alpha
 */
typedef enum
{
  VF_METAL_COMPOSITOR_OPERATOR_SOURCE,
  VF_METAL_COMPOSITOR_OPERATOR_OVER,
  VF_METAL_COMPOSITOR_OPERATOR_ADD,
} GstVfMetalCompositorOperator;

/**
 * GstVfMetalCompositorSizingPolicy:
 * @VF_METAL_COMPOSITOR_SIZING_POLICY_NONE: Scale without padding
 * @VF_METAL_COMPOSITOR_SIZING_POLICY_KEEP_ASPECT_RATIO: Keep aspect ratio with padding
 */
typedef enum
{
  VF_METAL_COMPOSITOR_SIZING_POLICY_NONE,
  VF_METAL_COMPOSITOR_SIZING_POLICY_KEEP_ASPECT_RATIO,
} GstVfMetalCompositorSizingPolicy;

/**
 * GstVfMetalCompositor:
 *
 * Metal-accelerated video compositor element.
 */
struct _GstVfMetalCompositor
{
  GstVideoAggregator videoaggregator;

  /* Properties */
  GstVfMetalCompositorBackground background;
  gboolean zero_size_is_unscaled;

  /* Metal rendering engine (opaque Obj-C object, cast to MetalCompositorRenderer* in .m) */
  void *renderer;
};

/**
 * GstVfMetalCompositorPad:
 *
 * Pad for the Metal compositor.
 */
struct _GstVfMetalCompositorPad
{
  GstVideoAggregatorPad parent;

  /* Properties */
  gint xpos, ypos;
  gint width, height;
  gdouble alpha;
  guint zorder;
  GstVfMetalCompositorSizingPolicy sizing_policy;
  GstVfMetalCompositorOperator op;

  /* Computed offsets for keep-aspect-ratio */
  gint x_offset;
  gint y_offset;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetalcompositor);

static inline gint
pad_zorder_compare (const GstVfMetalCompositorPad * pad1,
    const GstVfMetalCompositorPad * pad2)
{
  if (pad1->zorder < pad2->zorder) return -1;
  if (pad1->zorder > pad2->zorder) return 1;
  return 0;
}

G_END_DECLS

#endif /* __GST_VF_METAL_COMPOSITOR_H__ */
