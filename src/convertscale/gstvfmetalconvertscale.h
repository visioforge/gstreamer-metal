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

#ifndef __GST_VF_METAL_CONVERTSCALE_H__
#define __GST_VF_METAL_CONVERTSCALE_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/base/gstbasetransform.h>

G_BEGIN_DECLS

#define GST_TYPE_VF_METAL_CONVERTSCALE (gst_vf_metal_convertscale_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalConvertScale, gst_vf_metal_convertscale,
    GST, VF_METAL_CONVERTSCALE, GstBaseTransform)

/**
 * GstVfMetalConvertScale:
 *
 * Metal-accelerated video format conversion and scaling element.
 * Combines videoconvert + videoscale functionality in a single GPU pass.
 * Supports BGRA, RGBA, NV12, I420, UYVY, and YUY2 formats with
 * bilinear or nearest-neighbor interpolation and optional letterboxing.
 */
struct _GstVfMetalConvertScale
{
  GstBaseTransform basetransform;

  /* Properties */
  gint method;              /* 0=bilinear, 1=nearest */
  gboolean add_borders;     /* letterbox/pillarbox */
  guint32 border_color;     /* ARGB border color */

  /* Negotiated video info */
  GstVideoInfo in_info;
  GstVideoInfo out_info;
  gboolean negotiated;

  /* Metal rendering engine (opaque Obj-C object) */
  void *renderer;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetalconvertscale);

G_END_DECLS

#endif /* __GST_VF_METAL_CONVERTSCALE_H__ */
