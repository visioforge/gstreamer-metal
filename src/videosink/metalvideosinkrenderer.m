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

#import "metalvideosinkrenderer.h"
#import "vfmetaldevice.h"
#import "vfmetaltextureutil.h"
#import "vfmetalshaders.h"

#include <gst/gst.h>
#include <gst/video/video.h>

#if !TARGET_OS_IPHONE
#import <AppKit/AppKit.h>
#endif

GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_video_sink_debug);
#define GST_CAT_DEFAULT gst_vf_metal_video_sink_debug

/* --- Videosink-specific Metal shader source --- */

static NSString *const kVideoSinkShaderSource = @R"(

// Fullscreen quad vertex shader for video sink
vertex VertexOut videosinkVertex(
    uint vid [[vertex_id]],
    constant float4 *vertexData [[buffer(0)]]
) {
    VertexOut out;
    float4 vd = vertexData[vid];
    out.position = float4(vd.xy, 0.0, 1.0);
    out.texcoord = vd.zw;
    return out;
}

// Fragment shader: BGRA/RGBA texture (single plane)
fragment float4 videosinkFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texcoord);
}

// Fragment shader: NV12 input (Y + interleaved UV)
fragment float4 videosinkFragmentNV12(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// Fragment shader: I420 input (Y + separate U + separate V)
fragment float4 videosinkFragmentI420(
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
    return float4(rgb, 1.0);
}
)";

/* ============================================================= */
/*                      VfMetalView (macOS)                       */
/* ============================================================= */

#if !TARGET_OS_IPHONE

@class MetalVideoSinkRenderer;

@interface VfMetalView : NSView
@property (nonatomic, weak) MetalVideoSinkRenderer *renderer;
@end

@implementation VfMetalView

- (CALayer *)makeBackingLayer
{
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = [VfMetalDevice sharedDevice].device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    return layer;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy =
            NSViewLayerContentsRedrawDuringViewResize;
    }
    return self;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)isOpaque
{
    return YES;
}

@end

#endif /* !TARGET_OS_IPHONE */

/* ============================================================= */
/*               MetalVideoSinkRenderer implementation            */
/* ============================================================= */

@implementation MetalVideoSinkRenderer {
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    /* Render pipeline states per input format (no blend mode variants) */
    id<MTLRenderPipelineState> _pipelines[VF_METAL_INPUT_COUNT];

    /* Input texture cache (reused from common/) */
    VfMetalTextureCache *_textureCache;

    /* Video info */
    int _videoWidth;
    int _videoHeight;
    GstVideoFormat _videoFormat;
    VfMetalInputFormat _inputFormatIndex;

#if !TARGET_OS_IPHONE
    /* Window/layer management (macOS) */
    NSWindow *_internalWindow;
    VfMetalView *_renderView;
#endif
    CAMetalLayer *_metalLayer;

    /* Display geometry */
    BOOL _forceAspectRatio;
    BOOL _haveRenderRect;
    GstVideoRectangle _renderRect;
    GstVideoRectangle _displayRect;

    /* Thread safety: protects _windowReady, _metalLayer access across threads */
    NSLock *_renderLock;

    /* Cached view properties (updated on main thread only, read under lock) */
    CGSize _cachedDrawableSize;
    CGFloat _cachedContentsScale;

    /* State */
    BOOL _windowReady;
    BOOL _configured;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    VfMetalDevice *metalDevice = [VfMetalDevice sharedDevice];
    if (!metalDevice) {
        GST_ERROR ("MetalVideoSinkRenderer: No Metal device available");
        return nil;
    }

    _commandQueue = [metalDevice.device newCommandQueue];
    if (!_commandQueue) {
        GST_ERROR ("MetalVideoSinkRenderer: Failed to create command queue");
        return nil;
    }

    /* Compile shaders: concatenate common + videosink-specific source */
    NSString *fullSource = [kVfMetalCommonShaderSource
        stringByAppendingString:kVideoSinkShaderSource];

    NSError *error = nil;
    _library = [metalDevice compileShaderSource:fullSource error:&error];
    if (!_library) {
        GST_ERROR ("MetalVideoSinkRenderer: Failed to compile shaders: %s",
                   error.localizedDescription.UTF8String);
        return nil;
    }

    _textureCache = [[VfMetalTextureCache alloc]
        initWithDevice:metalDevice.device];

    _renderLock = [[NSLock alloc] init];
    _forceAspectRatio = YES;
    _windowReady = NO;
    _configured = NO;
    _cachedDrawableSize = CGSizeZero;
    _cachedContentsScale = 1.0;

    return self;
}

