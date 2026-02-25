# vfmetaltransform

Metal-accelerated video transform element providing flip, rotate, and crop operations. When set to identity transform with no crop, operates in passthrough mode (zero-copy).

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |
| src | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Properties

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `method` | Enum | see below | `none` | Video transform method (flip/rotate) |
| `crop-top` | Int | 0 - 2147483647 | `0` | Pixels to crop from the top edge |
| `crop-bottom` | Int | 0 - 2147483647 | `0` | Pixels to crop from the bottom edge |
| `crop-left` | Int | 0 - 2147483647 | `0` | Pixels to crop from the left edge |
| `crop-right` | Int | 0 - 2147483647 | `0` | Pixels to crop from the right edge |

### Method Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `none` | Identity (no rotation) |
| 1 | `clockwise` | Rotate clockwise 90 degrees |
| 2 | `rotate-180` | Rotate 180 degrees |
| 3 | `counterclockwise` | Rotate counter-clockwise 90 degrees |
| 4 | `horizontal-flip` | Flip horizontally |
| 5 | `vertical-flip` | Flip vertically |
| 6 | `upper-left-diagonal` | Flip across upper left / lower right diagonal |
| 7 | `upper-right-diagonal` | Flip across upper right / lower left diagonal |

## Pipeline Examples

Rotate clockwise 90 degrees:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaltransform method=clockwise ! autovideosink
```

Horizontal flip with side cropping:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetaltransform method=horizontal-flip crop-left=100 crop-right=100 ! fakesink
```

Crop all edges equally:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaltransform crop-top=30 crop-bottom=30 crop-left=30 crop-right=30 ! fakesink
```

Combined crop and rotate:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaltransform method=clockwise crop-top=20 crop-bottom=20 ! fakesink
```

1080p rotation with NV12:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetaltransform method=rotate-180 ! fakesink
```

## Notes

- Passthrough mode is automatically enabled when method is `none` and all crop values are 0
- Properties are thread-safe and can be changed during playback
- Crop is applied before the transform operation
- Classification: `Filter/Effect/Video`
- Rank: `GST_RANK_NONE`
