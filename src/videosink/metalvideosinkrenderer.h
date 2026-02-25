/* Metal video sink renderer
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

#ifndef __METAL_VIDEO_SINK_RENDERER_H__
#define __METAL_VIDEO_SINK_RENDERER_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <gst/video/video.h>

@interface MetalVideoSinkRenderer : NSObject

- (instancetype)init;

/* Configure for new video format; called from set_caps */
- (BOOL)configureWithVideoInfo:(GstVideoInfo *)info;

/* Window management */
- (void)ensureWindowWithHandle:(guintptr)handle
                         width:(int)width
                        height:(int)height;
- (void)closeWindow;

/* Rendering */
- (BOOL)renderFrame:(GstVideoFrame *)frame;
- (void)updateDrawableSize;
- (void)expose;

/* Properties */
- (void)setForceAspectRatio:(BOOL)force;
- (void)setRenderRectangleX:(gint)x y:(gint)y
                      width:(gint)width height:(gint)height;
- (void)setHandleEvents:(BOOL)handle;

/* Navigation coordinate transform: view coords -> video coords */
- (void)transformNavigationX:(gdouble)x y:(gdouble)y
                    toVideoX:(gdouble *)vx videoY:(gdouble *)vy;

/* Lifecycle */
- (void)cleanup;

@end

#endif /* __METAL_VIDEO_SINK_RENDERER_H__ */