/* --- Pipeline creation --- */

- (id<MTLRenderPipelineState>)createPipelineWithFragmentFunction:(NSString *)fragName
{
    id<MTLDevice> device = [VfMetalDevice sharedDevice].device;

    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [_library newFunctionWithName:@"videosinkVertex"];
    desc.fragmentFunction = [_library newFunctionWithName:fragName];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = NO;

    NSError *error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) {
        GST_ERROR ("MetalVideoSinkRenderer: Pipeline creation failed for %s: %s",
                   fragName.UTF8String, error.localizedDescription.UTF8String);
    }
    return state;
}

/* --- Configuration --- */

- (BOOL)configureWithVideoInfo:(GstVideoInfo *)info
{
    int width = GST_VIDEO_INFO_WIDTH (info);
    int height = GST_VIDEO_INFO_HEIGHT (info);
    GstVideoFormat format = GST_VIDEO_INFO_FORMAT (info);

    /* Skip if nothing changed */
    if (_configured && _videoWidth == width && _videoHeight == height &&
        _videoFormat == format) {
        return YES;
    }

    _videoWidth = width;
    _videoHeight = height;
    _videoFormat = format;
    _inputFormatIndex = vf_metal_input_format_index (format);

    /* Create pipelines if not yet created (they don't depend on resolution) */
    if (!_pipelines[0]) {
        NSString *fragNames[VF_METAL_INPUT_COUNT] = {
            @"videosinkFragment",
            @"videosinkFragmentNV12",
            @"videosinkFragmentI420"
        };

        for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
            _pipelines[fmt] =
                [self createPipelineWithFragmentFunction:fragNames[fmt]];
            if (!_pipelines[fmt]) {
                GST_ERROR ("MetalVideoSinkRenderer: Failed to create pipeline for format %d",
                           fmt);
                return NO;
            }
        }
    }

    _configured = YES;

    GST_DEBUG ("MetalVideoSinkRenderer: configured %dx%d format=%d",
               width, height, format);

    return YES;
}

/* --- Window management --- */

