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

#import "metaltransformrenderer.h"
#import "metaltransform_shaders.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"

#include <gst/gst.h>
#include <math.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_transform_debug);
#define GST_CAT_DEFAULT gst_vf_metal_transform_debug

/* Shader uniform — must match TransformUniforms in MSL */
typedef struct {
    float uvTransform[4];   /* 2x2 matrix (column-major) */
    float uvOffset[2];
    int32_t colorMatrix;
    int32_t padding;
} TransformUniformsGPU;

/* Build UV transform matrix for a given method */
static void
build_uv_transform (VfMetalTransformMethod method, float *mat, float *offset)
{
    /* mat is column-major 2x2: [m00 m10 m01 m11] */
    /* Default: identity */
    mat[0] = 1; mat[1] = 0;
    mat[2] = 0; mat[3] = 1;
    offset[0] = 0; offset[1] = 0;

    switch (method) {
        case VF_METAL_TRANSFORM_IDENTITY:
            break;
        case VF_METAL_TRANSFORM_90R:
            /* 90° clockwise: u' = v, v' = 1-u → mat = [[0,1],[−1,0]], off = [0,1] →
             * Actually: u'=1-v, v'=u → mat=[[0,1],[-1,0]], off=[1,0]
             * Let me think more carefully.
             * We want the output image to be the input rotated 90° clockwise.
             * For output pixel at normalized (u,v), we want to sample from input at:
             *   srcU = v, srcV = 1 - u
             * So: srcUV = mat * (uv - 0.5) + 0.5 + offset
             * With centered coords c = uv - 0.5:
             *   srcC.x = c.y → mat row0 = [0, 1]
             *   srcC.y = -c.x → mat row1 = [-1, 0]
             * Column-major: mat[0]=0, mat[1]=-1, mat[2]=1, mat[3]=0
             * offset = 0 (the re-centering handles it)
             */
            mat[0] = 0; mat[1] = -1;
            mat[2] = 1; mat[3] = 0;
            break;
        case VF_METAL_TRANSFORM_180:
            /* 180°: srcU = 1-u, srcV = 1-v → centered: -c */
            mat[0] = -1; mat[1] = 0;
            mat[2] = 0;  mat[3] = -1;
            break;
        case VF_METAL_TRANSFORM_90L:
            /* 90° counter-clockwise: srcU = 1-v, srcV = u */
            mat[0] = 0;  mat[1] = 1;
            mat[2] = -1; mat[3] = 0;
            break;
        case VF_METAL_TRANSFORM_HORIZ:
            /* Horizontal flip: srcU = 1-u, srcV = v */
            mat[0] = -1; mat[1] = 0;
            mat[2] = 0;  mat[3] = 1;
            break;
        case VF_METAL_TRANSFORM_VERT:
            /* Vertical flip: srcU = u, srcV = 1-v */
            mat[0] = 1;  mat[1] = 0;
            mat[2] = 0;  mat[3] = -1;
            break;
        case VF_METAL_TRANSFORM_UL_LR:
            /* Transpose (flip across main diagonal): srcU = v, srcV = u */
            mat[0] = 0; mat[1] = 1;
            mat[2] = 1; mat[3] = 0;
            break;
        case VF_METAL_TRANSFORM_UR_LL:
            /* Anti-transpose: srcU = 1-v, srcV = 1-u */
            mat[0] = 0;  mat[1] = -1;
            mat[2] = -1; mat[3] = 0;
            break;
    }
}

