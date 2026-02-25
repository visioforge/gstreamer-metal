/* Metal compositor renderer
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

#ifndef __METAL_COMP_RENDERER_H__
#define __METAL_COMP_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <gst/video/video.h>

typedef enum {
  METAL_BLEND_SOURCE = 0,
  METAL_BLEND_OVER = 1,
  METAL_BLEND_ADD = 2,
} MetalBlendMode;

typedef enum {
  METAL_BG_CHECKER = 0,
  METAL_BG_BLACK = 1,
  METAL_BG_WHITE = 2,
  METAL_BG_TRANSPARENT = 3,
} MetalBackgroundType;

/* Input pad descriptor for rendering */
typedef struct {
  GstVideoFrame *frame;
  gint xpos, ypos;
  gint width, height;
  gdouble alpha;
  MetalBlendMode blend_mode;
} MetalPadInput;

@interface MetalCompositorRenderer : NSObject

- (instancetype)init;
- (BOOL)configureWithWidth:(int)width
                    height:(int)height
                    format:(GstVideoFormat)format;
- (BOOL)compositeWithInputs:(MetalPadInput *)inputs
                      count:(int)count
                 background:(MetalBackgroundType)background
                   outFrame:(GstVideoFrame *)outFrame;
- (void)cleanup;

@end

#endif /* __METAL_COMP_RENDERER_H__ */
