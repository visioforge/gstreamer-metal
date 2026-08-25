#!/bin/bash
# Test suite for multi-element pipelines (chaining multiple vfmetal elements)
# Validates that per-element command queues work correctly when elements
# are used together in the same pipeline.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"
PLUGIN="${BUILD_DIR}/gstvfmetal.dylib"

# Find GStreamer commands
if [ -d "/Library/Frameworks/GStreamer.framework/Commands" ]; then
    GST_CMD="/Library/Frameworks/GStreamer.framework/Commands"
else
    GST_CMD=""
fi

GST_INSPECT="${GST_CMD:+${GST_CMD}/}gst-inspect-1.0"
GST_LAUNCH="${GST_CMD:+${GST_CMD}/}gst-launch-1.0"

export GST_PLUGIN_PATH="${BUILD_DIR}"

PASSED=0
FAILED=0
TOTAL=0

run_test() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    printf "  [%02d] %-60s " "$TOTAL" "$name"
    if "$@" > /dev/null 2>&1; then
        echo "PASS"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Multi-element pipeline tests ==="
echo ""

# --- Two-element chains ---
echo "--- Two-element chains ---"

run_test "videofilter ! convertscale (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalvideofilter brightness=0.2 contrast=1.3 ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

run_test "videofilter ! transform (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalvideofilter saturation=0.5 ! \
        vfmetaltransform method=clockwise ! \
        fakesink

run_test "deinterlace ! videofilter (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=bob ! \
        vfmetalvideofilter sepia=0.8 ! \
        fakesink

run_test "transform ! convertscale (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform method=horizontal-flip ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

run_test "convertscale ! videofilter (NV12)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=NV12,width=640,height=480" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=NV12,width=320,height=240" ! \
        vfmetalvideofilter brightness=0.1 ! \
        fakesink

# --- Three-element chains ---
echo "--- Three-element chains ---"

run_test "deinterlace ! videofilter ! convertscale (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=linear ! \
        vfmetalvideofilter contrast=1.5 gamma=1.2 ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

run_test "transform ! videofilter ! convertscale (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform method=rotate-180 ! \
        vfmetalvideofilter invert=true ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

run_test "videofilter ! transform ! convertscale (BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalvideofilter brightness=-0.2 saturation=1.5 ! \
        vfmetaltransform method=vertical-flip ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=1280,height=720" ! \
        fakesink

# --- Chains with compositor ---
echo "--- Chains with compositor ---"

run_test "videofilter ! compositor (two inputs)" \
    $GST_LAUNCH \
        videotestsrc num-buffers=10 ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! \
            vfmetalvideofilter brightness=0.3 ! \
            comp.sink_0 \
        videotestsrc num-buffers=10 pattern=snow ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! \
            vfmetalvideofilter sepia=1.0 ! \
            comp.sink_1 \
        vfmetalcompositor name=comp \
            sink_0::xpos=0 sink_0::ypos=0 \
            sink_1::xpos=320 sink_1::ypos=0 ! \
        "video/x-raw,width=640,height=240" ! \
        fakesink

run_test "compositor ! videofilter (post-process)" \
    $GST_LAUNCH \
        videotestsrc num-buffers=10 ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! comp.sink_0 \
        videotestsrc num-buffers=10 pattern=ball ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! comp.sink_1 \
        vfmetalcompositor name=comp \
            sink_1::xpos=160 sink_1::ypos=120 sink_1::alpha=0.7 ! \
        vfmetalvideofilter contrast=1.4 vignette=0.5 ! \
        fakesink

run_test "compositor ! convertscale (downscale)" \
    $GST_LAUNCH \
        videotestsrc num-buffers=10 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! comp.sink_0 \
        videotestsrc num-buffers=10 pattern=snow ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! comp.sink_1 \
        vfmetalcompositor name=comp \
            sink_1::xpos=320 sink_1::ypos=240 ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

# --- YUV multi-element chains ---
echo "--- YUV multi-element chains ---"

run_test "videofilter ! convertscale (NV12 -> BGRA)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=NV12,width=640,height=480" ! \
        vfmetalvideofilter brightness=0.1 ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

run_test "convertscale ! videofilter (BGRA -> NV12 -> filter)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=NV12,width=320,height=240" ! \
        vfmetalvideofilter contrast=1.2 ! \
        fakesink

run_test "deinterlace ! convertscale (NV12 scale)" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=NV12,width=640,height=480" ! \
        vfmetaldeinterlace method=bob ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=NV12,width=320,height=240" ! \
        fakesink

# --- Four-element chain (stress test) ---
echo "--- Four-element chain ---"

run_test "deinterlace ! videofilter ! transform ! convertscale" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=bob ! \
        vfmetalvideofilter brightness=0.1 contrast=1.2 ! \
        vfmetaltransform method=horizontal-flip ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        fakesink

# --- Summary ---
echo ""
echo "=== Multi-element results: ${PASSED}/${TOTAL} passed, ${FAILED} failed ==="

if [ ${FAILED} -gt 0 ]; then
    exit 1
fi
exit 0
