/* Metal texture cache and format utilities
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

#ifndef __VF_METAL_TEXTURE_UTIL_H__
#define __VF_METAL_TEXTURE_UTIL_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <gst/video/video.h>

/* Input format index for pipeline selection */
typedef enum {
    VF_METAL_INPUT_RGBA  = 0,
    VF_METAL_INPUT_NV12  = 1,
    VF_METAL_INPUT_I420  = 2,
    VF_METAL_INPUT_COUNT = 3,
} VfMetalInputFormat;

/* Classify a GstVideoFormat into input format index */
VfMetalInputFormat vf_metal_input_format_index (GstVideoFormat format);

/* Determine color matrix index (0=BT.601, 1=BT.709) from a GstVideoFrame */
int vf_metal_color_matrix_for_frame (GstVideoFrame *frame);

/* Texture cache — avoids per-frame allocation for input textures */
@interface VfMetalTextureCache : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

/* Reset the frame index at the start of each frame */
- (void)resetFrameIndex;

/* Upload a plane from a GstVideoFrame into a cached Metal texture */
- (id<MTLTexture>)uploadPlane:(GstVideoFrame *)frame
                        plane:(int)planeIndex
                       format:(MTLPixelFormat)pixelFormat
                        width:(int)planeWidth
                       height:(int)planeHeight;

/* Clear all cached textures */
- (void)clear;

@end

#endif /* __VF_METAL_TEXTURE_UTIL_H__ */
