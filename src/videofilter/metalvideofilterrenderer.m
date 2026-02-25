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

#import "metalvideofilterrenderer.h"
#import "metalvideofilter_shaders.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"
#import "vfmetalyuvoutput.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <gst/gst.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_video_filter_debug);
#define GST_CAT_DEFAULT gst_vf_metal_video_filter_debug

/* Shader uniform struct — must match FilterUniforms in MSL */
typedef struct {
    float brightness;
    float contrast;
    float saturation;
    float hue;
    float gamma;
    float sharpness;
    float sepia;
    float noise;
    float vignette;
    int32_t invert;
    int32_t chromaKeyEnabled;
    float chromaKeyR;
    float chromaKeyG;
    float chromaKeyB;
    float chromaKeyTolerance;
    float chromaKeySmoothness;
    uint32_t width;
    uint32_t height;
    int32_t colorMatrix;
    uint32_t frameIndex;
    int32_t hasLUT;
    int32_t lutSize;
    float padding;
} FilterUniformsGPU;

/* --- .cube LUT parser --- */

static id<MTLTexture>
parse_cube_lut (const char *path, id<MTLDevice> device, int *outSize)
{
    FILE *fp = fopen (path, "r");
    if (!fp) {
        GST_WARNING ("Failed to open .cube file: %s", path);
        return nil;
    }

    int size = 0;
    float *data = NULL;
    int count = 0;
    char line[512];

    while (fgets (line, sizeof (line), fp)) {
        /* Skip comments and empty lines */
        char *p = line;
        while (*p && isspace (*p)) p++;
        if (*p == '#' || *p == '\0' || *p == '\n') continue;

        /* Parse LUT_3D_SIZE */
        if (strncmp (p, "LUT_3D_SIZE", 11) == 0) {
            sscanf (p + 11, "%d", &size);
            if (size < 2 || size > 64) {
                GST_WARNING ("Invalid LUT size %d in %s", size, path);
                fclose (fp);
                return nil;
            }
            data = (float *) malloc (size * size * size * 4 * sizeof (float));
            if (!data) {
                fclose (fp);
                return nil;
            }
            continue;
        }

        /* Skip other keywords */
        if (strncmp (p, "TITLE", 5) == 0 ||
            strncmp (p, "DOMAIN_MIN", 10) == 0 ||
            strncmp (p, "DOMAIN_MAX", 10) == 0 ||
            strncmp (p, "LUT_1D_SIZE", 11) == 0) {
            continue;
        }

        /* Parse RGB triplet */
        if (size > 0 && data && count < size * size * size) {
            float r, g, b;
            if (sscanf (p, "%f %f %f", &r, &g, &b) == 3) {
                data[count * 4 + 0] = r;
                data[count * 4 + 1] = g;
                data[count * 4 + 2] = b;
                data[count * 4 + 3] = 1.0f;
                count++;
            }
        }
    }

    fclose (fp);

    if (size == 0 || count != size * size * size) {
        GST_WARNING ("Incomplete .cube LUT: expected %d entries, got %d",
                     size * size * size, count);
        free (data);
        return nil;
    }

    /* Create 3D texture */
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.width = size;
    desc.height = size;
    desc.depth = size;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) {
        free (data);
        return nil;
    }

    [texture replaceRegion:MTLRegionMake3D (0, 0, 0, size, size, size)
               mipmapLevel:0
                     slice:0
                 withBytes:data
               bytesPerRow:size * 4 * sizeof (float)
             bytesPerImage:size * size * 4 * sizeof (float)];

    free (data);
    *outSize = size;

    GST_DEBUG ("Loaded .cube LUT: %dx%dx%d from %s", size, size, size, path);
    return texture;
}

/* --- PNG LUT loader --- */

