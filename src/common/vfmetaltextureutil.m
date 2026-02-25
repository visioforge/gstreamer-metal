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

#import "vfmetaltextureutil.h"
#import "vfmetaldevice.h"

VfMetalInputFormat
vf_metal_input_format_index (GstVideoFormat format)
{
    switch (format) {
        case GST_VIDEO_FORMAT_NV12: return VF_METAL_INPUT_NV12;
        case GST_VIDEO_FORMAT_I420: return VF_METAL_INPUT_I420;
        default: return VF_METAL_INPUT_RGBA;
    }
}

int
vf_metal_color_matrix_for_frame (GstVideoFrame *frame)
{
    GstVideoColorMatrix matrix =
        GST_VIDEO_INFO_COLORIMETRY (&frame->info).matrix;
    return (matrix == GST_VIDEO_COLOR_MATRIX_BT709) ? 1 : 0;
}

@implementation VfMetalTextureCache {
    id<MTLDevice> _device;
    NSMutableArray<id<MTLTexture>> *_cache;
    int _cacheIndex;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (!self) return nil;
    _device = device;
    _cache = [NSMutableArray array];
    _cacheIndex = 0;
    return self;
}

- (void)resetFrameIndex
{
    _cacheIndex = 0;
}

- (id<MTLTexture>)uploadPlane:(GstVideoFrame *)frame
                        plane:(int)planeIndex
                       format:(MTLPixelFormat)pixelFormat
                        width:(int)planeWidth
                       height:(int)planeHeight
{
    id<MTLTexture> texture = nil;

    /* Check cache for a reusable texture at the current slot */
    if (_cacheIndex < (int)_cache.count) {
        id<MTLTexture> cached = _cache[_cacheIndex];
        if (cached.pixelFormat == pixelFormat &&
            (int)cached.width == planeWidth &&
            (int)cached.height == planeHeight) {
            texture = cached;
        }
    }

    /* Create new texture if cache miss */
    if (!texture) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:pixelFormat
                                         width:planeWidth
                                        height:planeHeight
                                     mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        texture = [_device newTextureWithDescriptor:desc];
        if (!texture) {
            _cacheIndex++;
            return nil;
        }

        /* Update cache */
        if (_cacheIndex < (int)_cache.count) {
            _cache[_cacheIndex] = texture;
        } else {
            [_cache addObject:texture];
        }
    }

    _cacheIndex++;

    [texture replaceRegion:MTLRegionMake2D(0, 0, planeWidth, planeHeight)
               mipmapLevel:0
                 withBytes:GST_VIDEO_FRAME_PLANE_DATA (frame, planeIndex)
               bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (frame, planeIndex)];

    return texture;
}

- (void)clear
{
    [_cache removeAllObjects];
    _cacheIndex = 0;
}

@end
