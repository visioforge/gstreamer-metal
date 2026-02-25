/* Metal video transform renderer
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

#ifndef __METAL_TRANSFORM_RENDERER_H__
#define __METAL_TRANSFORM_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <gst/video/video.h>

/* Transform method — matches GstVideoOrientationMethod values */
typedef enum {
    VF_METAL_TRANSFORM_IDENTITY = 0,
    VF_METAL_TRANSFORM_90R      = 1,
    VF_METAL_TRANSFORM_180      = 2,
    VF_METAL_TRANSFORM_90L      = 3,
    VF_METAL_TRANSFORM_HORIZ    = 4,
    VF_METAL_TRANSFORM_VERT     = 5,
    VF_METAL_TRANSFORM_UL_LR    = 6,   /* transpose: flip across UL-LR diagonal */
    VF_METAL_TRANSFORM_UR_LL    = 7,   /* flip across UR-LL diagonal */
} VfMetalTransformMethod;

/* Transform parameters */
typedef struct {
    VfMetalTransformMethod method;
    int cropTop;
    int cropBottom;
    int cropLeft;
    int cropRight;
} TransformParams;

@interface MetalTransformRenderer : NSObject

- (instancetype)init;

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo;

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const TransformParams *)params;

- (void)cleanup;

@end

#endif /* __METAL_TRANSFORM_RENDERER_H__ */
