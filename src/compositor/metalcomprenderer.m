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

#import "metalcomprenderer.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"
#import <QuartzCore/QuartzCore.h>

#include <gst/gst.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_compositor_debug);
#define GST_CAT_DEFAULT gst_vf_metal_compositor_debug

/* --- Compositor-specific Metal shader source --- */

static NSString *const kCompositorShaderSource = @R"(

// Vertex shader: transform quad position
vertex VertexOut compositorVertex(
    uint vid [[vertex_id]],
    constant float4 *vertexData [[buffer(0)]]
) {
    VertexOut out;
    float4 vd = vertexData[vid];
    out.position = float4(vd.xy, 0.0, 1.0);
    out.texcoord = vd.zw;
    return out;
}

// Fragment shader: sample BGRA/RGBA texture with alpha
fragment float4 compositorFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(s, in.texcoord);
    color.a *= uniforms.alpha;
    color.rgb *= color.a;
    return color;
}

// Fragment shader: NV12 (Y + interleaved UV)
fragment float4 compositorFragmentNV12(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, uniforms.colorMatrix);
    float4 color = float4(rgb, 1.0);
    color.a *= uniforms.alpha;
    color.rgb *= color.a;
    return color;
}

// Fragment shader: I420 (Y + separate U + separate V)
fragment float4 compositorFragmentI420(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, uniforms.colorMatrix);
    float4 color = float4(rgb, 1.0);
    color.a *= uniforms.alpha;
    color.rgb *= color.a;
    return color;
}

// Checker background
vertex VertexOut checkerVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texcoord = (positions[vid] + 1.0) * 0.5;
    out.texcoord.y = 1.0 - out.texcoord.y;
    return out;
}

fragment float4 checkerFragment(
    VertexOut in [[stage_in]],
    constant float2 &outputSize [[buffer(0)]]
) {
    int2 pos = int2(in.texcoord * outputSize);
    int checker = ((pos.x / 8) + (pos.y / 8)) % 2;
    float gray = checker ? 0.75 : 0.5;
    return float4(gray, gray, gray, 1.0);
}
)";

/* --- MetalCompositorRenderer implementation --- */

@implementation MetalCompositorRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states [inputFormat][blendMode] */
    id<MTLRenderPipelineState> _pipelines[VF_METAL_INPUT_COUNT][3];

    /* Checker background pipeline */
    id<MTLRenderPipelineState> _pipelineChecker;

    /* Shared YUV output helper */
    VfMetalYUVOutput *_yuvOutput;

    /* Output render target (always BGRA for compositing) */
    id<MTLTexture> _outputTexture;

    /* Current output configuration */
    int _outputWidth;
    int _outputHeight;
    GstVideoFormat _outputFormat;
    MTLPixelFormat _renderPixelFormat;  /* pixel format of compositing render target */

    /* Input texture cache */
    VfMetalTextureCache *_textureCache;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    VfMetalDevice *metalDevice = [VfMetalDevice sharedDevice];
    if (!metalDevice) {
        GST_ERROR ("MetalCompositorRenderer: No Metal device available");
        return nil;
    }

    _commandQueue = [metalDevice.device newCommandQueue];
    if (!_commandQueue) {
        GST_ERROR ("MetalCompositorRenderer: Failed to create command queue");
        return nil;
    }

    /* Compile shaders: concatenate common + compositor-specific source */
    NSString *fullSource = [kVfMetalCommonShaderSource
        stringByAppendingString:kCompositorShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalCompositorRenderer: Failed to compile shaders: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];
    _yuvOutput = [[VfMetalYUVOutput alloc] init];

    return self;
}

- (id<MTLRenderPipelineState>)createPipelineWithBlendMode:(MetalBlendMode)mode
                                             pixelFormat:(MTLPixelFormat)pixelFormat
                                        fragmentFunction:(NSString *)fragName
{
    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [_library newFunctionWithName:@"compositorVertex"];
    desc.fragmentFunction = [_library newFunctionWithName:fragName];
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;

    /* All modes use premultiplied alpha source */
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

    switch (mode) {
        case METAL_BLEND_SOURCE:
            /* Source replaces destination completely */
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].destinationRGBBlendFactor =
                MTLBlendFactorZero;
            desc.colorAttachments[0].sourceAlphaBlendFactor =
                MTLBlendFactorOne;
            desc.colorAttachments[0].destinationAlphaBlendFactor =
                MTLBlendFactorZero;
            break;

        case METAL_BLEND_OVER:
            /* Standard alpha-over compositing (premultiplied) */
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].destinationRGBBlendFactor =
                MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].sourceAlphaBlendFactor =
                MTLBlendFactorOne;
            desc.colorAttachments[0].destinationAlphaBlendFactor =
                MTLBlendFactorOneMinusSourceAlpha;
            break;

        case METAL_BLEND_ADD:
            /* Additive blending */
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].destinationRGBBlendFactor =
                MTLBlendFactorOne;
            desc.colorAttachments[0].sourceAlphaBlendFactor =
                MTLBlendFactorOne;
            desc.colorAttachments[0].destinationAlphaBlendFactor =
                MTLBlendFactorOne;
            break;
    }

    NSError *error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) {
        GST_ERROR ("MetalCompositorRenderer: Pipeline creation failed for blend mode %d: %s",
              mode, error.localizedDescription.UTF8String);
    }
    return state;
}

