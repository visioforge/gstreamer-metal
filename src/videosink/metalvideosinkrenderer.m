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

/* How long teardown is willing to wait for the main queue. */
#define VF_METAL_MAIN_QUEUE_TIMEOUT_SECONDS 5.0

/* --- Bounded main-queue hop --- */

/* AppKit work must happen on the main thread, but nothing here may block on the
 * main queue without a bound: a process whose main thread runs no Cocoa run
 * loop -- a test host, a console tool, a background service -- never services
 * that queue, and a dispatch_sync onto it waits forever.
 *
 * The streaming thread does not use this at all: see ensureWindowWithHandle:,
 * which dispatches and returns. Teardown does, because it has to know whether
 * the window is gone before the Metal objects behind it are released.
 *
 * Returns YES if the block ran within the bound. */
static BOOL
vf_metal_run_on_main_bounded (void (^block) (void))
{
    if ([NSThread isMainThread]) {
        block ();
        return YES;
    }

    dispatch_semaphore_t done = dispatch_semaphore_create (0);

    dispatch_async (dispatch_get_main_queue (), ^{
        block ();
        dispatch_semaphore_signal (done);
    });

    return dispatch_semaphore_wait (done, dispatch_time (DISPATCH_TIME_NOW,
                (int64_t) (VF_METAL_MAIN_QUEUE_TIMEOUT_SECONDS * NSEC_PER_SEC)))
        == 0;
}

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

/* Destroys a window and view the caller already owns -- it takes no lock and
 * touches no ivar, so both the teardown path and a create block that lost its
 * race can call it without one thread being able to see half a window. Main
 * thread only. */
static void
vf_metal_destroy_window (NSWindow *window, VfMetalView *view)
{
    /* Suppress window transition animations to prevent autoreleased
     * _NSWindowTransformAnimation objects from outliving the window. */
    [window setAnimationBehavior:NSWindowAnimationBehaviorNone];

    /* Drain animation objects inside this pool while the window hierarchy is
     * still alive, so their dealloc can't hit freed memory. */
    @autoreleasepool {
        [window orderOut:nil];

        [view.layer removeAllAnimations];
        [view removeFromSuperview];
    }

    [window close];
}

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

    /* Serialises renderFrame: against itself. Rendering normally happens on one
     * streaming thread, but the frame held below is drawn from the main thread
     * when the window finally appears, and the texture cache is not reentrant.
     * Held for the whole of a render, which includes [layer nextDrawable] and
     * can therefore take a frame interval or more. */
    NSLock *_frameLock;

    /* Guards the held frame and _renderedAny only, and is never held across a
     * render -- otherwise the streaming thread's per-frame holdFrame/discard
     * would queue behind a main-thread redraw sitting in nextDrawable. */
    NSLock *_heldLock;

    /* The most recent frame that arrived before there was a window to draw it
     * in, kept so it can be drawn as soon as there is one. Without it a pipeline
     * that prerolls and stays in PAUSED -- a paused preview, a scrub, a
     * thumbnail -- shows an empty window: its one frame was dropped and nothing
     * ever asks for it again. */
    GstBuffer *_heldFrame;
    GstVideoInfo _heldFrameInfo;

    /* Whether any frame has reached the screen since the last set_caps. Kept
     * here rather than in the element because the held frame is drawn from the
     * main thread, where the element's own streaming-thread flag never sees it.
     *
     * Cleared by closeWindow, which the element calls only after it has asked:
     * without that a second clip with identical caps inherits the first one's
     * answer -- configureWithVideoInfo: returns early when nothing changed --
     * and both the warning and the test assertion built on it become one-shot
     * per element. */
    BOOL _renderedAny;

    /* Cached view properties (updated on main thread only, read under lock) */
    CGSize _cachedDrawableSize;
    CGFloat _cachedContentsScale;

    /* State */
    BOOL _windowReady;
    BOOL _windowPending;
    BOOL _configured;

    /* Which handle the queued block is building for, and which the live window
     * belongs to. Without these an ensureWindowWithHandle: for a NEW handle
     * would see _windowPending and defer to a block still building the OLD
     * one -- and the sink would keep drawing into the view the application
     * just moved away from. */
    guintptr _pendingHandle;
    guintptr _attachedHandle;

    /* Bumped under _renderLock on every window transition. A block dispatched
     * to the main queue captures the value it was dispatched with and does
     * nothing if it no longer matches, so a queue that is only serviced much
     * later cannot create a window for an element that has since been torn
     * down, nor close one that has since been recreated. */
    NSUInteger _windowEpoch;
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
    _frameLock = [[NSLock alloc] init];
    _heldLock = [[NSLock alloc] init];

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
    BOOL ok;

    /* Skip if nothing changed */
    if (_configured && _videoWidth == width && _videoHeight == height &&
        _videoFormat == format) {
        return YES;
    }

    /* Under _frameLock for the whole mutation. These fields used to be written
     * and read on one thread -- set_caps and rendering are both the streaming
     * thread -- but the held frame and expose now draw from the main thread, and
     * a caps change landing mid-draw would lay an old picture out against the
     * new dimensions. Taking the render lock here means no draw is in flight. */
    [_frameLock lock];
    ok = [self configureLocked:info width:width height:height format:format];
    [_frameLock unlock];

    return ok;
}

