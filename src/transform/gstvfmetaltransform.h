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

#ifndef __GST_VF_METAL_TRANSFORM_H__
#define __GST_VF_METAL_TRANSFORM_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideofilter.h>

G_BEGIN_DECLS

#define GST_TYPE_VF_METAL_TRANSFORM (gst_vf_metal_transform_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalTransform, gst_vf_metal_transform,
    GST, VF_METAL_TRANSFORM, GstVideoFilter)

/**
 * GstVfMetalTransform:
 *
 * Metal-accelerated video transform element providing flip, rotate,
 * and crop operations. Similar to videoflip but GPU-accelerated.
 */
struct _GstVfMetalTransform
{
  GstVideoFilter videofilter;

  /* Properties */
  gint method;          /* VfMetalTransformMethod enum */
  gint crop_top;
  gint crop_bottom;
  gint crop_left;
  gint crop_right;

  /* Metal rendering engine */
  void *renderer;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetaltransform);

G_END_DECLS

#endif /* __GST_VF_METAL_TRANSFORM_H__ */
