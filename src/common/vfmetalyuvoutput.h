/* Shared YUV output conversion helper
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

#ifndef __VF_METAL_YUV_OUTPUT_H__
#define __VF_METAL_YUV_OUTPUT_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <gst/video/video.h>

/* Encapsulates NV12/I420 output plane textures and compute pipeline states.
 * Provides configure, GPU dispatch, and CPU readback in one place. */
@interface VfMetalYUVOutput : NSObject

/* (Re)create output plane textures and compute pipelines for the given format.
 * For BGRA/RGBA formats the internal resources are released (no-op output). */
- (BOOL)configureWithDevice:(id<MTLDevice>)device
                    library:(id<MTLLibrary>)library
                      width:(NSUInteger)width
                     height:(NSUInteger)height
                     format:(GstVideoFormat)format;

/* Encode an RGBA→NV12 or RGBA→I420 compute pass into commandBuffer.
 * No-op when the configured format is BGRA/RGBA. */
- (void)dispatchConversion:(id<MTLCommandBuffer>)commandBuffer
             sourceTexture:(id<MTLTexture>)source
                     width:(NSUInteger)width
                    height:(NSUInteger)height
                  outFrame:(GstVideoFrame *)outFrame;

/* Read back Metal textures to the appropriate GstVideoFrame planes.
 * Handles NV12 (2-plane), I420 (3-plane), and BGRA/RGBA (1-plane). */
- (void)readbackToFrame:(GstVideoFrame *)outFrame
          sourceTexture:(id<MTLTexture>)rgbaSource
                  width:(NSUInteger)width
                 height:(NSUInteger)height;

/* Release all textures and pipeline states. */
- (void)cleanup;

@end

#endif /* __VF_METAL_YUV_OUTPUT_H__ */
