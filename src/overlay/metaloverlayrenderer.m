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

#import "metaloverlayrenderer.h"
#import "metaloverlay_shaders.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <gst/gst.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_overlay_debug);
#define GST_CAT_DEFAULT gst_vf_metal_overlay_debug

/* Shader uniform — must match OverlayUniforms in MSL */
typedef struct {
    float overlayX;
    float overlayY;
    float overlayWidth;
    float overlayHeight;
    float frameWidth;
    float frameHeight;
    float alpha;
    int32_t colorMatrix;
} OverlayUniformsGPU;

@implementation MetalOverlayRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states per input format */
    id<MTLRenderPipelineState> _pipelines[VF_METAL_INPUT_COUNT];

    /* Intermediate RGBA render target */
    id<MTLTexture> _renderTarget;

    /* Shared YUV output helper */
    VfMetalYUVOutput *_yuvOutput;

    /* Overlay image texture */
    id<MTLTexture> _overlayTexture;
    int _overlayWidth;
    int _overlayHeight;

    /* Configuration */
    int _width;
    int _height;
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
        stringByAppendingString:kOverlayShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalOverlayRenderer: Failed to compile shaders: %s",
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
    int w = GST_VIDEO_INFO_WIDTH (inInfo);
    int h = GST_VIDEO_INFO_HEIGHT (inInfo);
    GstVideoFormat inFmt = GST_VIDEO_INFO_FORMAT (inInfo);
    GstVideoFormat outFmt = GST_VIDEO_INFO_FORMAT (outInfo);

    if (_renderTarget && _width == w && _height == h &&
        _inputFormat == inFmt && _outputFormat == outFmt) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _width = w;
    _height = h;
    _inputFormat = inFmt;
    _outputFormat = outFmt;

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
        @"overlayFragmentRGBA",
        @"overlayFragmentNV12",
        @"overlayFragmentI420"
    };

    id<MTLFunction> vertexFunc =
        [_library newFunctionWithName:@"overlayVertex"];

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
            GST_ERROR ("Failed to create overlay pipeline for format %d: %s",
                       fmt, error.localizedDescription.UTF8String);
            return NO;
        }
    }

    /* Create render target */
    MTLTextureDescriptor *rtDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_renderPixelFormat
                                     width:w height:h mipmapped:NO];
    rtDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsageShaderWrite;
    rtDesc.storageMode = MTLStorageModeShared;

    _renderTarget = [device newTextureWithDescriptor:rtDesc];
    if (!_renderTarget) return NO;

    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:w height:h format:outFmt])
        return NO;

    return YES;
}

- (BOOL)loadImageFromFile:(const char *)path
{
    @autoreleasepool {
        if (!path || *path == '\0') {
            [self clearImage];
            return YES;
        }

        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSData *fileData = [NSData dataWithContentsOfFile:nsPath];
        if (!fileData) {
            GST_WARNING ("Failed to read overlay file: %s", path);
            return NO;
        }

        CGImageSourceRef source = CGImageSourceCreateWithData (
            (__bridge CFDataRef)fileData, NULL);
        if (!source) {
            GST_WARNING ("Failed to create image source: %s", path);
            return NO;
        }

        CGImageRef cgImage = CGImageSourceCreateImageAtIndex (source, 0, NULL);
        CFRelease (source);
        if (!cgImage) {
            GST_WARNING ("Failed to decode image: %s", path);
            return NO;
        }

        int imgW = (int) CGImageGetWidth (cgImage);
        int imgH = (int) CGImageGetHeight (cgImage);

        /* Decode into RGBA8 */
        int bytesPerRow = imgW * 4;
        uint8_t *pixels = (uint8_t *) malloc (bytesPerRow * imgH);
        if (!pixels) {
            CGImageRelease (cgImage);
            return NO;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB ();
        CGContextRef ctx = CGBitmapContextCreate (pixels, imgW, imgH, 8,
            bytesPerRow, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease (colorSpace);

        if (!ctx) {
            free (pixels);
            CGImageRelease (cgImage);
            return NO;
        }

        CGContextDrawImage (ctx, CGRectMake (0, 0, imgW, imgH), cgImage);
        CGContextRelease (ctx);
        CGImageRelease (cgImage);

        /* Create Metal texture */
        id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:imgW height:imgH
                                     mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        _overlayTexture = [device newTextureWithDescriptor:desc];
        if (!_overlayTexture) {
            free (pixels);
            return NO;
        }

        [_overlayTexture replaceRegion:MTLRegionMake2D(0, 0, imgW, imgH)
                           mipmapLevel:0
                             withBytes:pixels
                           bytesPerRow:bytesPerRow];
        free (pixels);

        _overlayWidth = imgW;
        _overlayHeight = imgH;

        GST_DEBUG ("Loaded overlay image: %dx%d from %s", imgW, imgH, path);
        return YES;
    }
}

- (void)clearImage
{
    _overlayTexture = nil;
    _overlayWidth = 0;
    _overlayHeight = 0;
}

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const OverlayParams *)params
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

        /* Build uniforms */
        float overlayW = (params->width > 0) ? params->width : _overlayWidth;
        float overlayH = (params->height > 0) ? params->height : _overlayHeight;

        OverlayUniformsGPU uniforms = {
            .overlayX = params->x,
            .overlayY = params->y,
            .overlayWidth = overlayW,
            .overlayHeight = overlayH,
            .frameWidth = (float)frameW,
            .frameHeight = (float)frameH,
            .alpha = params->alpha,
            .colorMatrix = vf_metal_color_matrix_for_frame (inFrame),
        };

        /* === Render pass === */

        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = _renderTarget;
        rpDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        if (!encoder) return NO;

        MTLViewport viewport = {
            0, 0, (double)_width, (double)_height, 0.0, 1.0
        };
        [encoder setViewport:viewport];
        [encoder setRenderPipelineState:_pipelines[fmtIdx]];

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
            if (_overlayTexture) {
                [encoder setFragmentTexture:_overlayTexture atIndex:2];
            }
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
            if (_overlayTexture) {
                [encoder setFragmentTexture:_overlayTexture atIndex:3];
            }
        } else {
            MTLPixelFormat pixFmt = (inFmt == GST_VIDEO_FORMAT_BGRA)
                ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            id<MTLTexture> tex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:pixFmt width:frameW height:frameH];
            if (!tex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:tex atIndex:0];
            if (_overlayTexture) {
                [encoder setFragmentTexture:_overlayTexture atIndex:1];
            }
        }

        [encoder setFragmentBytes:&uniforms
                           length:sizeof(uniforms)
                          atIndex:0];

        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
        [encoder endEncoding];

        /* === Output format conversion === */

        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:_renderTarget
                                 width:_width height:_height
                              outFrame:outFrame];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Read back */
        [_yuvOutput readbackToFrame:outFrame sourceTexture:_renderTarget
                              width:_width height:_height];

        return YES;
    }
}

- (void)cleanup
{
    [_textureCache clear];
    _renderTarget = nil;
    [_yuvOutput cleanup];
    _overlayTexture = nil;
    for (int f = 0; f < VF_METAL_INPUT_COUNT; f++)
        _pipelines[f] = nil;
}

@end
