# vfmetalvideosink

Metal-accelerated video sink element that renders video frames using Apple's Metal framework. Supports BGRA, RGBA, NV12, and I420 input formats with GPU-accelerated YUV-to-RGB conversion.

When no external window handle is set via the GstVideoOverlay interface, the element creates its own NSWindow on first frame.

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Properties

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `force-aspect-ratio` | Boolean | `true` | When enabled, scaling will respect original aspect ratio |
| `enable-navigation-events` | Boolean | `true` | When enabled, navigation events are forwarded upstream |

## Interfaces

### GstVideoOverlay

Allows embedding the video output in an application-provided window. Methods:

- **set_window_handle**: Assign an `NSView` handle for rendering
- **expose**: Force a redraw of the current frame
- **set_render_rectangle**: Define a sub-region within the view for rendering
- **handle_events**: Enable or disable mouse/keyboard event handling

### GstNavigation

Forwards mouse and keyboard events upstream with coordinates transformed from view space to video space. This enables interactive overlays and click-to-seek behavior in applications.

## Pipeline Examples

Basic rendering with BGRA input:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideosink
```

NV12 input (YUV-to-RGB conversion on GPU):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetalvideosink
```

Disable aspect ratio preservation:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! \
  vfmetalvideosink force-aspect-ratio=false
```

## Notes

- The element creates a Metal device singleton shared across all vfmetal elements
- When the pipeline transitions to PAUSED->READY, the window is closed
- Buffer pool proposal includes `GstVideoMeta` support for efficient memory layout negotiation
- Classification: `Sink/Video`
- Rank: `GST_RANK_MARGINAL`