- (id<MTLRenderPipelineState>)createCheckerPipelineWithPixelFormat:(MTLPixelFormat)pixelFormat
{
    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [_library newFunctionWithName:@"checkerVertex"];
    desc.fragmentFunction = [_library newFunctionWithName:@"checkerFragment"];
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    desc.colorAttachments[0].blendingEnabled = NO;

    NSError *error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) {
        GST_ERROR ("MetalCompositorRenderer: Checker pipeline creation failed: %s",
              error.localizedDescription.UTF8String);
    }
    return state;
}

- (BOOL)configureWithWidth:(int)width
                    height:(int)height
                    format:(GstVideoFormat)format
{
    /* Only recreate if dimensions changed */
    if (_outputTexture && _outputWidth == width && _outputHeight == height &&
        _outputFormat == format) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _outputWidth = width;
    _outputHeight = height;
    _outputFormat = format;

    /* Compositing always happens in BGRA; for RGBA output we use RGBA */
    switch (format) {
        case GST_VIDEO_FORMAT_BGRA:
            _renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        case GST_VIDEO_FORMAT_RGBA:
            _renderPixelFormat = MTLPixelFormatRGBA8Unorm;
            break;
        case GST_VIDEO_FORMAT_NV12:
        case GST_VIDEO_FORMAT_I420:
            _renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        default:
            GST_ERROR ("MetalCompositorRenderer: Unsupported output format %d", format);
            return NO;
    }

    /* Create render pipeline states for each input format × blend mode */
    NSString *fragNames[VF_METAL_INPUT_COUNT] = {
        @"compositorFragment",
        @"compositorFragmentNV12",
        @"compositorFragmentI420"
    };

    for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
        for (int blend = 0; blend < 3; blend++) {
            _pipelines[fmt][blend] =
                [self createPipelineWithBlendMode:(MetalBlendMode)blend
                                      pixelFormat:_renderPixelFormat
                                 fragmentFunction:fragNames[fmt]];
            if (!_pipelines[fmt][blend]) {
                GST_ERROR ("MetalCompositorRenderer: Failed to create pipeline fmt=%d blend=%d",
                      fmt, blend);
                return NO;
            }
        }
    }

    _pipelineChecker =
        [self createCheckerPipelineWithPixelFormat:_renderPixelFormat];
    if (!_pipelineChecker) {
        GST_ERROR ("MetalCompositorRenderer: Failed to create checker pipeline");
        return NO;
    }

    /* Create output render target texture */
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_renderPixelFormat
                                     width:width
                                    height:height
                                 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    _outputTexture = [device newTextureWithDescriptor:desc];
    if (!_outputTexture) {
        GST_ERROR ("MetalCompositorRenderer: Failed to create output texture %dx%d",
              width, height);
        return NO;
    }

    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:width height:height format:format])
        return NO;

    return YES;
}

