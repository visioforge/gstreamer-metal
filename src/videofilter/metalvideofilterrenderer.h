/* Metal video filter renderer
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

#ifndef __METAL_VIDEO_FILTER_RENDERER_H__
#define __METAL_VIDEO_FILTER_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <gst/video/video.h>

/* All filter parameters passed to the renderer per frame */
typedef struct {
    float brightness;
    float contrast;
    float saturation;
    float hue;              /* in radians [-pi, pi] */
    float gamma;
    float sharpness;
    float sepia;
    float noise;
    float vignette;
    int invert;
    int chromaKeyEnabled;
    float chromaKeyR, chromaKeyG, chromaKeyB;
    float chromaKeyTolerance;
    float chromaKeySmoothness;
    uint32_t frameIndex;
} VideoFilterParams;

@interface MetalVideoFilterRenderer : NSObject

- (instancetype)init;

/* Configure for new video format; called from set_info */
- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo;

/* Process a frame with all filter parameters */
- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const VideoFilterParams *)params;

/* Load a 3D LUT from a .cube or .png file */
- (BOOL)loadLUTFromFile:(const char *)path;

/* Clear the loaded LUT */
- (void)clearLUT;

/* Lifecycle */
- (void)cleanup;

@end

#endif /* __METAL_VIDEO_FILTER_RENDERER_H__ */
