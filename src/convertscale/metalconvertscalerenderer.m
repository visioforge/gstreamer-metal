/* Metal convertscale renderer
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

#import "metalconvertscalerenderer.h"
#import "metalconvertscale_shaders.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"

#include <gst/gst.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_convertscale_debug);
#define GST_CAT_DEFAULT gst_vf_metal_convertscale_debug

/* Input format enum for pipeline indexing */
typedef enum {
    CS_INPUT_RGBA = 0,
    CS_INPUT_NV12 = 1,
    CS_INPUT_I420 = 2,
    CS_INPUT_UYVY = 3,
    CS_INPUT_YUY2 = 4,
    CS_INPUT_COUNT = 5,
} CsInputFormat;

static CsInputFormat
cs_input_format_index (GstVideoFormat format)
{
    switch (format) {
        case GST_VIDEO_FORMAT_NV12: return CS_INPUT_NV12;
        case GST_VIDEO_FORMAT_I420: return CS_INPUT_I420;
        case GST_VIDEO_FORMAT_UYVY: return CS_INPUT_UYVY;
        case GST_VIDEO_FORMAT_YUY2: return CS_INPUT_YUY2;
        default: return CS_INPUT_RGBA;
    }
}

/* Shader uniform — must match ConvertScaleUniforms in MSL */
typedef struct {
    int32_t colorMatrix;
    int32_t padding1;
    float padding2[2];
} ConvertScaleUniformsGPU;

@implementation MetalConvertScaleRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states: [inputFormat][method] */
    id<MTLRenderPipelineState> _pipelines[CS_INPUT_COUNT][2];

    /* Shared YUV output helper (NV12/I420) */
    VfMetalYUVOutput *_yuvOutput;

    /* Compute pipelines for packed YUV output (UYVY/YUY2 only) */
    id<MTLComputePipelineState> _computeUYVY;
    id<MTLComputePipelineState> _computeYUY2;

    /* Intermediate RGBA render target (at output dimensions) */
    id<MTLTexture> _renderTarget;

    /* Packed YUV output texture (UYVY/YUY2 only) */
    id<MTLTexture> _outputPacked;

    /* Configuration */
    int _inWidth;
    int _inHeight;
    int _outWidth;
    int _outHeight;
    GstVideoFormat _inputFormat;
    GstVideoFormat _outputFormat;
    VfMetalScaleMethod _method;
    BOOL _addBorders;
    guint32 _borderColor;

    /* Viewport for letterboxing */
    float _viewportParams[4];   /* offsetX, offsetY, scaleX, scaleY in NDC */

    /* Input texture cache */
    VfMetalTextureCache *_textureCache;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    VfMetalDevice *metalDevice = [VfMetalDevice sharedDevice];
    if (!metalDevice) {
        GST_ERROR ("MetalConvertScaleRenderer: No Metal device available");
        return nil;
    }

    _commandQueue = [metalDevice.device newCommandQueue];
    if (!_commandQueue) {
        GST_ERROR ("MetalConvertScaleRenderer: Failed to create command queue");
        return nil;
    }

    /* Compile shaders: common + convertscale-specific */
    NSString *fullSource = [kVfMetalCommonShaderSource
        stringByAppendingString:kConvertScaleShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalConvertScaleRenderer: Failed to compile shaders: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];
    _yuvOutput = [[VfMetalYUVOutput alloc] init];

    return self;
}

- (void)_computeViewportWithAddBorders:(BOOL)addBorders
{
    if (!addBorders || _inWidth == 0 || _inHeight == 0) {
        /* No letterbox — fill entire output */
        _viewportParams[0] = 0.0f;
        _viewportParams[1] = 0.0f;
        _viewportParams[2] = 1.0f;
        _viewportParams[3] = 1.0f;
        return;
    }

    float srcAspect = (float)_inWidth / (float)_inHeight;
    float dstAspect = (float)_outWidth / (float)_outHeight;

    float scaleX, scaleY;
    if (srcAspect > dstAspect) {
        /* Source is wider — pillarbox (bars on top/bottom) */
        scaleX = 1.0f;
        scaleY = dstAspect / srcAspect;
    } else {
        /* Source is taller — letterbox (bars on left/right) */
        scaleX = srcAspect / dstAspect;
        scaleY = 1.0f;
    }

    _viewportParams[0] = 0.0f;     /* center offset X */
    _viewportParams[1] = 0.0f;     /* center offset Y */
    _viewportParams[2] = scaleX;
    _viewportParams[3] = scaleY;
}