static id<MTLTexture>
parse_png_lut (const char *path, id<MTLDevice> device, int *outSize)
{
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSData *fileData = [NSData dataWithContentsOfFile:nsPath];
        if (!fileData) {
            GST_WARNING ("Failed to read PNG LUT file: %s", path);
            return nil;
        }

        /* Use CGImageSource to decode the PNG */
        CGImageSourceRef source = CGImageSourceCreateWithData (
            (__bridge CFDataRef)fileData, NULL);
        if (!source) {
            GST_WARNING ("Failed to create image source from: %s", path);
            return nil;
        }

        CGImageRef cgImage = CGImageSourceCreateImageAtIndex (source, 0, NULL);
        CFRelease (source);
        if (!cgImage) {
            GST_WARNING ("Failed to decode PNG: %s", path);
            return nil;
        }

        int imgWidth = (int) CGImageGetWidth (cgImage);
        int imgHeight = (int) CGImageGetHeight (cgImage);

        /* Determine LUT size from image dimensions.
         * Common layouts:
         * - 512x512 for 64x64x64 (8 slices horizontally × 8 vertically)
         * - 256x16 for 16x16x16 (16 slices horizontally)
         * - NxN where N = size * size (slices arranged in a square grid) */
        int lutSize = 0;

        /* Try square root approach: size = cbrt(width * height) */
        int totalPixels = imgWidth * imgHeight;
        for (int s = 2; s <= 256; s++) {
            if (s * s * s == totalPixels) {
                lutSize = s;
                break;
            }
        }

        if (lutSize == 0) {
            GST_WARNING ("Cannot determine LUT size from %dx%d PNG", imgWidth, imgHeight);
            CGImageRelease (cgImage);
            return nil;
        }

        /* Decode into RGBA8 buffer */
        int bytesPerRow = imgWidth * 4;
        uint8_t *pixels = (uint8_t *) malloc (bytesPerRow * imgHeight);
        if (!pixels) {
            CGImageRelease (cgImage);
            return nil;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB ();
        CGContextRef ctx = CGBitmapContextCreate (pixels, imgWidth, imgHeight, 8,
            bytesPerRow, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease (colorSpace);

        if (!ctx) {
            free (pixels);
            CGImageRelease (cgImage);
            return nil;
        }

        CGContextDrawImage (ctx, CGRectMake (0, 0, imgWidth, imgHeight), cgImage);
        CGContextRelease (ctx);
        CGImageRelease (cgImage);

        /* Convert to float RGBA and rearrange into 3D */
        float *lutData = (float *) malloc (
            lutSize * lutSize * lutSize * 4 * sizeof (float));
        if (!lutData) {
            free (pixels);
            return nil;
        }

        int slicesPerRow = imgWidth / lutSize;
        if (slicesPerRow == 0) {
            GST_WARNING ("LUT PNG too narrow (%d < %d)", imgWidth, lutSize);
            free (pixels);
            return nil;
        }

        for (int b = 0; b < lutSize; b++) {
            int sliceX = (b % slicesPerRow) * lutSize;
            int sliceY = (b / slicesPerRow) * lutSize;
            for (int g = 0; g < lutSize; g++) {
                for (int r = 0; r < lutSize; r++) {
                    int srcX = sliceX + r;
                    int srcY = sliceY + g;
                    int srcIdx = (srcY * imgWidth + srcX) * 4;
                    int dstIdx = (b * lutSize * lutSize + g * lutSize + r) * 4;
                    lutData[dstIdx + 0] = pixels[srcIdx + 0] / 255.0f;
                    lutData[dstIdx + 1] = pixels[srcIdx + 1] / 255.0f;
                    lutData[dstIdx + 2] = pixels[srcIdx + 2] / 255.0f;
                    lutData[dstIdx + 3] = 1.0f;
                }
            }
        }

        free (pixels);

        /* Create 3D texture */
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = MTLPixelFormatRGBA32Float;
        desc.width = lutSize;
        desc.height = lutSize;
        desc.depth = lutSize;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (!texture) {
            free (lutData);
            return nil;
        }

        [texture replaceRegion:MTLRegionMake3D (0, 0, 0, lutSize, lutSize, lutSize)
                   mipmapLevel:0
                         slice:0
                     withBytes:lutData
                   bytesPerRow:lutSize * 4 * sizeof (float)
                 bytesPerImage:lutSize * lutSize * 4 * sizeof (float)];

        free (lutData);
        *outSize = lutSize;

        GST_DEBUG ("Loaded PNG LUT: %dx%dx%d from %s",
                   lutSize, lutSize, lutSize, path);
        return texture;
    }
}

/* --- MetalVideoFilterRenderer implementation --- */

@implementation MetalVideoFilterRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states per input format */
    id<MTLRenderPipelineState> _pipelines[VF_METAL_INPUT_COUNT];

    /* Shared YUV output helper */
    VfMetalYUVOutput *_yuvOutput;

    /* Compute pipelines for blur/sharpen */
    id<MTLComputePipelineState> _computeBlurH;
    id<MTLComputePipelineState> _computeBlurV;
    id<MTLComputePipelineState> _computeUnsharp;

    /* Intermediate textures */
    id<MTLTexture> _renderTarget;       /* RGBA render target for color adjustments */
    id<MTLTexture> _blurTemp;           /* Temporary for horizontal blur pass */
    id<MTLTexture> _blurResult;         /* Result of vertical blur pass */

    /* 3D LUT texture */
    id<MTLTexture> _lutTexture;
    int _lutSize;

    /* Current configuration */
    int _width;
    int _height;
    GstVideoFormat _inputFormat;
    GstVideoFormat _outputFormat;
    MTLPixelFormat _renderPixelFormat;

    /* Input texture cache */
    VfMetalTextureCache *_textureCache;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    VfMetalDevice *metalDevice = [VfMetalDevice sharedDevice];
    if (!metalDevice) {
        GST_ERROR ("MetalVideoFilterRenderer: No Metal device available");
        return nil;
    }

    _commandQueue = [metalDevice.device newCommandQueue];
    if (!_commandQueue) {
        GST_ERROR ("MetalVideoFilterRenderer: Failed to create command queue");
        return nil;
    }

    /* Compile shaders: common + filter-specific */
    NSString *fullSource = [kVfMetalCommonShaderSource
        stringByAppendingString:kVideoFilterShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalVideoFilterRenderer: Failed to compile shaders: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];

    /* Create blur/sharpen compute pipelines */
    id<MTLDevice> device = metalDevice.device;

    id<MTLFunction> blurHFunc = [_library newFunctionWithName:@"blurHorizontal"];
    id<MTLFunction> blurVFunc = [_library newFunctionWithName:@"blurVertical"];
    id<MTLFunction> unsharpFunc = [_library newFunctionWithName:@"unsharpMask"];

    if (blurHFunc) {
        _computeBlurH = [device newComputePipelineStateWithFunction:blurHFunc
                                                              error:&error];
    }
    if (blurVFunc) {
        _computeBlurV = [device newComputePipelineStateWithFunction:blurVFunc
                                                              error:&error];
    }
    if (unsharpFunc) {
        _computeUnsharp = [device newComputePipelineStateWithFunction:unsharpFunc
                                                                error:&error];
    }

    if (!_computeBlurH || !_computeBlurV || !_computeUnsharp) {
        GST_ERROR ("MetalVideoFilterRenderer: Failed to create blur pipelines: %s",
              error.localizedDescription.UTF8String);
        return nil;
    }

    _yuvOutput = [[VfMetalYUVOutput alloc] init];
    _lutSize = 0;

    return self;
}