- (void)ensureWindowWithHandle:(guintptr)handle
                         width:(int)width
                        height:(int)height
{
    if (_windowReady)
        return;

#if !TARGET_OS_IPHONE
    void (^createBlock)(void) = ^{
        if (handle != 0) {
            /* External mode: embed in provided NSView */
            NSView *parentView = (__bridge NSView *)(void *)handle;
            self->_renderView =
                [[VfMetalView alloc] initWithFrame:parentView.bounds];
            self->_renderView.renderer = self;
            self->_renderView.autoresizingMask =
                NSViewWidthSizable | NSViewHeightSizable;
            [parentView addSubview:self->_renderView];
        } else {
            /* Internal mode: create NSWindow */
            [NSApplication sharedApplication];

            NSRect frame = NSMakeRect(100, 100, width, height);
            self->_internalWindow = [[NSWindow alloc]
                initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskMiniaturizable
                            backing:NSBackingStoreBuffered
                              defer:NO];
            self->_internalWindow.title = @"VF Metal Video Sink";
            self->_internalWindow.releasedWhenClosed = NO;

            self->_renderView =
                [[VfMetalView alloc]
                    initWithFrame:self->_internalWindow.contentView.bounds];
            self->_renderView.renderer = self;
            self->_renderView.autoresizingMask =
                NSViewWidthSizable | NSViewHeightSizable;
            [self->_internalWindow.contentView addSubview:self->_renderView];
            [self->_internalWindow makeKeyAndOrderFront:nil];

            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }

        self->_metalLayer = (CAMetalLayer *)self->_renderView.layer;

        /* Cache view properties for thread-safe access from renderFrame.
         * These must only be read/written from the main thread. */
        CGFloat scale = self->_renderView.window.backingScaleFactor;
        if (scale <= 0) scale = 1.0;
        self->_cachedContentsScale = scale;
        self->_metalLayer.contentsScale = scale;

        CGSize boundsSize = self->_renderView.bounds.size;
        self->_cachedDrawableSize = CGSizeMake(
            boundsSize.width * scale, boundsSize.height * scale);
        self->_metalLayer.drawableSize = self->_cachedDrawableSize;
    };

    if ([NSThread isMainThread]) {
        createBlock();
    } else {
        /* All AppKit operations must happen on the main thread.
         * Use dispatch_sync to ensure the window is ready before returning. */
        dispatch_sync (dispatch_get_main_queue (), createBlock);
    }
#endif /* !TARGET_OS_IPHONE */

    [_renderLock lock];
    _windowReady = YES;
    [_renderLock unlock];
}

