#!/bin/bash
# Test suite for vfmetalconvertscale element
# Usage: ./test-convertscale.sh [path-to-plugin-dir]

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

echo "=== vfmetalconvertscale test suite ==="
echo ""

# --- Element inspection ---
echo "--- Element inspection ---"
run_test "Element loads" \
    $GST_INSPECT vfmetalconvertscale

# --- Same format passthrough (should be zero-copy) ---
echo "--- Passthrough (same format + size) ---"
for fmt in BGRA RGBA NV12 I420; do
    run_test "Passthrough $fmt 640x480" \
        $GST_LAUNCH videotestsrc num-buffers=10 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetalconvertscale ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            fakesink
done

# --- Format conversion (same size) ---
echo "--- Format conversion (same size 320x240) ---"
FORMATS=(BGRA RGBA NV12 I420)
for src_fmt in "${FORMATS[@]}"; do
    for dst_fmt in "${FORMATS[@]}"; do
        if [ "$src_fmt" != "$dst_fmt" ]; then
            run_test "Convert $src_fmt -> $dst_fmt" \
                $GST_LAUNCH videotestsrc num-buffers=5 ! \
                    "video/x-raw,format=$src_fmt,width=320,height=240" ! \
                    vfmetalconvertscale ! \
                    "video/x-raw,format=$dst_fmt,width=320,height=240" ! \
                    fakesink
        fi
    done
done

# --- Packed YUV conversion ---
echo "--- Packed YUV formats ---"
for packed_fmt in UYVY YUY2; do
    run_test "Convert BGRA -> $packed_fmt" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! \
            vfmetalconvertscale ! \
            "video/x-raw,format=$packed_fmt,width=320,height=240" ! \
            fakesink

    run_test "Convert $packed_fmt -> BGRA" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=$packed_fmt,width=320,height=240" ! \
            vfmetalconvertscale ! \
            "video/x-raw,format=BGRA,width=320,height=240" ! \
            fakesink

    run_test "Convert NV12 -> $packed_fmt" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=NV12,width=320,height=240" ! \
            vfmetalconvertscale ! \
            "video/x-raw,format=$packed_fmt,width=320,height=240" ! \
            fakesink
done

# --- Scaling (same format) ---
echo "--- Scaling (same format, different size) ---"
run_test "Scale BGRA 1920x1080 -> 640x480 (bilinear)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetalconvertscale method=bilinear ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

run_test "Scale BGRA 640x480 -> 1920x1080 (bilinear)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalconvertscale method=bilinear ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        fakesink

run_test "Scale BGRA 1920x1080 -> 640x480 (nearest)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetalconvertscale method=nearest ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

run_test "Scale NV12 1280x720 -> 640x360" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=NV12,width=1280,height=720" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=NV12,width=640,height=360" ! \
        fakesink

run_test "Scale I420 1280x720 -> 320x240" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=I420,width=1280,height=720" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=I420,width=320,height=240" ! \
        fakesink

# --- Combined convert + scale ---
echo "--- Combined convert + scale ---"
run_test "NV12 1920x1080 -> BGRA 640x480" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=NV12,width=1920,height=1080" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

run_test "BGRA 640x480 -> NV12 1920x1080" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=NV12,width=1920,height=1080" ! \
        fakesink

run_test "I420 1280x720 -> RGBA 320x240" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=I420,width=1280,height=720" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=RGBA,width=320,height=240" ! \
        fakesink

run_test "BGRA 320x240 -> I420 1920x1080" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=I420,width=1920,height=1080" ! \
        fakesink

# --- Letterboxing ---
echo "--- Letterboxing ---"
run_test "Letterbox 16:9 -> 4:3 (add-borders=true)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetalconvertscale add-borders=true ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

run_test "Pillarbox 4:3 -> 16:9 (add-borders=true)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetalconvertscale add-borders=true ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        fakesink

run_test "Letterbox with custom border color" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetalconvertscale add-borders=true border-color=0xFF0000FF ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

# --- Odd dimensions ---
echo "--- Edge cases ---"
run_test "Odd dimensions 319x241 -> 641x479" \
    $GST_LAUNCH videotestsrc num-buffers=3 ! \
        "video/x-raw,format=BGRA,width=320,height=240" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=641,height=479" ! \
        fakesink

run_test "Tiny 16x16 -> 1920x1080" \
    $GST_LAUNCH videotestsrc num-buffers=3 ! \
        "video/x-raw,format=BGRA,width=16,height=16" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        fakesink

run_test "1:1 aspect ratio 480x480 -> 640x480" \
    $GST_LAUNCH videotestsrc num-buffers=3 ! \
        "video/x-raw,format=BGRA,width=480,height=480" ! \
        vfmetalconvertscale ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        fakesink

# --- Summary ---
echo ""
echo "=== Results: $PASSED/$TOTAL passed, $FAILED failed ==="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
