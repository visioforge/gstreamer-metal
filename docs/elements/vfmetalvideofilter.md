# vfmetalvideofilter

Metal-accelerated video filter element providing brightness, contrast, saturation, hue, gamma, sharpness/blur, sepia, invert, film grain, vignette, chroma key, and 3D LUT color grading. All effects are applied in a single GPU pass.

When all properties are at their default values, the element operates in passthrough mode (zero-copy, no GPU work).

## Pad Templates

| Direction | Availability | Caps |
|-----------|-------------|------|
| sink | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |
| src | Always | `video/x-raw, format={ BGRA, RGBA, NV12, I420 }, width=[1,MAX], height=[1,MAX]` |

## Properties

### Color Adjustments

| Name | Type | Range | Default | Description | Controllable |
|------|------|-------|---------|-------------|:---:|
| `brightness` | Double | -1.0 - 1.0 | `0.0` | Brightness adjustment | Yes |
| `contrast` | Double | 0.0 - 2.0 | `1.0` | Contrast adjustment (1.0 = normal) | Yes |
| `saturation` | Double | 0.0 - 2.0 | `1.0` | Color saturation (0.0 = grayscale, 1.0 = normal, 2.0 = oversaturated) | Yes |
| `hue` | Double | -1.0 - 1.0 | `0.0` | Hue rotation (mapped to -180 to +180 degrees) | Yes |
| `gamma` | Double | 0.01 - 10.0 | `1.0` | Gamma correction (1.0 = normal) | Yes |

### Effects

| Name | Type | Range | Default | Description | Controllable |
|------|------|-------|---------|-------------|:---:|
| `sharpness` | Double | -1.0 - 1.0 | `0.0` | Sharpness (-1.0 = maximum blur, 0.0 = none, 1.0 = maximum sharpen) | Yes |
| `sepia` | Double | 0.0 - 1.0 | `0.0` | Sepia tone mix (0.0 = none, 1.0 = full sepia) | Yes |
| `invert` | Boolean | - | `false` | Invert all colors (negative image) | Yes |
| `noise` | Double | 0.0 - 1.0 | `0.0` | Film grain / noise amount (0.0 = none, 1.0 = maximum) | Yes |
| `vignette` | Double | 0.0 - 1.0 | `0.0` | Vignette darkness (0.0 = none, 1.0 = maximum darkening at edges) | Yes |

### Chroma Key

| Name | Type | Range | Default | Description |
|------|------|-------|---------|-------------|
| `chroma-key-enabled` | Boolean | - | `false` | Enable chroma key (green screen) removal |
| `chroma-key-color` | UInt32 | 0 - 4294967295 | `0xFF00FF00` | Chroma key color in ARGB format (default: green) |
| `chroma-key-tolerance` | Double | 0.0 - 1.0 | `0.2` | Color distance threshold for chroma key |
| `chroma-key-smoothness` | Double | 0.0 - 1.0 | `0.1` | Edge softness for chroma key transition |

### Color Grading

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `lut-file` | String | `null` | Path to a .cube or .png 3D LUT file for color grading |

## Pipeline Examples

Adjust brightness and contrast:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter brightness=0.3 contrast=1.5 ! autovideosink
```

Grayscale with sepia tone:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetalvideofilter saturation=0 sepia=1.0 ! fakesink
```

Vintage film look (sepia + vignette + grain):

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter sepia=0.7 vignette=0.6 noise=0.15 contrast=1.2 ! autovideosink
```

Green screen removal:

```bash
gst-launch-1.0 videotestsrc pattern=smpte ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter chroma-key-enabled=true chroma-key-color=0xFF00FF00 \
  chroma-key-tolerance=0.3 chroma-key-smoothness=0.1 ! fakesink
```

All color adjustments combined:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter brightness=0.1 contrast=1.2 saturation=0.8 hue=0.3 gamma=1.5 \
  sharpness=0.5 sepia=0.2 noise=0.1 vignette=0.3 ! fakesink
```

3D LUT color grading:

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter lut-file=/path/to/cinematic.cube ! autovideosink
```

## Notes

- All color adjustment and effect properties are controllable via GstController for animation
- The `hue` property value is mapped internally: a value of 1.0 corresponds to a 180-degree rotation in the hue circle
- Negative `sharpness` values produce a blur effect; positive values sharpen
- The `noise` effect generates animated film grain that varies per-frame
- The 3D LUT supports both `.cube` (Resolve/Adobe) and `.png` (strip) formats
- Setting `lut-file` to null or empty string clears the LUT
- Passthrough is re-evaluated whenever any property changes
- Classification: `Filter/Effect/Video`
- Rank: `GST_RANK_NONE`