- (void)closeWindow
{
    /* Mark as not ready first (under lock) to prevent new renders */
    [_renderLock lock];
    if (!_windowReady) {
        [_renderLock unlock];
        return;
    }
    _windowReady = NO;
    _metalLayer = nil;  /* Nil under lock so renderFrame can't grab it */
    [_renderLock unlock];

#if !TARGET_OS_IPHONE
    void (^closeBlock)(void) = ^{
        /* Suppress window transition animations to prevent autoreleased
         * _NSWindowTransformAnimation objects from outliving the window. */
        if (self->_internalWindow) {
            [self->_internalWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
        }

        /* Drain animation objects inside this pool while the window
         * hierarchy is still alive, so their dealloc can't hit freed memory. */
        @autoreleasepool {
            if (self->_internalWindow) {
                [self->_internalWindow orderOut:nil];
            }

            if (self->_renderView) {
                [self->_renderView.layer removeAllAnimations];
                [self->_renderView removeFromSuperview];
            }
        }

        /* Now safe to release — all autoreleased animation objects are gone */
        self->_renderView = nil;

        if (self->_internalWindow) {
            [self->_internalWindow close];
            self->_internalWindow = nil;
        }
    };

    if ([NSThread isMainThread]) {
        closeBlock();
    } else {
        dispatch_sync (dispatch_get_main_queue (), closeBlock);
    }
#endif /* !TARGET_OS_IPHONE */
}

/* --- Display rectangle calculation --- */

- (GstVideoRectangle)computeDisplayRect
{
    GstVideoRectangle result;
    CGFloat viewW, viewH;

    if (_haveRenderRect) {
        viewW = _renderRect.w;
        viewH = _renderRect.h;
    } else if (_cachedDrawableSize.width > 0 && _cachedDrawableSize.height > 0) {
        viewW = _cachedDrawableSize.width;
        viewH = _cachedDrawableSize.height;
    } else {
        viewW = _videoWidth;
        viewH = _videoHeight;
    }

    if (_forceAspectRatio && _videoWidth > 0 && _videoHeight > 0) {
        GstVideoRectangle src, dst;
        src.x = src.y = 0;
        src.w = _videoWidth;
        src.h = _videoHeight;

        dst.x = dst.y = 0;
        dst.w = (gint)viewW;
        dst.h = (gint)viewH;

        gst_video_center_rect (&src, &dst, &result, TRUE);
    } else {
        result.x = 0;
        result.y = 0;
        result.w = (gint)viewW;
        result.h = (gint)viewH;
    }

    _displayRect = result;
    return result;
}

/* --- Rendering --- */

- (BOOL)renderFrame:(GstVideoFrame *)frame
{
    [_renderLock lock];
    if (!_windowReady || !_metalLayer || !_configured) {
        [_renderLock unlock];
        return NO;
    }

    /* Grab local references under lock so closeWindow can't nil them mid-render */
    CAMetalLayer *metalLayer = _metalLayer;
    CGSize drawableSize = _cachedDrawableSize;
    [_renderLock unlock];

    if (drawableSize.width <= 0 || drawableSize.height <= 0)
        return NO;

    @autoreleasepool {
        [_textureCache resetFrameIndex];

        GstVideoFormat fmt = GST_VIDEO_FRAME_FORMAT (frame);
        VfMetalInputFormat fmtIdx = vf_metal_input_format_index (fmt);
        int frameW = GST_VIDEO_FRAME_WIDTH (frame);
        int frameH = GST_VIDEO_FRAME_HEIGHT (frame);

        /* Upload textures based on input format */
        id<MTLTexture> textures[3] = { nil, nil, nil };
        int textureCount = 0;

        if (fmtIdx == VF_METAL_INPUT_NV12) {
            textures[0] = [_textureCache uploadPlane:frame plane:0
                                              format:MTLPixelFormatR8Unorm
                                               width:frameW height:frameH];
            textures[1] = [_textureCache uploadPlane:frame plane:1
                                              format:MTLPixelFormatRG8Unorm
                                               width:(frameW + 1) / 2
                                              height:(frameH + 1) / 2];
            textureCount = 2;
            if (!textures[0] || !textures[1]) return NO;
        } else if (fmtIdx == VF_METAL_INPUT_I420) {
            textures[0] = [_textureCache uploadPlane:frame plane:0
                                              format:MTLPixelFormatR8Unorm
                                               width:frameW height:frameH];
            textures[1] = [_textureCache uploadPlane:frame plane:1
                                              format:MTLPixelFormatR8Unorm
                                               width:(frameW + 1) / 2
                                              height:(frameH + 1) / 2];
            textures[2] = [_textureCache uploadPlane:frame plane:2
                                              format:MTLPixelFormatR8Unorm
                                               width:(frameW + 1) / 2
                                              height:(frameH + 1) / 2];
            textureCount = 3;
            if (!textures[0] || !textures[1] || !textures[2]) return NO;
        } else {
            /* BGRA / RGBA: single plane */
            MTLPixelFormat pixFmt = (fmt == GST_VIDEO_FORMAT_BGRA)
                ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            textures[0] = [_textureCache uploadPlane:frame plane:0
                                              format:pixFmt
                                               width:frameW height:frameH];
            textureCount = 1;
            if (!textures[0]) return NO;
        }

        /* Use cached drawable size (updated on main thread via updateDrawableSize) */
        float drawW = (float)drawableSize.width;
        float drawH = (float)drawableSize.height;

        /* Get drawable from the layer */
        id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
        if (!drawable) {
            GST_WARNING ("MetalVideoSinkRenderer: no drawable available");
            return NO;
        }

        /* Compute display rectangle for aspect ratio */
        GstVideoRectangle displayRect = [self computeDisplayRect];

        /* Map display rect to NDC coordinates [-1, 1] */
        float x = (2.0f * displayRect.x / drawW) - 1.0f;
        float y = 1.0f - (2.0f * displayRect.y / drawH);
        float w = 2.0f * displayRect.w / drawW;
        float h = 2.0f * displayRect.h / drawH;

        float vertices[] = {
            x,     y,       0.0f, 0.0f,
            x + w, y,       1.0f, 0.0f,
            x,     y - h,   0.0f, 1.0f,
            x + w, y - h,   1.0f, 1.0f,
        };

        /* Create command buffer */
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            GST_ERROR ("Failed to create Metal command buffer");
            return NO;
        }

        /* Set up render pass with black clear (letterboxing) */
        MTLRenderPassDescriptor *rpDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpDesc.colorAttachments[0].texture = drawable.texture;
        rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:rpDesc];
        if (!encoder) return NO;

        /* Set viewport to full drawable size */
        MTLViewport viewport = {
            0, 0,
            (double)drawW, (double)drawH,
            0.0, 1.0
        };
        [encoder setViewport:viewport];

        /* Set pipeline for current input format */
        [encoder setRenderPipelineState:_pipelines[fmtIdx]];

        /* Set vertex data */
        [encoder setVertexBytes:vertices
                         length:sizeof(vertices)
                        atIndex:0];

        /* Set fragment textures */
        for (int i = 0; i < textureCount; i++) {
            [encoder setFragmentTexture:textures[i] atIndex:i];
        }

        /* Set uniforms for YUV formats (needed for colorMatrix) */
        if (fmtIdx != VF_METAL_INPUT_RGBA) {
            VfMetalUniforms uniforms;
            uniforms.alpha = 1.0f;
            uniforms.colorMatrix = vf_metal_color_matrix_for_frame (frame);
            uniforms.padding[0] = 0;
            uniforms.padding[1] = 0;

            [encoder setFragmentBytes:&uniforms
                               length:sizeof(uniforms)
                              atIndex:0];
        }

        /* Draw quad */
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];

        [encoder endEncoding];

        /* Present drawable and commit — no waitUntilCompleted needed.
         * GPU runs async; CAMetalLayer handles presentation timing. */
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        return YES;
    }
}

