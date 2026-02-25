# vfmetaldeinterlace

Metal-accelerated video deinterlacing element supporting bob, weave, linear, and greedy-H (motion-adaptive) algorithms. All processing runs on the GPU via Metal compute shaders.

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |
| src | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Properties

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `method` | Enum | see below | `bob` | Deinterlacing algorithm |
| `field-layout` | Enum | see below | `auto` | Field order (top-first or bottom-first) |
| `motion-threshold` | Double | 0.0 - 1.0 | `0.1` | Motion detection threshold for greedy-H method |

### Method Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `bob` | Bob (field interpolation) |
| 1 | `weave` | Weave (field merge from two frames) |
| 2 | `linear` | Linear (3-tap vertical filter) |
| 3 | `greedyh` | Greedy-H (motion-adaptive) |

### Field Layout Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `auto` | Auto-detect from caps / buffer flags |
| 1 | `top-field-first` | Top field first |
| 2 | `bottom-field-first` | Bottom field first |

## Pipeline Examples

Bob deinterlacing (fastest, lowest quality):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaldeinterlace method=bob ! autovideosink
```

Linear interpolation with NV12:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetaldeinterlace method=linear ! fakesink
```

Greedy-H motion-adaptive with custom threshold:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaldeinterlace method=greedyh motion-threshold=0.3 ! fakesink
```

Explicit field order:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaldeinterlace method=bob field-layout=top-field-first ! fakesink
```

## Notes

- When `field-layout` is `auto`, the element checks `GST_VIDEO_BUFFER_FLAG_TFF` on each buffer
- The `weave` and `greedyh` methods use frame history (previous frame data) for better quality
- `motion-threshold` only affects the `greedyh` method; it is ignored by other algorithms
- Classification: `Filter/Effect/Video/Deinterlace`
- Rank: `GST_RANK_NONE`
