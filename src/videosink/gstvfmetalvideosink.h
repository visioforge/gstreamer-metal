/* GStreamer Metal video sink element
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

#ifndef __GST_VF_METAL_VIDEO_SINK_H__
#define __GST_VF_METAL_VIDEO_SINK_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideosink.h>
#include <gst/video/videooverlay.h>
#include <gst/video/navigation.h>

G_BEGIN_DECLS

#define GST_TYPE_VF_METAL_VIDEO_SINK (gst_vf_metal_video_sink_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalVideoSink, gst_vf_metal_video_sink,
    GST, VF_METAL_VIDEO_SINK, GstVideoSink)

/**
 * GstVfMetalVideoSink:
 *
 * Metal-accelerated video sink element.
 */
struct _GstVfMetalVideoSink
{
  GstVideoSink videosink;

  /* Properties */
  gboolean force_aspect_ratio;

  /* Video info from set_caps */
  GstVideoInfo info;
  gboolean have_info;

  /* Window handle from GstVideoOverlay::set_window_handle */
  guintptr window_handle;

  /* Render rectangle from GstVideoOverlay::set_render_rectangle */
  gboolean have_render_rect;
  GstVideoRectangle render_rect;

  /* Whether to forward navigation events */
  gboolean handle_events;

  /* Metal rendering engine (opaque Obj-C object, cast to MetalVideoSinkRenderer* in .m) */
  void *renderer;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetalvideosink);

G_END_DECLS

#endif /* __GST_VF_METAL_VIDEO_SINK_H__ */