@implementation MetalTransformRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states per input format */
    id<MTLRenderPipelineState> _pipelines[VF_METAL_INPUT_COUNT];

    /* Intermediate RGBA render target */
    id<MTLTexture> _renderTarget;

    /* Shared YUV output helper */
    VfMetalYUVOutput *_yuvOutput;

    /* Configuration */
    int _inWidth;
    int _inHeight;
    int _outWidth;
    int _outHeight;
    GstVideoFormat _inputFormat;
    GstVideoFormat _outputFormat;
    MTLPixelFormat _renderPixelFormat;

    VfMetalTextureCache *_textureCache;
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
        stringByAppendingString:kTransformShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalTransformRenderer: Failed to compile shaders: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];
    _yuvOutput = [[VfMetalYUVOutput alloc] init];

    return self;
}

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo
{
    int inW = GST_VIDEO_INFO_WIDTH (inInfo);
    int inH = GST_VIDEO_INFO_HEIGHT (inInfo);
    int outW = GST_VIDEO_INFO_WIDTH (outInfo);
    int outH = GST_VIDEO_INFO_HEIGHT (outInfo);
    GstVideoFormat inFmt = GST_VIDEO_INFO_FORMAT (inInfo);
    GstVideoFormat outFmt = GST_VIDEO_INFO_FORMAT (outInfo);

    if (_renderTarget && _inWidth == inW && _inHeight == inH &&
        _outWidth == outW && _outHeight == outH &&
        _inputFormat == inFmt && _outputFormat == outFmt) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _inWidth = inW;
    _inHeight = inH;
    _outWidth = outW;
    _outHeight = outH;
    _inputFormat = inFmt;
    _outputFormat = outFmt;

    /* Render pixel format */
    switch (outFmt) {
        case GST_VIDEO_FORMAT_RGBA:
            _renderPixelFormat = MTLPixelFormatRGBA8Unorm;
            break;
        default:
            _renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
    }

    /* Create render pipelines */
    NSString *fragNames[VF_METAL_INPUT_COUNT] = {
        @"transformFragmentRGBA",
        @"transformFragmentNV12",
        @"transformFragmentI420"
    };

    id<MTLFunction> vertexFunc =
        [_library newFunctionWithName:@"transformVertex"];

    for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
        MTLRenderPipelineDescriptor *desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertexFunc;
        desc.fragmentFunction = [_library newFunctionWithName:fragNames[fmt]];
        desc.colorAttachments[0].pixelFormat = _renderPixelFormat;
        desc.colorAttachments[0].blendingEnabled = NO;

        NSError *error = nil;
        _pipelines[fmt] =
            [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_pipelines[fmt]) {
            GST_ERROR ("Failed to create transform pipeline for format %d: %s",
                       fmt, error.localizedDescription.UTF8String);
            return NO;
        }
    }

    /* Create render target */
    MTLTextureDescriptor *rtDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_renderPixelFormat
                                     width:outW
                                    height:outH
                                 mipmapped:NO];
    rtDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsageShaderWrite;
    rtDesc.storageMode = MTLStorageModeShared;

    _renderTarget = [device newTextureWithDescriptor:rtDesc];
    if (!_renderTarget) return NO;

    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:outW height:outH format:outFmt])
        return NO;

    return YES;
}

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const TransformParams *)params
{
    @autoreleasepool {
        [_textureCache resetFrameIndex];

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            GST_ERROR ("Failed to create Metal command buffer");
            return NO;
        }

        GstVideoFormat inFmt = GST_VIDEO_FRAME_FORMAT (inFrame);
        VfMetalInputFormat fmtIdx = vf_metal_input_format_index (inFmt);
        int frameW = GST_VIDEO_FRAME_WIDTH (inFrame);
        int frameH = GST_VIDEO_FRAME_HEIGHT (inFrame);

        /* Build UV transform */
        TransformUniformsGPU uniforms;
        memset (&uniforms, 0, sizeof (uniforms));

        /* Compute crop UV offset and scale */
        float cropL = (float)params->cropLeft / (float)frameW;
        float cropR = (float)params->cropRight / (float)frameW;
        float cropT = (float)params->cropTop / (float)frameH;
        float cropB = (float)params->cropBottom / (float)frameH;

        float cropScaleX = 1.0f - cropL - cropR;
        float cropScaleY = 1.0f - cropT - cropB;
        float cropOffsetX = (cropL - cropR) * 0.5f;
        float cropOffsetY = (cropT - cropB) * 0.5f;

        /* Get transform matrix */
        float transMat[4], transOff[2];
        build_uv_transform (params->method, transMat, transOff);

        /* Combine: first apply crop scale, then transform rotation
         * UV = transform * (crop_scale * centered_uv) + offsets
         * Combined matrix = transform * diag(cropScale)
         */
        uniforms.uvTransform[0] = transMat[0] * cropScaleX;
        uniforms.uvTransform[1] = transMat[1] * cropScaleX;
        uniforms.uvTransform[2] = transMat[2] * cropScaleY;
        uniforms.uvTransform[3] = transMat[3] * cropScaleY;

        /* Offset: transform the crop offset, then add transform offset */
        uniforms.uvOffset[0] = transMat[0] * cropOffsetX +
                               transMat[2] * cropOffsetY + transOff[0];
        uniforms.uvOffset[1] = transMat[1] * cropOffsetX +
                               transMat[3] * cropOffsetY + transOff[1];

        uniforms.colorMatrix = vf_metal_color_matrix_for_frame (inFrame);
        uniforms.padding = 0;

        /* === Render pass === */

        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _renderTarget;
        rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        if (!encoder) return NO;

        MTLViewport viewport = {
            0, 0, (double)_outWidth, (double)_outHeight, 0.0, 1.0
        };
        [encoder setViewport:viewport];
        [encoder setRenderPipelineState:_pipelines[fmtIdx]];

        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];

        /* Upload input textures */
        if (fmtIdx == VF_METAL_INPUT_NV12) {
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
        } else if (fmtIdx == VF_METAL_INPUT_I420) {
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
        } else {
            MTLPixelFormat pixFmt = (inFmt == GST_VIDEO_FORMAT_BGRA)
                ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            id<MTLTexture> tex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:pixFmt width:frameW height:frameH];
            if (!tex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:tex atIndex:0];
        }

        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
        [encoder endEncoding];

        /* === Output format conversion === */

        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:_renderTarget
                                 width:_outWidth height:_outHeight
                              outFrame:outFrame];

        /* Commit and wait */
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Read back */
        [_yuvOutput readbackToFrame:outFrame sourceTexture:_renderTarget
                              width:_outWidth height:_outHeight];

        return YES;
    }
}

- (void)cleanup
{
    [_textureCache clear];
    _renderTarget = nil;
    [_yuvOutput cleanup];
    for (int f = 0; f < VF_METAL_INPUT_COUNT; f++)
        _pipelines[f] = nil;
}

@end
