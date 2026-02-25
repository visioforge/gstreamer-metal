# gst-vf-metal

Metal-accelerated video processing plugin for GStreamer on macOS and iOS. Provides GPU-powered alternatives to common CPU-bound elements (`videoconvert`, `videoscale`, `compositor`, `deinterlace`, etc.) using Apple's Metal framework with compute shaders, texture caching, and zero-copy passthrough when no processing is needed.

## Features

- **Single-pass processing** - All filter effects (brightness, contrast, hue, chroma key, LUT, etc.) applied in one GPU dispatch
- **Zero-copy passthrough** - Elements automatically skip GPU work when configured at identity/default values
- **Metal texture caching** - `CVMetalTextureCache` eliminates redundant CPU-GPU copies
- **Mixed format compositing** - Compositor accepts heterogeneous input formats (e.g., BGRA + NV12) and resolutions
- **6 supported pixel formats** - BGRA, RGBA, NV12, I420, UYVY, YUY2 (format availability varies per element)

## Elements

| Element | Description | Formats | Reference |
| ------- | ----------- | ------- | --------- |
| [`vfmetalcompositor`](docs/elements/vfmetalcompositor.md) | Multi-input video compositor with per-pad positioning, scaling, alpha, z-order, and blend modes | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetalcompositor.md) |
| [`vfmetalvideosink`](docs/elements/vfmetalvideosink.md) | Video renderer with GstVideoOverlay and GstNavigation support | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetalvideosink.md) |
| [`vfmetalvideofilter`](docs/elements/vfmetalvideofilter.md) | 15-property video effects: color adjustments, chroma key, LUT, sepia, grain, vignette | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetalvideofilter.md) |
| [`vfmetalconvertscale`](docs/elements/vfmetalconvertscale.md) | GPU format conversion + scaling in one pass (replaces `videoconvert` + `videoscale`) | BGRA, RGBA, NV12, I420, UYVY, YUY2 | [docs](docs/elements/vfmetalconvertscale.md) |
| [`vfmetaltransform`](docs/elements/vfmetaltransform.md) | Flip, rotate (8 methods), and crop | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetaltransform.md) |
| [`vfmetaldeinterlace`](docs/elements/vfmetaldeinterlace.md) | Deinterlacing with bob, weave, linear, and greedy-H (motion-adaptive) algorithms | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetaldeinterlace.md) |
| [`vfmetaloverlay`](docs/elements/vfmetaloverlay.md) | PNG/JPEG image overlay with positioning, sizing, and alpha blending | BGRA, RGBA, NV12, I420 | [docs](docs/elements/vfmetaloverlay.md) |

## Supported Formats

| Element | BGRA | RGBA | NV12 | I420 | UYVY | YUY2 |
| ------- | :--: | :--: | :--: | :--: | :--: | :--: |
| vfmetalcompositor | x | x | x | x | | |
| vfmetalvideosink | x | x | x | x | | |
| vfmetalvideofilter | x | x | x | x | | |
| vfmetalconvertscale | x | x | x | x | x | x |
| vfmetaltransform | x | x | x | x | | |
| vfmetaldeinterlace | x | x | x | x | | |
| vfmetaloverlay | x | x | x | x | | |

## Building

### macOS

```bash
./build.sh
```

### macOS with tests

```bash
./build.sh --test
```

### iOS

```bash
./build.sh --platform=ios --gst-root=/path/to/GStreamer/iOS/SDK
```

### Mac Catalyst

```bash
./build.sh --platform=maccatalyst --gst-root=/path/to/GStreamer/iOS/SDK
```

The build produces `build/gstvfmetal.dylib` (macOS) or `build/libgstvfmetal.a` (iOS/Catalyst).

## iOS Static Registration

For iOS apps using a static GStreamer build:

```c
#include "gstvfmetal_static.h"

// After gst_init():
GST_PLUGIN_STATIC_REGISTER(vfmetal);
```

## Quick Examples

**Render test pattern:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! vfmetalvideosink
```

**Convert NV12 to BGRA and downscale:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! \
  vfmetalconvertscale ! video/x-raw,format=BGRA,width=640,height=480 ! fakesink
```

**Apply color adjustments:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetalvideofilter brightness=0.2 contrast=1.3 saturation=1.5 ! autovideosink
```

**Composite two streams:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  vfmetalcompositor name=comp sink_1::xpos=160 sink_1::ypos=120 sink_1::alpha=0.7 ! \
  autovideosink \
  videotestsrc ! video/x-raw,format=BGRA,width=320,height=240 ! comp. \
  videotestsrc pattern=snow ! video/x-raw,format=BGRA,width=320,height=240 ! comp.
```

**Rotate and crop:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaltransform method=clockwise crop-top=20 crop-bottom=20 ! fakesink
```

**Deinterlace with greedy-H:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaldeinterlace method=greedyh motion-threshold=0.3 ! fakesink
```

**Image overlay:**

```bash
GST_PLUGIN_PATH=build gst-launch-1.0 \
  videotestsrc ! video/x-raw,format=BGRA,width=640,height=480 ! \
  vfmetaloverlay location=logo.png relative-x=0.9 relative-y=0.05 alpha=0.8 ! autovideosink
```

## Testing

Run all tests:

```bash
./build.sh --test
```

Run individual test suites:

```bash
GST_PLUGIN_PATH=build ./tests/test-compositor.sh
GST_PLUGIN_PATH=build ./tests/test-videosink.sh
GST_PLUGIN_PATH=build ./tests/test-videofilter.sh
GST_PLUGIN_PATH=build ./tests/test-convertscale.sh
GST_PLUGIN_PATH=build ./tests/test-transform.sh
GST_PLUGIN_PATH=build ./tests/test-deinterlace.sh
GST_PLUGIN_PATH=build ./tests/test-overlay.sh
```

## Requirements

- macOS 13.0+ or iOS 14.0+
- GStreamer 1.20+
- CMake 3.20+
- Metal-capable GPU

## Project Structure

```text
gst-vf-metal/
├── src/
│   ├── common/                     # Shared Metal infrastructure
│   │   ├── vfmetaldevice.h/.m      # Metal device singleton
│   │   ├── vfmetaltextureutil.h/.m  # Texture cache, format helpers
│   │   ├── vfmetalshaders.h/.m     # Shared shader source (YUV matrices, compute kernels)
│   │   └── vfmetalyuvoutput.h/.m   # YUV output conversion
│   ├── compositor/                  # Compositor element
│   ├── videosink/                   # Video sink element
│   ├── videofilter/                 # Video filter element
│   ├── convertscale/                # Convert and scale element
│   ├── transform/                   # Flip/rotate/crop element
│   ├── deinterlace/                 # Deinterlace element
│   ├── overlay/                     # Image overlay element
│   ├── gstvfmetal_static.h          # iOS static plugin registration
│   └── plugin.m                     # GStreamer plugin registration
├── docs/
│   └── elements/                    # Per-element reference documentation
├── tests/                           # Shell-based regression test suites
├── CMakeLists.txt
├── build.sh
├── LICENSE                          # LGPL v2
└── README.md
```

## License

This library is free software; you can redistribute it and/or modify it under the terms of the [GNU Library General Public License, version 2](LICENSE).
