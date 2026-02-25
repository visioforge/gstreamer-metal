/* GStreamer vfmetal plugin registration
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

#ifndef PACKAGE
#define PACKAGE "gst-vf-metal"
#endif

#include "compositor/gstvfmetalcompositor.h"
#ifndef DISABLE_VIDEOSINK
#include "videosink/gstvfmetalvideosink.h"
#endif
#include "videofilter/gstvfmetalvideofilter.h"
#include "convertscale/gstvfmetalconvertscale.h"
#include "transform/gstvfmetaltransform.h"
#include "deinterlace/gstvfmetaldeinterlace.h"
#include "overlay/gstvfmetaloverlay.h"

static gboolean
plugin_init (GstPlugin * plugin)
{
  gboolean ret = TRUE;

  ret &= GST_ELEMENT_REGISTER (vfmetalcompositor, plugin);
#ifndef DISABLE_VIDEOSINK
  ret &= GST_ELEMENT_REGISTER (vfmetalvideosink, plugin);
#endif
  ret &= GST_ELEMENT_REGISTER (vfmetalvideofilter, plugin);
  ret &= GST_ELEMENT_REGISTER (vfmetalconvertscale, plugin);
  ret &= GST_ELEMENT_REGISTER (vfmetaltransform, plugin);
  ret &= GST_ELEMENT_REGISTER (vfmetaldeinterlace, plugin);
  ret &= GST_ELEMENT_REGISTER (vfmetaloverlay, plugin);

  return ret;
}

GST_PLUGIN_DEFINE (GST_VERSION_MAJOR,
    GST_VERSION_MINOR,
    vfmetal,
    "Metal-accelerated video processing elements",
    plugin_init,
    "1.0.0",
    "LGPL",
    "GstVfMetal",
    "https://visioforge.com")
