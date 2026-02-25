# vfmetalconvertscale

Metal-accelerated video format conversion and scaling element. Combines the functionality of `videoconvert` + `videoscale` in a single GPU pass. Supports bilinear or nearest-neighbor interpolation and optional letterboxing.

When input and output format and dimensions are identical, the element operates in passthrough mode (zero-copy).

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420, UYVY, YUY2 }, width=[1,MAX], height=[1,MAX]` |
| src | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420, UYVY, YUY2 }, width=[1,MAX], height=[1,MAX]` |

## Properties

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `method` | Enum | see below | `bilinear` | Scaling interpolation method |
| `add-borders` | Boolean | - | `false` | Add letterbox/pillarbox borders to preserve aspect ratio |
| `border-color` | UInt32 | 0 - 4294967295 | `0xFF000000` | Border color in ARGB format (default: opaque black) |

### Method Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `bilinear` | Bilinear interpolation |
| 1 | `nearest` | Nearest-neighbor |

## Pipeline Examples

Format conversion (NV12 to BGRA) with scaling:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetalconvertscale ! video/x-raw,format=BGRA,width=640,height=480 ! autovideosink
```

Downscale with bilinear interpolation:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=1920,height=1080 ! \
  vfmetalconvertscale method=bilinear ! video/x-raw,format=BGRA,width=640,height=480 ! \
  fakesink
```

Nearest-neighbor scaling (pixel-art style):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=1920,height=1080 ! \
  vfmetalconvertscale method=nearest ! video/x-raw,format=BGRA,width=640,height=480 ! \
  fakesink
```

Letterboxing (16:9 to 4:3 with black borders):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=1920,height=1080 ! \
  vfmetalconvertscale add-borders=true ! video/x-raw,format=BGRA,width=640,height=480 ! \
  fakesink
```

Letterboxing with custom border color (blue):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=1920,height=1080 ! \
  vfmetalconvertscale add-borders=true border-color=0xFF0000FF ! \
  video/x-raw,format=BGRA,width=640,height=480 ! fakesink
```

## Notes

- Supports all pairwise conversions between BGRA, RGBA, NV12, I420, UYVY, and YUY2
- Passthrough mode is automatically enabled when input and output have the same format and dimensions
- Caps negotiation preserves display aspect ratio (DAR) when fixating output dimensions
- Properties can be changed at runtime; the renderer reconfigures on the next frame
- Classification: `Filter/Converter/Video/Scaler`
- Rank: `GST_RANK_NONE`
