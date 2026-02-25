/* Metal deinterlace renderer
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

#ifndef __METAL_DEINTERLACE_RENDERER_H__
#define __METAL_DEINTERLACE_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <gst/video/video.h>

typedef enum {
    VF_METAL_DEINTERLACE_BOB     = 0,
    VF_METAL_DEINTERLACE_WEAVE   = 1,
    VF_METAL_DEINTERLACE_LINEAR  = 2,
    VF_METAL_DEINTERLACE_GREEDYH = 3,
} VfMetalDeinterlaceMethod;

typedef struct {
    VfMetalDeinterlaceMethod method;
    int topFieldFirst;
    float motionThreshold;  /* for greedyh */
} DeinterlaceParams;

@interface MetalDeinterlaceRenderer : NSObject

- (instancetype)init;

- (BOOL)configureWithInfo:(GstVideoInfo *)info;

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const DeinterlaceParams *)params;

- (void)cleanup;

@end

#endif /* __METAL_DEINTERLACE_RENDERER_H__ */
