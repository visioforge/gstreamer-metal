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

#import "metaldeinterlacerenderer.h"
#import "metaldeinterlace_shaders.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"

#include <gst/gst.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_deinterlace_debug);
#define GST_CAT_DEFAULT gst_vf_metal_deinterlace_debug

/* Shader uniform — must match DeinterlaceUniforms in MSL */
typedef struct {
    uint32_t width;
    uint32_t height;
    int32_t topFieldFirst;
    int32_t method;
    float motionThreshold;
    int32_t padding1;
    int32_t padding2;
    int32_t padding3;
} DeinterlaceUniformsGPU;

@implementation MetalDeinterlaceRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Compute pipelines */
    id<MTLComputePipelineState> _computeBob;
    id<MTLComputePipelineState> _computeLinear;
    id<MTLComputePipelineState> _computeWeave;
    id<MTLComputePipelineState> _computeGreedyH;

    /* Shared YUV output helper */
    VfMetalYUVOutput *_yuvOutput;

    /* Render pipelines for YUV→RGBA input conversion (GPU-side) */
    id<MTLRenderPipelineState> _yuvToRgbaNV12;
    id<MTLRenderPipelineState> _yuvToRgbaI420;

    /* Intermediate textures */
    id<MTLTexture> _inputRGBA;      /* Input uploaded/converted to RGBA */
    id<MTLTexture> _outputRGBA;     /* Deinterlaced output in RGBA */
    id<MTLTexture> _prevFrameRGBA;  /* Previous frame for weave/greedyh */

    /* Configuration */
    int _width;
    int _height;
    GstVideoFormat _format;

    VfMetalTextureCache *_textureCache;
    BOOL _hasPrevFrame;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    VfMetalDevice *metalDevice = [VfMetalDevice sharedDevice];
    if (!metalDevice) return nil;

    _commandQueue = [metalDevice.device newCommandQueue];
    if (!_commandQueue) return nil;

    NSString *fullSource = [kVfMetalCommonShaderSource
        stringByAppendingString:kDeinterlaceShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalDeinterlaceRenderer: Failed to compile shaders: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];

    id<MTLDevice> device = metalDevice.device;

    /* Create compute pipelines */
    id<MTLFunction> bobFunc = [_library newFunctionWithName:@"deinterlaceBob"];
    id<MTLFunction> linearFunc = [_library newFunctionWithName:@"deinterlaceLinear"];
    id<MTLFunction> weaveFunc = [_library newFunctionWithName:@"deinterlaceWeave"];
    id<MTLFunction> greedyHFunc = [_library newFunctionWithName:@"deinterlaceGreedyH"];

    _computeBob = [device newComputePipelineStateWithFunction:bobFunc error:&error];
    _computeLinear = [device newComputePipelineStateWithFunction:linearFunc error:&error];
    _computeWeave = [device newComputePipelineStateWithFunction:weaveFunc error:&error];
    _computeGreedyH = [device newComputePipelineStateWithFunction:greedyHFunc error:&error];

    if (!_computeBob || !_computeLinear || !_computeWeave || !_computeGreedyH) {
        GST_ERROR ("MetalDeinterlaceRenderer: Failed to create compute pipelines: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    /* Create render pipelines for YUV→RGBA GPU conversion */
    id<MTLFunction> vertFunc =
        [_library newFunctionWithName:@"deinterlacePassVertex"];

    {
        MTLRenderPipelineDescriptor *desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertFunc;
        desc.fragmentFunction =
            [_library newFunctionWithName:@"deinterlaceNV12ToRGBA"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *err = nil;
        _yuvToRgbaNV12 =
            [device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!_yuvToRgbaNV12) {
            GST_ERROR ("MetalDeinterlaceRenderer: Failed to create NV12 pipeline: %s",
                  err.localizedDescription.UTF8String);
            return nil;
        }
    }

    {
        MTLRenderPipelineDescriptor *desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertFunc;
        desc.fragmentFunction =
            [_library newFunctionWithName:@"deinterlaceI420ToRGBA"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *err = nil;
        _yuvToRgbaI420 =
            [device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!_yuvToRgbaI420) {
            GST_ERROR ("MetalDeinterlaceRenderer: Failed to create I420 pipeline: %s",
                  err.localizedDescription.UTF8String);
            return nil;
        }
    }

    _yuvOutput = [[VfMetalYUVOutput alloc] init];
    _hasPrevFrame = NO;

    return self;
}

- (BOOL)configureWithInfo:(GstVideoInfo *)info
{
    int w = GST_VIDEO_INFO_WIDTH (info);
    int h = GST_VIDEO_INFO_HEIGHT (info);
    GstVideoFormat fmt = GST_VIDEO_INFO_FORMAT (info);

    if (_inputRGBA && _width == w && _height == h && _format == fmt) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _width = w;
    _height = h;
    _format = fmt;
    _hasPrevFrame = NO;

    /* Create RGBA intermediate textures (always process in RGBA space) */
    MTLTextureDescriptor *rgbaDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    rgbaDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                     MTLTextureUsageRenderTarget;
    rgbaDesc.storageMode = MTLStorageModeShared;

    _inputRGBA = [device newTextureWithDescriptor:rgbaDesc];
    _outputRGBA = [device newTextureWithDescriptor:rgbaDesc];
    _prevFrameRGBA = [device newTextureWithDescriptor:rgbaDesc];
    if (!_inputRGBA || !_outputRGBA || !_prevFrameRGBA) return NO;

    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:w height:h format:fmt])
        return NO;

    return YES;
}

- (void)_uploadInputToRGBA:(GstVideoFrame *)inFrame
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [_textureCache resetFrameIndex];

    GstVideoFormat fmt = GST_VIDEO_FRAME_FORMAT (inFrame);
    int w = GST_VIDEO_FRAME_WIDTH (inFrame);
    int h = GST_VIDEO_FRAME_HEIGHT (inFrame);

    if (fmt == GST_VIDEO_FORMAT_BGRA || fmt == GST_VIDEO_FORMAT_RGBA) {
        /* Direct copy to RGBA texture */
        [_inputRGBA replaceRegion:MTLRegionMake2D(0, 0, w, h)
                      mipmapLevel:0
                        withBytes:GST_VIDEO_FRAME_PLANE_DATA (inFrame, 0)
                      bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (inFrame, 0)];
    } else if (fmt == GST_VIDEO_FORMAT_NV12) {
        /* Upload Y and UV planes as textures, convert via GPU render pass */
        id<MTLTexture> yTex =
            [_textureCache uploadPlane:inFrame plane:0
                        format:MTLPixelFormatR8Unorm
                         width:w height:h];
        id<MTLTexture> uvTex =
            [_textureCache uploadPlane:inFrame plane:1
                        format:MTLPixelFormatRG8Unorm
                         width:(w + 1) / 2 height:(h + 1) / 2];
        if (!yTex || !uvTex) return;

        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _inputRGBA;
        rpDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        [encoder setRenderPipelineState:_yuvToRgbaNV12];
        MTLViewport viewport = {0, 0, (double)w, (double)h, 0.0, 1.0};
        [encoder setViewport:viewport];

        VfMetalUniforms uniforms = {
            .alpha = 1.0f,
            .colorMatrix = vf_metal_color_matrix_for_frame(inFrame),
        };
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:yTex atIndex:0];
        [encoder setFragmentTexture:uvTex atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0 vertexCount:4];
        [encoder endEncoding];
    } else if (fmt == GST_VIDEO_FORMAT_I420) {
        /* Upload Y, U, V planes as textures, convert via GPU render pass */
        id<MTLTexture> yTex =
            [_textureCache uploadPlane:inFrame plane:0
                        format:MTLPixelFormatR8Unorm
                         width:w height:h];
        id<MTLTexture> uTex =
            [_textureCache uploadPlane:inFrame plane:1
                        format:MTLPixelFormatR8Unorm
                         width:(w + 1) / 2 height:(h + 1) / 2];
        id<MTLTexture> vTex =
            [_textureCache uploadPlane:inFrame plane:2
                        format:MTLPixelFormatR8Unorm
                         width:(w + 1) / 2 height:(h + 1) / 2];
        if (!yTex || !uTex || !vTex) return;

        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _inputRGBA;
        rpDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        [encoder setRenderPipelineState:_yuvToRgbaI420];
        MTLViewport viewport = {0, 0, (double)w, (double)h, 0.0, 1.0};
        [encoder setViewport:viewport];

        VfMetalUniforms uniforms = {
            .alpha = 1.0f,
            .colorMatrix = vf_metal_color_matrix_for_frame(inFrame),
        };
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:yTex atIndex:0];
        [encoder setFragmentTexture:uTex atIndex:1];
        [encoder setFragmentTexture:vTex atIndex:2];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0 vertexCount:4];
        [encoder endEncoding];
    }
}

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const DeinterlaceParams *)params
{
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            GST_ERROR ("Failed to create Metal command buffer");
            return NO;
        }

        /* Upload input to RGBA texture (GPU-side for YUV) */
        [self _uploadInputToRGBA:inFrame commandBuffer:commandBuffer];

        /* Build uniforms */
        DeinterlaceUniformsGPU uniforms = {
            .width = (uint32_t)_width,
            .height = (uint32_t)_height,
            .topFieldFirst = params->topFieldFirst,
            .method = (int32_t)params->method,
            .motionThreshold = params->motionThreshold,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        };

        MTLSize tg = MTLSizeMake(16, 16, 1);
        MTLSize grid = MTLSizeMake(
            (_width + 15) / 16, (_height + 15) / 16, 1);

        /* Run deinterlace compute kernel */
        BOOL needsPrevFrame = (params->method == VF_METAL_DEINTERLACE_WEAVE ||
                               params->method == VF_METAL_DEINTERLACE_GREEDYH);

        if (needsPrevFrame && !_hasPrevFrame) {
            /* No previous frame yet — fall back to bob */
            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:_computeBob];
            [compute setTexture:_inputRGBA atIndex:0];
            [compute setTexture:_outputRGBA atIndex:1];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        } else if (params->method == VF_METAL_DEINTERLACE_BOB) {
            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:_computeBob];
            [compute setTexture:_inputRGBA atIndex:0];
            [compute setTexture:_outputRGBA atIndex:1];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        } else if (params->method == VF_METAL_DEINTERLACE_LINEAR) {
            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:_computeLinear];
            [compute setTexture:_inputRGBA atIndex:0];
            [compute setTexture:_outputRGBA atIndex:1];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        } else if (params->method == VF_METAL_DEINTERLACE_WEAVE) {
            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:_computeWeave];
            [compute setTexture:_inputRGBA atIndex:0];
            [compute setTexture:_prevFrameRGBA atIndex:1];
            [compute setTexture:_outputRGBA atIndex:2];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        } else if (params->method == VF_METAL_DEINTERLACE_GREEDYH) {
            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:_computeGreedyH];
            [compute setTexture:_inputRGBA atIndex:0];
            [compute setTexture:_prevFrameRGBA atIndex:1];
            [compute setTexture:_outputRGBA atIndex:2];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        }

        /* Convert RGBA output to YUV if needed */
        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:_outputRGBA
                                 width:_width height:_height
                              outFrame:outFrame];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Save current as previous for next frame */
        id<MTLCommandBuffer> copyCmd = [_commandQueue commandBuffer];
        if (!copyCmd) {
            GST_ERROR ("Failed to create Metal command buffer for frame copy");
            return NO;
        }
        id<MTLBlitCommandEncoder> blit = [copyCmd blitCommandEncoder];
        [blit copyFromTexture:_inputRGBA toTexture:_prevFrameRGBA];
        [blit endEncoding];
        [copyCmd commit];
        [copyCmd waitUntilCompleted];
        _hasPrevFrame = YES;

        /* Read back */
        [_yuvOutput readbackToFrame:outFrame sourceTexture:_outputRGBA
                              width:_width height:_height];

        return YES;
    }
}

- (void)cleanup
{
    [_textureCache clear];
    _inputRGBA = nil;
    _outputRGBA = nil;
    _prevFrameRGBA = nil;
    [_yuvOutput cleanup];
    _hasPrevFrame = NO;
}

@end