- (BOOL)compositeWithInputs:(MetalPadInput *)inputs
                      count:(int)count
                 background:(MetalBackgroundType)background
                   outFrame:(GstVideoFrame *)outFrame
{
    @autoreleasepool {
        [_textureCache resetFrameIndex];

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            GST_ERROR ("Failed to create Metal command buffer");
            return NO;
        }

        /* Set up render pass */
        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _outputTexture;
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        /* Set clear color and load action based on background */
        switch (background) {
            case METAL_BG_BLACK:
                rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpDesc.colorAttachments[0].clearColor =
                    MTLClearColorMake(0, 0, 0, 1);
                break;
            case METAL_BG_WHITE:
                rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpDesc.colorAttachments[0].clearColor =
                    MTLClearColorMake(1, 1, 1, 1);
                break;
            case METAL_BG_TRANSPARENT:
                rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpDesc.colorAttachments[0].clearColor =
                    MTLClearColorMake(0, 0, 0, 0);
                break;
            case METAL_BG_CHECKER:
                /* Will draw checker pattern in the render pass */
                rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpDesc.colorAttachments[0].clearColor =
                    MTLClearColorMake(0, 0, 0, 1);
                break;
        }

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        if (!encoder) return NO;

        /* Set viewport */
        MTLViewport viewport = {
            0, 0,
            (double)_outputWidth, (double)_outputHeight,
            0.0, 1.0
        };
        [encoder setViewport:viewport];

        /* Draw checker background if needed */
        if (background == METAL_BG_CHECKER) {
            [encoder setRenderPipelineState:_pipelineChecker];
            float outputSize[2] = {
                (float)_outputWidth, (float)_outputHeight
            };
            [encoder setFragmentBytes:outputSize
                               length:sizeof(outputSize)
                              atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0
                        vertexCount:4];
        }

        /* Draw each input pad */
        for (int i = 0; i < count; i++) {
            MetalPadInput *input = &inputs[i];
            GstVideoFormat fmt = GST_VIDEO_FRAME_FORMAT (input->frame);
            VfMetalInputFormat fmtIdx = vf_metal_input_format_index(fmt);
            int frameW = GST_VIDEO_FRAME_WIDTH (input->frame);
            int frameH = GST_VIDEO_FRAME_HEIGHT (input->frame);

            /* Select pipeline based on input format + blend mode */
            id<MTLRenderPipelineState> pipeline =
                _pipelines[fmtIdx][input->blend_mode];
            [encoder setRenderPipelineState:pipeline];

            /* Upload textures based on input format */
            if (fmtIdx == VF_METAL_INPUT_NV12) {
                id<MTLTexture> yTex =
                    [_textureCache uploadPlane:input->frame plane:0
                              format:MTLPixelFormatR8Unorm
                               width:frameW height:frameH];
                id<MTLTexture> uvTex =
                    [_textureCache uploadPlane:input->frame plane:1
                              format:MTLPixelFormatRG8Unorm
                               width:(frameW + 1) / 2 height:(frameH + 1) / 2];
                if (!yTex || !uvTex) continue;
                [encoder setFragmentTexture:yTex atIndex:0];
                [encoder setFragmentTexture:uvTex atIndex:1];
            } else if (fmtIdx == VF_METAL_INPUT_I420) {
                id<MTLTexture> yTex =
                    [_textureCache uploadPlane:input->frame plane:0
                              format:MTLPixelFormatR8Unorm
                               width:frameW height:frameH];
                id<MTLTexture> uTex =
                    [_textureCache uploadPlane:input->frame plane:1
                              format:MTLPixelFormatR8Unorm
                               width:(frameW + 1) / 2 height:(frameH + 1) / 2];
                id<MTLTexture> vTex =
                    [_textureCache uploadPlane:input->frame plane:2
                              format:MTLPixelFormatR8Unorm
                               width:(frameW + 1) / 2 height:(frameH + 1) / 2];
                if (!yTex || !uTex || !vTex) continue;
                [encoder setFragmentTexture:yTex atIndex:0];
                [encoder setFragmentTexture:uTex atIndex:1];
                [encoder setFragmentTexture:vTex atIndex:2];
            } else {
                /* BGRA / RGBA: single plane */
                MTLPixelFormat pixFmt = (fmt == GST_VIDEO_FORMAT_BGRA)
                    ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
                id<MTLTexture> tex =
                    [_textureCache uploadPlane:input->frame plane:0
                              format:pixFmt width:frameW height:frameH];
                if (!tex) continue;
                [encoder setFragmentTexture:tex atIndex:0];
            }

            /* Calculate NDC coordinates from pixel coordinates */
            float x = (2.0f * input->xpos / _outputWidth) - 1.0f;
            float y = 1.0f - (2.0f * input->ypos / _outputHeight);
            float w = 2.0f * input->width / _outputWidth;
            float h = 2.0f * input->height / _outputHeight;

            float vertices[] = {
                x,     y,       0.0f, 0.0f,
                x + w, y,       1.0f, 0.0f,
                x,     y - h,   0.0f, 1.0f,
                x + w, y - h,   1.0f, 1.0f,
            };

            [encoder setVertexBytes:vertices
                             length:sizeof(vertices)
                            atIndex:0];

            /* Set uniforms */
            VfMetalUniforms uniforms;
            uniforms.alpha = (float)input->alpha;
            uniforms.colorMatrix =
                vf_metal_color_matrix_for_frame(input->frame);
            uniforms.padding[0] = 0;
            uniforms.padding[1] = 0;

            [encoder setFragmentBytes:&uniforms
                               length:sizeof(uniforms)
                              atIndex:0];

            /* Draw quad */
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0
                        vertexCount:4];
        }

        [encoder endEncoding];

        /* If output is YUV, run compute shader to convert RGBA->YUV */
        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:_outputTexture
                                 width:_outputWidth height:_outputHeight
                              outFrame:outFrame];

        /* No synchronizeResource needed — we use MTLStorageModeShared,
         * so waitUntilCompleted alone guarantees CPU coherency. */

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Read back to GstVideoFrame */
        [_yuvOutput readbackToFrame:outFrame sourceTexture:_outputTexture
                              width:_outputWidth height:_outputHeight];

        return YES;
    }
}

- (void)cleanup
{
    [_textureCache clear];
    _outputTexture = nil;
    [_yuvOutput cleanup];
    for (int f = 0; f < VF_METAL_INPUT_COUNT; f++)
        for (int b = 0; b < 3; b++)
            _pipelines[f][b] = nil;
    _pipelineChecker = nil;
    /* _library is created once in init and must survive across stop/start
     * state cycles. ARC releases it when the renderer object is deallocated. */
}

@end