- (BOOL)configureWithInputInfo:(GstVideoInfo *)inInfo
                    outputInfo:(GstVideoInfo *)outInfo
{
    int width = GST_VIDEO_INFO_WIDTH (inInfo);
    int height = GST_VIDEO_INFO_HEIGHT (inInfo);
    GstVideoFormat inFmt = GST_VIDEO_INFO_FORMAT (inInfo);
    GstVideoFormat outFmt = GST_VIDEO_INFO_FORMAT (outInfo);

    /* Only recreate if config changed */
    if (_renderTarget && _width == width && _height == height &&
        _inputFormat == inFmt && _outputFormat == outFmt) {
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    _width = width;
    _height = height;
    _inputFormat = inFmt;
    _outputFormat = outFmt;

    /* Determine render target pixel format */
    switch (outFmt) {
        case GST_VIDEO_FORMAT_BGRA:
            _renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        case GST_VIDEO_FORMAT_RGBA:
            _renderPixelFormat = MTLPixelFormatRGBA8Unorm;
            break;
        case GST_VIDEO_FORMAT_NV12:
        case GST_VIDEO_FORMAT_I420:
            /* Process in BGRA, then convert to YUV */
            _renderPixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        default:
            GST_ERROR ("Unsupported output format %d", outFmt);
            return NO;
    }

    /* Create render pipeline states for each input format */
    NSString *fragNames[VF_METAL_INPUT_COUNT] = {
        @"filterFragmentRGBA",
        @"filterFragmentNV12",
        @"filterFragmentI420"
    };

    for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
        MTLRenderPipelineDescriptor *desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = [_library newFunctionWithName:@"filterVertex"];
        desc.fragmentFunction = [_library newFunctionWithName:fragNames[fmt]];
        desc.colorAttachments[0].pixelFormat = _renderPixelFormat;
        desc.colorAttachments[0].blendingEnabled = NO;

        NSError *error = nil;
        _pipelines[fmt] =
            [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_pipelines[fmt]) {
            GST_ERROR ("Failed to create filter pipeline for format %d: %s",
                       fmt, error.localizedDescription.UTF8String);
            return NO;
        }
    }

    /* Create render target texture */
    MTLTextureDescriptor *rtDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_renderPixelFormat
                                     width:width
                                    height:height
                                 mipmapped:NO];
    rtDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsageShaderWrite;
    rtDesc.storageMode = MTLStorageModeShared;

    _renderTarget = [device newTextureWithDescriptor:rtDesc];
    if (!_renderTarget) return NO;

    /* Create blur intermediate textures */
    MTLTextureDescriptor *blurDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_renderPixelFormat
                                     width:width
                                    height:height
                                 mipmapped:NO];
    blurDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    blurDesc.storageMode = MTLStorageModeShared;

    _blurTemp = [device newTextureWithDescriptor:blurDesc];
    _blurResult = [device newTextureWithDescriptor:blurDesc];
    if (!_blurTemp || !_blurResult) return NO;

    if (![_yuvOutput configureWithDevice:device library:_library
                                   width:width height:height format:outFmt])
        return NO;

    return YES;
}