- (BOOL)configureLocked:(GstVideoInfo *)info
                  width:(int)width
                 height:(int)height
                 format:(GstVideoFormat)format
{
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

    /* The held frame belongs to the caps that are being replaced: drawing it
     * later would letterbox an old picture against the new dimensions. */
    [_heldLock lock];
    gst_buffer_replace (&_heldFrame, NULL);
    _renderedAny = NO;
    [_heldLock unlock];

    GST_DEBUG ("MetalVideoSinkRenderer: configured %dx%d format=%d",
               width, height, format);

    return YES;
}

/* --- Window management --- */

/* Never blocks.  The streaming thread calls this once per frame; it returns NO
 * until the window exists, and the caller drops the frame and tries again.
 * Waiting here is what wedged headless processes, and it deadlocks an AppKit
 * host too: a main thread sitting in gst_element_get_state() while the sink
 * prerolls is the very thread that has to build the window.  Dispatching and
 * returning lets preroll finish, which releases that thread, which then runs
 * the block. */
- (BOOL)ensureWindowWithHandle:(guintptr)handle
                         width:(int)width
                        height:(int)height
{
    return [self ensureWindowWithHandle:handle width:width height:height
                          authoritative:NO];
}

- (BOOL)ensureWindowWithHandle:(guintptr)handle
                         width:(int)width
                        height:(int)height
                 authoritative:(BOOL)authoritative
{
    [_renderLock lock];
    if (_windowReady && _attachedHandle == handle) {
        [_renderLock unlock];
        return YES;
    }
    if (_windowPending
        && (_pendingHandle == handle || !authoritative)) {
        /* Already queued. A second block would add a second view to the same
         * parent and orphan the first.
         *
         * Also when the queued handle is a DIFFERENT one and this call is not
         * authoritative: only set_window_handle knows what the application
         * asked for last. show_frame reaches here with a handle it read a
         * moment ago, and letting that retire a block queued by a newer
         * set_window_handle would bind the sink to the view the application
         * just moved away from -- with no further buffer to correct it if the
         * pipeline is sitting in PAUSED. */
        [_renderLock unlock];
        return NO;
    }
    /* Either nothing is queued, or what is queued is for a handle that is no
     * longer the one wanted -- bumping the epoch retires it. */
    _windowPending = YES;
    _pendingHandle = handle;
    NSUInteger epoch = ++_windowEpoch;
    [_renderLock unlock];

#if !TARGET_OS_IPHONE
    __weak MetalVideoSinkRenderer *weakSelf = self;

    /* The window is built into locals with no lock held, and every ivar is then
     * assigned in one locked step at the end.  Holding the lock across AppKit
     * would be the safer-looking shape and is the more dangerous one: it is not
     * recursive, and anything AppKit does that drains the main queue would
     * deadlock the main thread against itself -- the exact failure this element
     * is being fixed for. */
    void (^createBlock)(void) = ^{
        /* Weak: in a process that never drains its main queue this block is
         * never run and never released, and a strong reference would keep a
         * whole renderer -- Metal device, texture cache, pipeline states --
         * alive for the life of the process, once per PLAYING cycle. */
        MetalVideoSinkRenderer *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        [strongSelf->_renderLock lock];
        if (strongSelf->_windowEpoch != epoch) {
            /* Retired. _windowPending is not cleared here: it belongs to
             * whatever superseded this block, and clearing it would make the
             * next frame queue a redundant third one. */
            [strongSelf->_renderLock unlock];
            return;
        }
        [strongSelf->_renderLock unlock];

        NSWindow *window = nil;
        VfMetalView *view = nil;

        if (handle != 0) {
            /* External mode: embed in provided NSView */
            NSView *parentView = (__bridge NSView *)(void *)handle;
            view = [[VfMetalView alloc] initWithFrame:parentView.bounds];
            view.renderer = strongSelf;
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [parentView addSubview:view];
        } else {
            /* Internal mode: create NSWindow */
            [NSApplication sharedApplication];

            NSRect frame = NSMakeRect(100, 100, width, height);
            window = [[NSWindow alloc]
                initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskMiniaturizable
                            backing:NSBackingStoreBuffered
                              defer:NO];
            window.title = @"VF Metal Video Sink";
            window.releasedWhenClosed = NO;

            view = [[VfMetalView alloc]
                initWithFrame:window.contentView.bounds];
            view.renderer = strongSelf;
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [window.contentView addSubview:view];
            /* Deliberately not ordered front yet, and the activation policy not
             * touched: a closeWindow landing between the two epoch checks would
             * otherwise leave a window flashing on screen and a headless process
             * permanently promoted to a regular app -- dock icon and menu bar --
             * which destroying the window does not undo. Both happen after the
             * second check, once this block knows it is still the live one. */
        }

        CAMetalLayer *layer = (CAMetalLayer *)view.layer;

        CGFloat scale = view.window.backingScaleFactor;
        if (scale <= 0) scale = 1.0;
        layer.contentsScale = scale;

        CGSize boundsSize = view.bounds.size;
        CGSize drawableSize = CGSizeMake(
            boundsSize.width * scale, boundsSize.height * scale);
        layer.drawableSize = drawableSize;

        [strongSelf->_renderLock lock];
        if (strongSelf->_windowEpoch != epoch) {
            /* Torn down while this was building. Nothing was published, so this
             * block still owns what it made and has to undo it. _windowPending
             * is left to whatever superseded it. */
            [strongSelf->_renderLock unlock];
            vf_metal_destroy_window (window, view);
            return;
        }

        /* Whatever is being replaced goes out here. show_frame reaches this
         * method with a handle the application thread may have just changed, so
         * a live window for the previous handle can still be standing -- and an
         * internal NSWindow was ordered front with releasedWhenClosed = NO, so
         * simply overwriting the ivar strands it on screen for good. */
        NSWindow *outgoingWindow = strongSelf->_internalWindow;
        VfMetalView *outgoingView = strongSelf->_renderView;

        strongSelf->_internalWindow = window;
        strongSelf->_renderView = view;
        strongSelf->_metalLayer = layer;
        strongSelf->_cachedContentsScale = scale;
        strongSelf->_cachedDrawableSize = drawableSize;

        /* Published at the point the window actually exists: "there is a
         * window" and "_windowReady" are one fact. */
        strongSelf->_windowReady = YES;
        strongSelf->_windowPending = NO;
        strongSelf->_attachedHandle = handle;
        [strongSelf->_renderLock unlock];

        if (outgoingWindow || outgoingView)
            vf_metal_destroy_window (outgoingWindow, outgoingView);

        /* Only now: this block is the live one, so showing the window and
         * promoting the process cannot be left behind by a teardown. */
        if (handle == 0) {
            [window makeKeyAndOrderFront:nil];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }

        /* Draw whatever arrived while there was nowhere to draw it. */
        [strongSelf drawHeldFrame];
    };

    if ([NSThread isMainThread])
        createBlock ();
    else
        dispatch_async (dispatch_get_main_queue (), createBlock);
#else
    [_renderLock lock];
    _windowReady = YES;
    _windowPending = NO;
    _attachedHandle = handle;
    [_renderLock unlock];
#endif /* !TARGET_OS_IPHONE */

    [_renderLock lock];
    BOOL ready = (_windowReady && _attachedHandle == handle);
    [_renderLock unlock];
    return ready;
}

