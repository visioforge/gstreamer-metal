# vfmetaloverlay

Metal-accelerated image overlay element. Composites a PNG or JPEG image onto video frames on the GPU. Supports absolute pixel positioning, relative (fractional) positioning, custom sizing, and alpha blending.

When no overlay image is loaded, the element operates in passthrough mode (zero-copy).

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |
| src | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Properties

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `location` | String | - | `null` | Path to overlay image file (PNG or JPEG) |
| `x` | Int | 0 - 2147483647 | `0` | Overlay X position in pixels |
| `y` | Int | 0 - 2147483647 | `0` | Overlay Y position in pixels |
| `width` | Int | 0 - 2147483647 | `0` | Overlay width in pixels (0 = original image width) |
| `height` | Int | 0 - 2147483647 | `0` | Overlay height in pixels (0 = original image height) |
| `alpha` | Double | 0.0 - 1.0 | `1.0` | Overlay opacity (0.0 = transparent, 1.0 = opaque) |
| `relative-x` | Double | -1.0 - 1.0 | `-1.0` | Overlay X position as fraction of video width (-1 = use pixel x) |
| `relative-y` | Double | -1.0 - 1.0 | `-1.0` | Overlay Y position as fraction of video height (-1 = use pixel y) |

### Positioning

The overlay position can be set in two ways:

- **Absolute**: Set `x` and `y` in pixels (used when `relative-x` / `relative-y` are -1.0)
- **Relative**: Set `relative-x` and `relative-y` as fractions of the video dimensions (0.0 = left/top edge, 1.0 = right/bottom edge). When >= 0.0, relative values override the absolute pixel values.

## Pipeline Examples

Basic logo overlay at a fixed position:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaloverlay location=/path/to/logo.png x=10 y=10 ! autovideosink
```

Semi-transparent watermark in the top-right corner:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetaloverlay location=/path/to/watermark.png relative-x=0.9 relative-y=0.05 alpha=0.8 ! \
  autovideosink
```

Overlay with custom size:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaloverlay location=/path/to/image.png width=64 height=64 ! fakesink
```

Centered overlay using relative positioning:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaloverlay location=/path/to/image.png relative-x=0.5 relative-y=0.5 ! fakesink
```

## Notes

- The image is loaded when the `location` property is set; it can be changed at runtime
- Setting `location` to an empty string or null clears the overlay and re-enables passthrough
- If the image file cannot be loaded, a warning is emitted and the element remains in passthrough
- The overlay image is uploaded to a Metal texture once on load; subsequent frames reuse the cached texture
- Classification: `Filter/Effect/Video`
- Rank: `GST_RANK_NONE`
