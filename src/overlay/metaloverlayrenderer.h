/* Metal overlay renderer
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

#ifndef __METAL_OVERLAY_RENDERER_H__
#define __METAL_OVERLAY_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <gst/video/video.h>

typedef struct {
    float x;
    float y;
    float width;
    float height;
    float alpha;
} OverlayParams;

@interface MetalOverlayRenderer : NSObject

- (instancetype)init;

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo;

- (BOOL)loadImageFromFile:(const char *)path;
- (void)clearImage;

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const OverlayParams *)params;

- (void)cleanup;

@end

#endif /* __METAL_OVERLAY_RENDERER_H__ */