- (void)closeWindow
{
    [_renderLock lock];
    /* Bump the epoch even when there is no window yet: a createBlock may be
     * sitting unrun in the main queue, and this is what makes it retire instead
     * of building a window for an element already torn down. It only retires
     * the block; showing the window and promoting the process happen after the
     * block's second epoch check, so that they cannot be left behind. */
    ++_windowEpoch;
    _windowReady = NO;
    _windowPending = NO;
    _attachedHandle = 0;
    _pendingHandle = 0;
    _cachedDrawableSize = CGSizeZero;
    _metalLayer = nil;
#if !TARGET_OS_IPHONE
    /* Taken out of the ivars here rather than read from them inside the block:
     * the block then owns what it destroys, so it needs no staleness check and
     * cannot tear down a window that was recreated behind it. */
    NSWindow *window = _internalWindow;
    VfMetalView *view = _renderView;
    _internalWindow = nil;
    _renderView = nil;
#endif
    [_renderLock unlock];

    /* A window that goes takes "something was displayed" with it: the next one
     * starts having shown nothing. Under _heldLock, which owns this field, and
     * safe here because the element asks before it closes. */
    [_heldLock lock];
    _renderedAny = NO;
    [_heldLock unlock];

#if !TARGET_OS_IPHONE
    if (!window && !view)
        return;

    if (!vf_metal_run_on_main_bounded (^{
                vf_metal_destroy_window (window, view);
            })) {
        GST_WARNING ("MetalVideoSinkRenderer: the main queue was not serviced "
                     "within %g s; leaving the window to be closed by the run "
                     "loop rather than blocking teardown.",
                     VF_METAL_MAIN_QUEUE_TIMEOUT_SECONDS);
    }
#endif /* !TARGET_OS_IPHONE */
}