- (BOOL)processFrame:(GstVideoFrame *)inFrame
              output:(GstVideoFrame *)outFrame
              params:(const VideoFilterParams *)params
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

        /* === Pass 1: Color adjustment render pass === */

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
            if (_lutTexture) {
                [encoder setFragmentTexture:_lutTexture atIndex:2];
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
            if (_lutTexture) {
                [encoder setFragmentTexture:_lutTexture atIndex:3];
            }
        } else {
            MTLPixelFormat pixFmt = (inFmt == GST_VIDEO_FORMAT_BGRA)
                ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            id<MTLTexture> tex =
                [_textureCache uploadPlane:inFrame plane:0
                          format:pixFmt width:frameW height:frameH];
            if (!tex) { [encoder endEncoding]; return NO; }
            [encoder setFragmentTexture:tex atIndex:0];
            if (_lutTexture) {
                [encoder setFragmentTexture:_lutTexture atIndex:1];
            }
        }

        /* Set filter uniforms */
        FilterUniformsGPU uniforms = {
            .brightness = (float)params->brightness,
            .contrast = (float)params->contrast,
            .saturation = (float)params->saturation,
            .hue = (float)params->hue,
            .gamma = (float)params->gamma,
            .sharpness = (float)params->sharpness,
            .sepia = (float)params->sepia,
            .noise = (float)params->noise,
            .vignette = (float)params->vignette,
            .invert = params->invert,
            .chromaKeyEnabled = params->chromaKeyEnabled,
            .chromaKeyR = (float)params->chromaKeyR,
            .chromaKeyG = (float)params->chromaKeyG,
            .chromaKeyB = (float)params->chromaKeyB,
            .chromaKeyTolerance = (float)params->chromaKeyTolerance,
            .chromaKeySmoothness = (float)params->chromaKeySmoothness,
            .width = (uint32_t)_width,
            .height = (uint32_t)_height,
            .colorMatrix = vf_metal_color_matrix_for_frame (inFrame),
            .frameIndex = params->frameIndex,
            .hasLUT = (_lutTexture != nil) ? 1 : 0,
            .lutSize = _lutSize,
            .padding = 0,
        };

        [encoder setFragmentBytes:&uniforms
                           length:sizeof(uniforms)
                          atIndex:0];

        /* Draw full-screen quad */
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
        [encoder endEncoding];

        /* === Pass 2: Sharpness / blur (only if sharpness != 0) === */

        BOOL needsSharpness = (params->sharpness < -0.001f ||
                               params->sharpness > 0.001f);
        id<MTLTexture> finalTexture = _renderTarget;

        if (needsSharpness) {
            MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
            MTLSize gridSize = MTLSizeMake(
                (_width + 15) / 16, (_height + 15) / 16, 1);

            /* Horizontal blur: renderTarget -> blurTemp */
            id<MTLComputeCommandEncoder> computeH =
                [commandBuffer computeCommandEncoder];
            [computeH setComputePipelineState:_computeBlurH];
            [computeH setTexture:_renderTarget atIndex:0];
            [computeH setTexture:_blurTemp atIndex:1];
            [computeH dispatchThreadgroups:gridSize
                     threadsPerThreadgroup:threadGroupSize];
            [computeH endEncoding];

            /* Vertical blur: blurTemp -> blurResult */
            id<MTLComputeCommandEncoder> computeV =
                [commandBuffer computeCommandEncoder];
            [computeV setComputePipelineState:_computeBlurV];
            [computeV setTexture:_blurTemp atIndex:0];
            [computeV setTexture:_blurResult atIndex:1];
            [computeV dispatchThreadgroups:gridSize
                     threadsPerThreadgroup:threadGroupSize];
            [computeV endEncoding];

            /* Unsharp mask or blur mix: renderTarget + blurResult -> renderTarget
             * We write back to a temp that becomes our final texture.
             * Actually we can reuse blurTemp as output since we're done with it. */
            id<MTLComputeCommandEncoder> computeU =
                [commandBuffer computeCommandEncoder];
            [computeU setComputePipelineState:_computeUnsharp];
            [computeU setTexture:_renderTarget atIndex:0];
            [computeU setTexture:_blurResult atIndex:1];
            [computeU setTexture:_blurTemp atIndex:2];
            float amount = (float)params->sharpness;
            [computeU setBytes:&amount length:sizeof(float) atIndex:0];
            [computeU dispatchThreadgroups:gridSize
                     threadsPerThreadgroup:threadGroupSize];
            [computeU endEncoding];

            finalTexture = _blurTemp;
        }

        /* === Pass 3: Output format conversion (if YUV) === */

        [_yuvOutput dispatchConversion:commandBuffer
                         sourceTexture:finalTexture
                                 width:_width height:_height
                              outFrame:outFrame];

        /* Commit and wait */
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            GST_ERROR ("Metal command buffer failed: %s",
                       commandBuffer.error.localizedDescription.UTF8String);
            return NO;
        }

        /* Read back to GstVideoFrame */
        [_yuvOutput readbackToFrame:outFrame sourceTexture:finalTexture
                              width:_width height:_height];

        return YES;
    }
}

- (BOOL)loadLUTFromFile:(const char *)path
{
    if (!path || *path == '\0') {
        [self clearLUT];
        return YES;
    }

    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;
    int lutSize = 0;
    id<MTLTexture> tex = nil;

    /* Determine format by extension */
    const char *dot = strrchr (path, '.');
    if (dot && strcasecmp (dot, ".cube") == 0) {
        tex = parse_cube_lut (path, device, &lutSize);
    } else if (dot && (strcasecmp (dot, ".png") == 0)) {
        tex = parse_png_lut (path, device, &lutSize);
    } else {
        GST_WARNING ("Unknown LUT file format: %s", path);
        return NO;
    }

    if (!tex) return NO;

    _lutTexture = tex;
    _lutSize = lutSize;
    return YES;
}

- (void)clearLUT
{
    _lutTexture = nil;
    _lutSize = 0;
}

- (void)cleanup
{
    [_textureCache clear];
    _renderTarget = nil;
    _blurTemp = nil;
    _blurResult = nil;
    [_yuvOutput cleanup];
    _lutTexture = nil;
    _lutSize = 0;
    for (int f = 0; f < VF_METAL_INPUT_COUNT; f++)
        _pipelines[f] = nil;
}

@end
