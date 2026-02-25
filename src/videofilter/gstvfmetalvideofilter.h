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

#ifndef __GST_VF_METAL_VIDEO_FILTER_H__
#define __GST_VF_METAL_VIDEO_FILTER_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideofilter.h>

G_BEGIN_DECLS

#define GST_TYPE_VF_METAL_VIDEO_FILTER (gst_vf_metal_video_filter_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalVideoFilter, gst_vf_metal_video_filter,
    GST, VF_METAL_VIDEO_FILTER, GstVideoFilter)

/**
 * GstVfMetalVideoFilter:
 *
 * Metal-accelerated video filter element providing brightness, contrast,
 * saturation, hue, gamma, sharpness, sepia, invert, noise, vignette,
 * chroma key, and 3D LUT color grading — all in a single GPU pass.
 */
struct _GstVfMetalVideoFilter
{
  GstVideoFilter videofilter;

  /* Color adjustment properties */
  gdouble brightness;       /* [-1.0, 1.0], default 0.0 */
  gdouble contrast;         /* [0.0, 2.0], default 1.0 */
  gdouble saturation;       /* [0.0, 2.0], default 1.0 */
  gdouble hue;              /* [-1.0, 1.0], default 0.0 */
  gdouble gamma;            /* [0.01, 10.0], default 1.0 */

  /* Sharpness / blur */
  gdouble sharpness;        /* [-1.0, 1.0], default 0.0: <0 blur, >0 sharpen */

  /* Color effects */
  gdouble sepia;            /* [0.0, 1.0], default 0.0: sepia mix amount */
  gboolean invert;          /* default FALSE */
  gdouble noise;            /* [0.0, 1.0], default 0.0: film grain */
  gdouble vignette;         /* [0.0, 1.0], default 0.0: vignette darkness */

  /* Chroma key */
  gboolean chroma_key_enabled;
  guint chroma_key_color;       /* ARGB, default 0xFF00FF00 (green) */
  gdouble chroma_key_tolerance; /* [0.0, 1.0], default 0.2 */
  gdouble chroma_key_smoothness;/* [0.0, 1.0], default 0.1 */

  /* LUT */
  gchar *lut_file;          /* path to .cube or .png LUT file */

  /* Frame counter for noise randomization */
  guint64 frame_count;

  /* Metal rendering engine (opaque Obj-C object, cast to MetalVideoFilterRenderer* in .m) */
  void *renderer;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetalvideofilter);

G_END_DECLS

#endif /* __GST_VF_METAL_VIDEO_FILTER_H__ */