/* --- Display rectangle calculation --- */

/* Takes the drawable size rather than reading _cachedDrawableSize: renderFrame
 * snapshots that under the lock and divides by the snapshot to reach NDC, so
 * reading the ivar again here would let a resize land in between and compute
 * the rectangle against one size and the projection against another -- a frame
 * offset or stretched for as long as the resize lasts. */
- (GstVideoRectangle)computeDisplayRectForDrawableSize:(CGSize)drawableSize
                                            renderRect:(GstVideoRectangle)renderRect
                                        haveRenderRect:(BOOL)haveRenderRect
{
    GstVideoRectangle result;
    CGFloat viewW, viewH;

    if (haveRenderRect) {
        viewW = renderRect.w;
        viewH = renderRect.h;
    } else if (drawableSize.width > 0 && drawableSize.height > 0) {
        viewW = drawableSize.width;
        viewH = drawableSize.height;
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

    [_renderLock lock];
    _displayRect = result;
    [_renderLock unlock];

    return result;
}

/* --- Rendering --- */

- (BOOL)renderFrame:(GstVideoFrame *)frame
{
    [_frameLock lock];
    BOOL ok = [self renderFrameLocked:frame];
    [_frameLock unlock];
    return ok;
}

/* Callers hold _frameLock. */
- (BOOL)renderFrameLocked:(GstVideoFrame *)frame
{
    BOOL ok = [self renderFrameUnsafe:frame];
    if (ok) {
        [_heldLock lock];
        _renderedAny = YES;
        [_heldLock unlock];
    }
    return ok;
}

- (BOOL)renderFrameUnsafe:(GstVideoFrame *)frame
{
    [_renderLock lock];
    if (!_windowReady || !_metalLayer || !_configured) {
        [_renderLock unlock];
        return NO;
    }

    /* Grab local references under lock so closeWindow can't nil them mid-render */
    CAMetalLayer *metalLayer = _metalLayer;
    CGSize drawableSize = _cachedDrawableSize;
    BOOL haveRenderRect = _haveRenderRect;
    GstVideoRectangle renderRect = _renderRect;
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

        /* Compute display rectangle for aspect ratio, from the same snapshot
         * drawW/drawH came from. */
        GstVideoRectangle displayRect =
            [self computeDisplayRectForDrawableSize:drawableSize
                                         renderRect:renderRect
                                     haveRenderRect:haveRenderRect];

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
    /* Called from the streaming thread, while closeWindow nils these two on the
     * main thread. Assigning a strong ivar releases what it held, so reading
     * one unlocked from another thread can hand back a pointer that is freed a
     * moment later. Take strong local references under the lock and let the
     * block work from those. */
    [_renderLock lock];
    BOOL haveWindow = (_renderView != nil && _metalLayer != nil);
    [_renderLock unlock];

    if (!haveWindow)
        return;

    /* Weak, and nothing else captured: this is dispatched once per frame, so a
     * main thread stuck in a modal loop queues hundreds of these. Capturing the
     * view or the layer as locals would keep them alive past closeWindow and
     * past the element's finalize just as surely as capturing self would, so the
     * block re-reads both under the lock instead. */
    __weak MetalVideoSinkRenderer *weakSelf = self;

    void (^updateBlock)(void) = ^{
        MetalVideoSinkRenderer *self = weakSelf;
        if (!self)
            return;

        [self->_renderLock lock];
        VfMetalView *view = self->_renderView;
        CAMetalLayer *layer = self->_metalLayer;
        [self->_renderLock unlock];

        if (!view || !layer)
            return;

        CGSize boundsSize = view.bounds.size;
        CGFloat scale = view.window.backingScaleFactor;
        if (scale <= 0) scale = 1.0;

        CGSize newSize = CGSizeMake(
            boundsSize.width * scale, boundsSize.height * scale);

        if (newSize.width > 0 && newSize.height > 0) {
            layer.drawableSize = newSize;
            layer.contentsScale = scale;

            [self->_renderLock lock];
            /* Only if this is still the layer being rendered into: the window
             * may have been closed or replaced while this block was queued. */
            if (self->_metalLayer == layer) {
                self->_cachedDrawableSize = newSize;
                self->_cachedContentsScale = scale;
            }
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

- (void)holdFrame:(GstBuffer *)buffer info:(GstVideoInfo *)info
{
    [_heldLock lock];
    gst_buffer_replace (&_heldFrame, buffer);
    _heldFrameInfo = *info;
    [_heldLock unlock];
}

- (void)drawHeldFrame
{
    [self drawHeldFrameRetrying:YES];
}

- (void)drawHeldFrameRetrying:(BOOL)allowRetry
{
    GstVideoFrame frame;
    GstBuffer *buffer;
    GstVideoInfo info;
    BOOL drawn = NO;

    /* tryLock, not lock: this runs on the main thread, and the streaming thread
     * holds _frameLock for the whole of a render including [layer nextDrawable],
     * which blocks when the drawable pool is empty. If a real frame is being
     * drawn right now there is nothing for a redraw to add anyway.
     *
     * Taken FIRST, before the held frame is read: _frameLock is what keeps a
     * caps change out, and reading the buffer before taking it would let
     * configureWithVideoInfo: swap the dimensions underneath -- the old picture
     * would then be laid out against the new ones. */
    if (![_frameLock tryLock])
        return;

    /* Kept rather than consumed: the held frame is whatever is on screen, so
     * expose can redraw it whenever the host view is resized. discardHeldFrame
     * releases it -- on a caps change and at teardown. */
    [_heldLock lock];
    buffer = _heldFrame ? gst_buffer_ref (_heldFrame) : NULL;
    info = _heldFrameInfo;
    [_heldLock unlock];

    if (buffer) {
        if (gst_video_frame_map (&frame, &info, buffer, GST_MAP_READ)) {
            drawn = [self renderFrameLocked:&frame];
            gst_video_frame_unmap (&frame);
        }
        gst_buffer_unref (buffer);
    }

    [_frameLock unlock];

    if (!buffer)
        return;

    /* nextDrawable can transiently return nil on a layer that has only just been
     * created. For a pipeline that prerolls and stays in PAUSED this is the only
     * draw there will ever be, and losing it leaves a black window and a
     * teardown warning blaming a window that did exist. One retry, next turn. */
    if (!drawn && allowRetry) {
        __weak MetalVideoSinkRenderer *weakSelf = self;
        dispatch_async (dispatch_get_main_queue (), ^{
            [weakSelf drawHeldFrameRetrying:NO];
        });
    }
}

- (BOOL)hasRenderedFrame
{
    [_heldLock lock];
    BOOL rendered = _renderedAny;
    [_heldLock unlock];
    return rendered;
}

- (BOOL)isAttachedToHandle:(guintptr)handle
{
    [_renderLock lock];
    BOOL attached = (_windowReady && _attachedHandle == handle);
    [_renderLock unlock];
    return attached;
}

- (void)discardHeldFrame
{
    [_heldLock lock];
    gst_buffer_replace (&_heldFrame, NULL);
    [_heldLock unlock];
}

- (void)expose
{
    /* The held frame is the one on screen, so this is a genuine redraw. */
    [self drawHeldFrame];
}

/* --- Properties --- */

- (void)setForceAspectRatio:(BOOL)force
{
    _forceAspectRatio = force;
}

- (void)setRenderRectangleX:(gint)x y:(gint)y
                      width:(gint)width height:(gint)height
{
    /* Written from the application thread and read while a frame is being laid
     * out, so it goes under the same lock as the drawable size -- otherwise a
     * frame can be positioned against half of the old rectangle and half of the
     * new one. */
    [_renderLock lock];
    _haveRenderRect = YES;
    _renderRect.x = x;
    _renderRect.y = y;
    _renderRect.w = width;
    _renderRect.h = height;
    [_renderLock unlock];
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
    /* Snapshotted: this runs on the application thread while the rectangle is
     * being written by whichever thread last laid a frame out, and a mouse
     * event landing mid-write would be transformed against a mixed rectangle. */
    [_renderLock lock];
    GstVideoRectangle rect = _displayRect;
    [_renderLock unlock];

    if (rect.w > 0 && rect.h > 0 && _videoWidth > 0 && _videoHeight > 0) {
        *vx = (x - rect.x) * (gdouble)_videoWidth / (gdouble)rect.w;
        *vy = (y - rect.y) * (gdouble)_videoHeight / (gdouble)rect.h;
    } else {
        *vx = x;
        *vy = y;
    }
}

/* --- Lifecycle --- */

- (void)cleanup
{
    [self closeWindow];
    [self discardHeldFrame];
    [_textureCache clear];

    for (int fmt = 0; fmt < VF_METAL_INPUT_COUNT; fmt++) {
        _pipelines[fmt] = nil;
    }

    _configured = NO;
}

@end
