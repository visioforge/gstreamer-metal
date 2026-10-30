/* GStreamer Metal overlay element
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

#ifndef __GST_VF_METAL_OVERLAY_H__
#define __GST_VF_METAL_OVERLAY_H__

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideofilter.h>

G_BEGIN_DECLS

#define GST_TYPE_VF_METAL_OVERLAY (gst_vf_metal_overlay_get_type())
G_DECLARE_FINAL_TYPE (GstVfMetalOverlay, gst_vf_metal_overlay,
    GST, VF_METAL_OVERLAY, GstVideoFilter)

struct _GstVfMetalOverlay
{
  GstVideoFilter videofilter;

  /* The properties as last written; committed to the fields below in one
   * step when the write's notifications are dispatched, so a batch (one
   * g_object_set () or a freeze/thaw) is never seen half-applied. */
  gchar *pending_location;
  gint pending_x;
  gint pending_y;
  gint pending_width;
  gint pending_height;
  gdouble pending_alpha;
  gdouble pending_relative_x;
  gdouble pending_relative_y;

  /* The committed properties, what the streaming thread reads */
  gchar *location;
  gint x;
  gint y;
  gint width;
  gint height;
  gdouble alpha;
  gdouble relative_x;
  gdouble relative_y;

  /* State */
  gboolean image_loaded;

  /* Held while passthrough is computed and set */
  GMutex passthrough_lock;

  /* Metal rendering engine */
  void *renderer;
};

GST_ELEMENT_REGISTER_DECLARE (vfmetaloverlay);

G_END_DECLS

#endif /* __GST_VF_METAL_OVERLAY_H__ */
