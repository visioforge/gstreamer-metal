# vfmetalcompositor

Metal-accelerated video compositor that combines multiple video streams into a single output frame. Supports per-pad positioning, scaling, alpha blending, z-ordering, and multiple blend modes. Accepts heterogeneous input formats and resolutions.

Output dimensions default to the bounding box of all positioned inputs. Output framerate matches the fastest input stream.

## Pad Templates

| Direction | Name | Availability | Caps |
|-----------|------|-------------|------|
| src | `src` | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |
| sink | `sink_%u` | Request | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Element Properties

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `background` | Enum | see below | `checker` | Background type |
| `zero-size-is-unscaled` | Boolean | - | `true` | If TRUE, input video is unscaled when width or height is 0 (for backwards compatibility) |
| `ignore-inactive-pads` | Boolean | - | `false` | Avoid timing out waiting for inactive pads |

### Background Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `checker` | Checker pattern |
| 1 | `black` | Black |
| 2 | `white` | White |
| 3 | `transparent` | Transparent background to enable further compositing |

## Pad Properties

Each sink pad (`sink_%u`) exposes these properties, accessible via the GstChildProxy interface (e.g., `sink_0::xpos=100`):

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `xpos` | Int | -2147483648 - 2147483647 | `0` | X position of the picture |
| `ypos` | Int | -2147483648 - 2147483647 | `0` | Y position of the picture |
| `width` | Int | -2147483648 - 2147483647 | `-1` | Width of the picture (-1 = input width) |
| `height` | Int | -2147483648 - 2147483647 | `-1` | Height of the picture (-1 = input height) |
| `alpha` | Double | 0.0 - 1.0 | `1.0` | Alpha of the picture |
| `operator` | Enum | see below | `over` | Blending operator for this pad |
| `sizing-policy` | Enum | see below | `none` | Sizing policy for image scaling |
| `zorder` | UInt | 0 - 4294967295 | `0` | Z-order of the picture in the composition |

### Operator Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `source` | Source (replaces destination) |
| 1 | `over` | Over (standard alpha compositing) |
| 2 | `add` | Add (additive blending) |

### Sizing Policy Values

| Value | Nick | Description |
|-------|------|-------------|
| 0 | `none` | Image is scaled to fill the configured destination rectangle without padding or keeping the aspect ratio |
| 1 | `keep-aspect-ratio` | Image is scaled to fit the destination rectangle with preserved aspect ratio, centered with padding if necessary |

## Interfaces

- **GstChildProxy**: Access per-pad properties using `sink_N::property` syntax

## Pipeline Examples

Two inputs with positioning and alpha:

```bash
gst-launch-1.0 \
  vfmetalcompositor name=comp sink_0::alpha=0.7 sink_1::xpos=160 sink_1::ypos=120 ! \
  videoconvert ! autovideosink \
  videotestsrc pattern=snow ! video/x-raw,format=BGRA,width=320,height=240 ! comp. \
  videotestsrc pattern=smpte ! video/x-raw,format=BGRA,width=320,height=240 ! comp.
```

Three inputs with mixed blend modes:

```bash
gst-launch-1.0 \
  vfmetalcompositor name=comp \
    sink_0::operator=source \
    sink_1::operator=over sink_1::xpos=50 sink_1::ypos=50 sink_1::alpha=0.8 \
    sink_2::operator=add sink_2::xpos=100 sink_2::ypos=100 sink_2::alpha=0.5 ! \
  fakesink \
  videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! comp. \
  videotestsrc pattern=snow ! video/x-raw,format=BGRA,width=160,height=120 ! comp. \
  videotestsrc pattern=smpte ! video/x-raw,format=BGRA,width=160,height=120 ! comp.
```

Black background:

```bash
gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! \
  vfmetalcompositor background=black ! fakesink
```

Mixed input formats (BGRA + NV12):

```bash
gst-launch-1.0 \
  vfmetalcompositor name=comp sink_1::xpos=160 sink_1::ypos=120 ! fakesink \
  videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! comp. \
  videotestsrc pattern=snow ! video/x-raw,format=NV12,width=160,height=120 ! comp.
```

Keep aspect ratio with explicit pad size:

```bash
gst-launch-1.0 \
  vfmetalcompositor name=comp \
    sink_0::sizing-policy=keep-aspect-ratio sink_0::width=200 sink_0::height=200 ! \
  fakesink \
  videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! comp.
```

## Notes

- Each input stream can have a different format and resolution; the compositor converts all inputs internally
- Pads with `alpha=0.0` are skipped entirely (no GPU work)
- Obscured frames (fully covered by a higher z-order opaque pad) are also skipped
- The compositor renders internally to BGRA and converts to the negotiated output format; output can be NV12, I420, etc.
- Navigation events are forwarded to the correct sink pad based on pointer coordinates and pad geometry
- All pad properties are controllable and can be animated via GstController
- Classification: `Filter/Editor/Video/Compositor`
- Rank: `GST_RANK_PRIMARY + 2`
