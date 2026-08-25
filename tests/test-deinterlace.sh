#!/bin/bash
# Test suite for vfmetaldeinterlace element
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

echo "=== vfmetaldeinterlace test suite ==="
echo ""

# --- Element inspection ---
echo "--- Element inspection ---"
run_test "Element loads" \
    $GST_INSPECT vfmetaldeinterlace

# --- Bob method (all formats) ---
echo "--- Bob method ---"
for fmt in BGRA RGBA NV12 I420; do
    run_test "Bob $fmt 640x480" \
        $GST_LAUNCH videotestsrc num-buffers=10 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetaldeinterlace method=bob ! \
            fakesink
done

# --- Linear method ---
echo "--- Linear method ---"
for fmt in BGRA NV12 I420; do
    run_test "Linear $fmt 640x480" \
        $GST_LAUNCH videotestsrc num-buffers=10 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetaldeinterlace method=linear ! \
            fakesink
done

# --- Weave method (needs history) ---
echo "--- Weave method ---"
for fmt in BGRA NV12; do
    run_test "Weave $fmt 640x480 (30 frames)" \
        $GST_LAUNCH videotestsrc num-buffers=30 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetaldeinterlace method=weave ! \
            fakesink
done

# --- GreedyH method ---
echo "--- GreedyH method ---"
run_test "GreedyH BGRA 640x480" \
    $GST_LAUNCH videotestsrc num-buffers=30 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=greedyh ! \
        fakesink

run_test "GreedyH NV12 640x480" \
    $GST_LAUNCH videotestsrc num-buffers=30 ! \
        "video/x-raw,format=NV12,width=640,height=480" ! \
        vfmetaldeinterlace method=greedyh ! \
        fakesink

run_test "GreedyH custom threshold" \
    $GST_LAUNCH videotestsrc num-buffers=30 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=greedyh motion-threshold=0.3 ! \
        fakesink

# --- Field layout ---
echo "--- Field layout ---"
run_test "Top-field-first" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=bob field-layout=top-field-first ! \
        fakesink

run_test "Bottom-field-first" \
    $GST_LAUNCH videotestsrc num-buffers=10 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaldeinterlace method=bob field-layout=bottom-field-first ! \
        fakesink

# --- HD content ---
echo "--- HD content ---"
run_test "Bob 1080p BGRA" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetaldeinterlace method=bob ! \
        fakesink

run_test "Linear 1080p NV12" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=NV12,width=1920,height=1080" ! \
        vfmetaldeinterlace method=linear ! \
        fakesink

# --- Summary ---
echo ""
echo "=== Results: $PASSED/$TOTAL passed, $FAILED failed ==="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