- (BOOL)_createPipelinesForFormat:(MTLPixelFormat)renderPixelFormat
{
    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    /* Fragment shader names: [inputFormat][method] */
    NSString *fragBilinear[CS_INPUT_COUNT] = {
        @"convertScaleFragmentRGBA",
        @"convertScaleFragmentNV12",
        @"convertScaleFragmentI420",
        @"convertScaleFragmentUYVY",
        @"convertScaleFragmentYUY2",
    };
    NSString *fragNearest[CS_INPUT_COUNT] = {
        @"convertScaleFragmentRGBANearest",
        @"convertScaleFragmentNV12Nearest",
        @"convertScaleFragmentI420Nearest",
        @"convertScaleFragmentUYVY",   /* UYVY always nearest */
        @"convertScaleFragmentYUY2",   /* YUY2 always nearest */
    };

    id<MTLFunction> vertexFunc =
        [_library newFunctionWithName:@"convertScaleVertex"];
    if (!vertexFunc) {
        GST_ERROR ("Failed to find convertScaleVertex function");
        return NO;
    }

    for (int fmt = 0; fmt < CS_INPUT_COUNT; fmt++) {
        for (int m = 0; m < 2; m++) {
            NSString *fragName = (m == 0) ? fragBilinear[fmt] : fragNearest[fmt];

            MTLRenderPipelineDescriptor *desc =
                [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vertexFunc;
            desc.fragmentFunction = [_library newFunctionWithName:fragName];
            desc.colorAttachments[0].pixelFormat = renderPixelFormat;
            desc.colorAttachments[0].blendingEnabled = NO;

            if (!desc.fragmentFunction) {
                GST_ERROR ("Failed to find fragment function: %s",
                           fragName.UTF8String);
                return NO;
            }

            NSError *error = nil;
            _pipelines[fmt][m] =
                [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (!_pipelines[fmt][m]) {
                GST_ERROR ("Failed to create pipeline fmt=%d method=%d: %s",
                           fmt, m, error.localizedDescription.UTF8String);
                return NO;
            }
        }
    }

    return YES;
}

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo
                        method:(VfMetalScaleMethod)method
                    addBorders:(BOOL)addBorders
                   borderColor:(guint32)borderColor
{
    int inW = GST_VIDEO_INFO_WIDTH (inInfo);
    int inH = GST_VIDEO_INFO_HEIGHT (inInfo);
    int outW = GST_VIDEO_INFO_WIDTH (outInfo);
    int outH = GST_VIDEO_INFO_HEIGHT (outInfo);
    GstVideoFormat inFmt = GST_VIDEO_INFO_FORMAT (inInfo);
    GstVideoFormat outFmt = GST_VIDEO_INFO_FORMAT (outInfo);

    /* Check if reconfigure is needed */
    if (_renderTarget && _inWidth == inW && _inHeight == inH &&
        _outWidth == outW && _outHeight == outH &&
        _inputFormat == inFmt && _outputFormat == outFmt &&
        _method == method && _addBorders == addBorders &&
        _borderColor == borderColor) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _inWidth = inW;
    _inHeight = inH;
    _outWidth = outW;
    _outHeight = outH;
    _inputFormat = inFmt;
    _outputFormat = outFmt;
    _method = method;
    _addBorders = addBorders;
    _borderColor = borderColor;

    [self _computeViewportWithAddBorders:addBorders];

    /* Render target pixel format — always BGRA for intermediate */
    MTLPixelFormat renderPixelFormat;
    switch (outFmt) {
        case GST_VIDEO_FORMAT_RGBA:
            renderPixelFormat = MTLPixelFormatRGBA8Unorm;
            break;
        default:
            renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
    }

    /* Create render pipelines */
    if (![self _createPipelinesForFormat:renderPixelFormat]) {
        return NO;
    }

    /* Create render target at output dimensions */
    MTLTextureDescriptor *rtDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:renderPixelFormat
                                     width:outW
                                    height:outH
                                 mipmapped:NO];
    rtDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsageShaderWrite;
    rtDesc.storageMode = MTLStorageModeShared;

    _renderTarget = [device newTextureWithDescriptor:rtDesc];
    if (!_renderTarget) return NO;

    /* Clean up old packed output resources */
    _outputPacked = nil;
    _computeUYVY = nil;
    _computeYUY2 = nil;

    /* Configure NV12/I420 output via shared helper */
    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:outW height:outH format:outFmt])
        return NO;

    /* Create packed YUV output resources if needed */
    if (outFmt == GST_VIDEO_FORMAT_UYVY || outFmt == GST_VIDEO_FORMAT_YUY2) {
        MTLTextureDescriptor *packedDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:outW / 2
                                        height:outH
                                     mipmapped:NO];
        packedDesc.usage =
            MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        packedDesc.storageMode = MTLStorageModeShared;
        _outputPacked = [device newTextureWithDescriptor:packedDesc];
        if (!_outputPacked) return NO;

        NSError *error = nil;
        NSString *funcName = (outFmt == GST_VIDEO_FORMAT_UYVY)
            ? @"rgbaToUYVY" : @"rgbaToYUY2";
        id<MTLFunction> func = [_library newFunctionWithName:funcName];
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:func error:&error];
        if (!pipeline) return NO;

        if (outFmt == GST_VIDEO_FORMAT_UYVY) {
            _computeUYVY = pipeline;
        } else {
            _computeYUY2 = pipeline;
        }
    }

    return YES;
}

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
{
    @autoreleasepool {
        [_textureCache resetFrameIndex];

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            GST_ERROR ("Failed to create Metal command buffer");
            return NO;
        }

        GstVideoFormat inFmt = GST_VIDEO_FRAME_FORMAT (inFrame);
        CsInputFormat fmtIdx = cs_input_format_index (inFmt);
        int frameW = GST_VIDEO_FRAME_WIDTH (inFrame);
        int frameH = GST_VIDEO_FRAME_HEIGHT (inFrame);
        int methodIdx = (_method == VF_METAL_SCALE_NEAREST) ? 1 : 0;

        /* === Render pass: convert + scale to RGBA render target === */

        /* Clear render target with border color if letterboxing */
        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _renderTarget;

        if (_addBorders) {
            float r = ((_borderColor >> 16) & 0xFF) / 255.0f;
            float g = ((_borderColor >> 8) & 0xFF) / 255.0f;
            float b = (_borderColor & 0xFF) / 255.0f;
            float a = ((_borderColor >> 24) & 0xFF) / 255.0f;
            rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpDesc.colorAttachments[0].clearColor =
                MTLClearColorMake(r, g, b, a);
        } else {
            rpDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        }
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        if (!encoder) return NO;

        MTLViewport viewport = {
            0, 0, (double)_outWidth, (double)_outHeight, 0.0, 1.0
        };
        [encoder setViewport:viewport];
        [encoder setRenderPipelineState:_pipelines[fmtIdx][methodIdx]];

        /* Viewport transform for letterboxing */
        [encoder setVertexBytes:_viewportParams
                         length:sizeof(_viewportParams)
                        atIndex:0];

        /* Upload input textures */
        if (fmtIdx == CS_INPUT_NV12) {
            id<MTLTexture> yTex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:MTLPixelFormatR8Unorm
                           width:frameW height:frameH];
            id<MTLTexture> uvTex =
                [_textureCache uploadPlane:inFrame plane:1
                          format:MTLPixelFormatRG8Unorm
                           width:(frameW + 1) / 2 height:(frameH + 1) / 2];
            if (!yTex || !uvTex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:yTex atIndex:0];
            [encoder setFragmentTexture:uvTex atIndex:1];
        } else if (fmtIdx == CS_INPUT_I420) {
            id<MTLTexture> yTex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:MTLPixelFormatR8Unorm
                           width:frameW height:frameH];
            id<MTLTexture> uTex =
                [_textureCache uploadPlane:inFrame plane:1
                          format:MTLPixelFormatR8Unorm
                           width:(frameW + 1) / 2 height:(frameH + 1) / 2];
            id<MTLTexture> vTex =
                [_textureCache uploadPlane:inFrame plane:2
                          format:MTLPixelFormatR8Unorm
                           width:(frameW + 1) / 2 height:(frameH + 1) / 2];
            if (!yTex || !uTex || !vTex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:yTex atIndex:0];
            [encoder setFragmentTexture:uTex atIndex:1];
            [encoder setFragmentTexture:vTex atIndex:2];
        } else if (fmtIdx == CS_INPUT_UYVY || fmtIdx == CS_INPUT_YUY2) {
            /* Packed YUV: upload as RGBA8 at half width */
            id<MTLTexture> tex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:MTLPixelFormatRGBA8Unorm
                           width:frameW / 2 height:frameH];
            if (!tex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:tex atIndex:0];
        } else {
            /* BGRA/RGBA */
            MTLPixelFormat pixFmt = (inFmt == GST_VIDEO_FORMAT_BGRA)
                ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            id<MTLTexture> tex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:pixFmt width:frameW height:frameH];
            if (!tex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:tex atIndex:0];
        }

        /* Set uniforms */
        ConvertScaleUniformsGPU uniforms = {
            .colorMatrix = vf_metal_color_matrix_for_frame (inFrame),
            .padding1 = 0,
            .padding2 = {0, 0}
        };
        [encoder setFragmentBytes:&uniforms
                           length:sizeof(uniforms)
                          atIndex:0];

        /* Draw full-screen quad */
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
        [encoder endEncoding];

        /* === Output format conversion (if not BGRA/RGBA) === */

        GstVideoFormat outFmt = GST_VIDEO_FRAME_FORMAT (outFrame);

        /* NV12/I420 conversion via shared helper */
        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:_renderTarget
                                 width:_outWidth height:_outHeight
                              outFrame:outFrame];

        /* Packed YUV conversion (UYVY/YUY2) — local */
        if ((outFmt == GST_VIDEO_FORMAT_UYVY && _computeUYVY) ||
                   (outFmt == GST_VIDEO_FORMAT_YUY2 && _computeYUY2)) {
            id<MTLComputePipelineState> pipeline =
                (outFmt == GST_VIDEO_FORMAT_UYVY) ? _computeUYVY : _computeYUY2;

            id<MTLComputeCommandEncoder> compute =
                [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:pipeline];
            [compute setTexture:_renderTarget atIndex:0];
            [compute setTexture:_outputPacked atIndex:1];

            VfMetalComputeUniforms cu = {
                .width = (uint32_t)_outWidth,
                .height = (uint32_t)_outHeight,
                .colorMatrix = vf_metal_color_matrix_for_frame (outFrame),
                .padding = 0
            };
            [compute setBytes:&cu length:sizeof(cu) atIndex:0];

            MTLSize tg = MTLSizeMake(16, 16, 1);
            MTLSize grid = MTLSizeMake(
                (_outWidth / 2 + 15) / 16, (_outHeight + 15) / 16, 1);
            [compute dispatchThreadgroups:grid threadsPerThreadgroup:tg];
            [compute endEncoding];
        }

        /* Commit and wait */
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Read back to GstVideoFrame */
        if (outFmt == GST_VIDEO_FORMAT_UYVY ||
            outFmt == GST_VIDEO_FORMAT_YUY2) {
            [_outputPacked getBytes:GST_VIDEO_FRAME_PLANE_DATA (outFrame, 0)
                        bytesPerRow:GST_VIDEO_FRAME_PLANE_STRIDE (outFrame, 0)
                         fromRegion:MTLRegionMake2D(0, 0, _outWidth / 2,
                                                    _outHeight)
                        mipmapLevel:0];
        } else {
            [_yuvOutput readbackToFrame:outFrame sourceTexture:_renderTarget
                                  width:_outWidth height:_outHeight];
        }

        return YES;
    }
}

- (void)cleanup
{
    [_textureCache clear];
    _renderTarget = nil;
    [_yuvOutput cleanup];
    _outputPacked = nil;
    for (int f = 0; f < CS_INPUT_COUNT; f++) {
        _pipelines[f][0] = nil;
        _pipelines[f][1] = nil;
    }
    _computeUYVY = nil;
    _computeYUY2 = nil;
}

@end