- (void)updateDrawableSize
{
#if !TARGET_OS_IPHONE
    if (!_renderView)
        return;

    void (^updateBlock)(void) = ^{
        CGSize boundsSize = self->_renderView.bounds.size;
        CGFloat scale = self->_renderView.window.backingScaleFactor;
        if (scale <= 0) scale = 1.0;

        CGSize newSize = CGSizeMake(
            boundsSize.width * scale, boundsSize.height * scale);

        if (newSize.width > 0 && newSize.height > 0) {
            self->_metalLayer.drawableSize = newSize;
            self->_metalLayer.contentsScale = scale;

            [self->_renderLock lock];
            self->_cachedDrawableSize = newSize;
            self->_cachedContentsScale = scale;
            [self->_renderLock unlock];
        }
    };

    if ([NSThread isMainThread]) {
        updateBlock();
    } else {
        dispatch_async (dispatch_get_main_queue (), updateBlock);
    }
#endif
}

- (void)expose
{
    /* Request a redraw. For now this is a no-op since we don't cache
     * the last frame. The element can re-render via gst_base_sink_get_last_sample()
     * if needed in the future. */
}

/* --- Properties --- */

- (void)setForceAspectRatio:(BOOL)force
{
    _forceAspectRatio = force;
}

- (void)setRenderRectangleX:(gint)x y:(gint)y
                      width:(gint)width height:(gint)height
{
    _haveRenderRect = YES;
    _renderRect.x = x;
    _renderRect.y = y;
    _renderRect.w = width;
    _renderRect.h = height;
}

- (void)setHandleEvents:(BOOL)handle
{
    /* Currently no-op; event handling is always enabled when
     * the view is first responder */
}

/* --- Navigation --- */

- (void)transformNavigationX:(gdouble)x y:(gdouble)y
                    toVideoX:(gdouble *)vx videoY:(gdouble *)vy
{
    if (_displayRect.w > 0 && _displayRect.h > 0 &&
        _videoWidth > 0 && _videoHeight > 0) {
        *vx = (x - _displayRect.x) *
              (gdouble)_videoWidth / (gdouble)_displayRect.w;
        *vy = (y - _displayRect.y) *
              (gdouble)_videoHeight / (gdouble)_displayRect.h;
    } else {
        *vx = x;
        *vy = y;
    }
}

/* --- Lifecycle --- */

- (void)cleanup
{
    [self closeWindow];
    [_textureCache clear];

    for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
        _pipelines[fmt] = nil;
    }

    _configured = NO;
}

@end
