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

#import "vfmetalyuvoutput.h"
#import "vfmetalshaders.h"
#import "vfmetaltextureutil.h"

@implementation VfMetalYUVOutput {
    id<MTLComputePipelineState> _computeNV12;
    id<MTLComputePipelineState> _computeI420;
    id<MTLTexture> _outputY;
    id<MTLTexture> _outputUV;
    id<MTLTexture> _outputU;
    id<MTLTexture> _outputV;
    GstVideoFormat _format;
}

- (BOOL)configureWithDevice:(id<MTLDevice>)device
                    library:(id<MTLLibrary>)library
                      width:(NSUInteger)width
                     height:(NSUInteger)height
                     format:(GstVideoFormat)format
{
    [self cleanup];
    _format = format;

    if (format != GST_VIDEO_FORMAT_NV12 && format != GST_VIDEO_FORMAT_I420)
        return YES;

    /* Y plane — full resolution */
    MTLTextureDescriptor *yDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                     width:width height:height mipmapped:NO];
    yDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    yDesc.storageMode = MTLStorageModeShared;
    _outputY = [device newTextureWithDescriptor:yDesc];
    if (!_outputY) return NO;

    if (format == GST_VIDEO_FORMAT_NV12) {
        MTLTextureDescriptor *uvDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                         width:(width + 1) / 2
                                        height:(height + 1) / 2
                                     mipmapped:NO];
        uvDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        uvDesc.storageMode = MTLStorageModeShared;
        _outputUV = [device newTextureWithDescriptor:uvDesc];
        if (!_outputUV) return NO;

        NSError *err = nil;
        id<MTLFunction> func = [library newFunctionWithName:@"rgbaToNV12"];
        _computeNV12 =
            [device newComputePipelineStateWithFunction:func error:&err];
        if (!_computeNV12) return NO;
    } else {
        MTLTextureDescriptor *cDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                         width:(width + 1) / 2
                                        height:(height + 1) / 2
                                     mipmapped:NO];
        cDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        cDesc.storageMode = MTLStorageModeShared;
        _outputU = [device newTextureWithDescriptor:cDesc];
        _outputV = [device newTextureWithDescriptor:cDesc];
        if (!_outputU || !_outputV) return NO;

        NSError *err = nil;
        id<MTLFunction> func = [library newFunctionWithName:@"rgbaToI420"];
        _computeI420 =
            [device newComputePipelineStateWithFunction:func error:&err];
        if (!_computeI420) return NO;
    }

    return YES;
}

- (void)dispatchConversion:(id<MTLCommandBuffer>)commandBuffer
             sourceTexture:(id<MTLTexture>)source
                     width:(NSUInteger)width
                    height:(NSUInteger)height
                  outFrame:(GstVideoFrame *)outFrame
{
    id<MTLComputePipelineState> pipeline = nil;

    if (_format == GST_VIDEO_FORMAT_NV12 && _computeNV12) {
        pipeline = _computeNV12;
    } else if (_format == GST_VIDEO_FORMAT_I420 && _computeI420) {
        pipeline = _computeI420;
    } else {
        return;
    }

    id<MTLComputeCommandEncoder> compute =
        [commandBuffer computeCommandEncoder];
    [compute setComputePipelineState:pipeline];
    [compute setTexture:source atIndex:0];
    [compute setTexture:_outputY atIndex:1];

    if (_format == GST_VIDEO_FORMAT_NV12) {
        [compute setTexture:_outputUV atIndex:2];
    } else {
        [compute setTexture:_outputU atIndex:2];
        [compute setTexture:_outputV atIndex:3];
    }

    VfMetalComputeUniforms cu = {
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .colorMatrix = vf_metal_color_matrix_for_frame (outFrame),
        .padding = 0
    };
    [compute setBytes:&cu length:sizeof(cu) atIndex:0];

    MTLSize tg = MTLSizeMake(16, 16, 1);
    MTLSize grid = MTLSizeMake((width + 15) / 16, (height + 15) / 16, 1);
    [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [compute endEncoding];
}

- (void)readbackToFrame:(GstVideoFrame *)outFrame
          sourceTexture:(id<MTLTexture>)rgbaSource
                  width:(NSUInteger)width
                 height:(NSUInteger)height
{
    GstVideoFormat fmt = GST_VIDEO_FRAME_FORMAT (outFrame);

    if (fmt == GST_VIDEO_FORMAT_NV12) {
        [_outputY getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 0)
               bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 0)
                fromRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0];
        [_outputUV getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 1)
                bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 1)
                 fromRegion:MTLRegionMake2D(0, 0, (width + 1) / 2,
                                            (height + 1) / 2)
                mipmapLevel:0];
    } else if (fmt == GST_VIDEO_FORMAT_I420) {
        [_outputY getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 0)
               bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 0)
                fromRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0];
        [_outputU getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 1)
               bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 1)
                fromRegion:MTLRegionMake2D(0, 0, (width + 1) / 2,
                                           (height + 1) / 2)
               mipmapLevel:0];
        [_outputV getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 2)
               bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 2)
                fromRegion:MTLRegionMake2D(0, 0, (width + 1) / 2,
                                           (height + 1) / 2)
               mipmapLevel:0];
    } else {
        [rgbaSource getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 0)
                 bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 0)
                  fromRegion:MTLRegionMake2D(0, 0, width, height)
                 mipmapLevel:0];
    }
}

- (void)cleanup
{
    _outputY = nil;
    _outputUV = nil;
    _outputU = nil;
    _outputV = nil;
    _computeNV12 = nil;
    _computeI420 = nil;
    _format = GST_VIDEO_FORMAT_UNKNOWN;
}

@end
