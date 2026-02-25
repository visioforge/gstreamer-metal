/* Metal convertscale renderer
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

#ifndef __METAL_CONVERTSCALE_RENDERER_H__
#define __METAL_CONVERTSCALE_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <gst/video/video.h>

/* Scaling interpolation method */
typedef enum {
    VF_METAL_SCALE_BILINEAR = 0,
    VF_METAL_SCALE_NEAREST  = 1,
} VfMetalScaleMethod;

@interface MetalConvertScaleRenderer : NSObject

- (instancetype)init;

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo
                        method:(VfMetalScaleMethod)method
                    addBorders:(BOOL)addBorders
                   borderColor:(guint32)borderColor;

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame;

- (void)cleanup;

@end

#endif /* __METAL_CONVERTSCALE_RENDERER_H__ */
