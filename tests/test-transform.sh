#!/bin/bash
# Test suite for vfmetaltransform element
# Usage: ./test-transform.sh [path-to-plugin-dir]

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

echo "=== vfmetaltransform test suite ==="
echo ""

# --- Element inspection ---
echo "--- Element inspection ---"
run_test "Element loads" \
    $GST_INSPECT vfmetaltransform

# --- Identity passthrough ---
echo "--- Passthrough (identity, no crop) ---"
for fmt in BGRA RGBA NV12 I420; do
    run_test "Passthrough $fmt" \
        $GST_LAUNCH videotestsrc num-buffers=10 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetaltransform method=none ! \
            fakesink
done

# --- Flip/rotate methods ---
echo "--- Flip and rotate methods (BGRA 640x480) ---"
METHODS=(none clockwise rotate-180 counterclockwise horizontal-flip vertical-flip upper-left-diagonal upper-right-diagonal)
for method in "${METHODS[@]}"; do
    run_test "Method: $method" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaltransform method=$method ! \
            fakesink
done

# --- Methods with NV12 ---
echo "--- Flip/rotate with NV12 ---"
for method in clockwise rotate-180 horizontal-flip; do
    run_test "NV12: $method" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=NV12,width=640,height=480" ! \
            vfmetaltransform method=$method ! \
            fakesink
done

# --- Methods with I420 ---
echo "--- Flip/rotate with I420 ---"
for method in counterclockwise vertical-flip upper-left-diagonal; do
    run_test "I420: $method" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=I420,width=640,height=480" ! \
            vfmetaltransform method=$method ! \
            fakesink
done

# --- Cropping ---
echo "--- Cropping ---"
run_test "Crop top=50" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform crop-top=50 ! \
        fakesink

run_test "Crop all sides=30" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform crop-top=30 crop-bottom=30 crop-left=30 crop-right=30 ! \
        fakesink

run_test "Crop left=100 right=100" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=NV12,width=1920,height=1080" ! \
        vfmetaltransform crop-left=100 crop-right=100 ! \
        fakesink

# --- Crop + rotate ---
echo "--- Combined crop + rotate ---"
run_test "Crop + clockwise" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform method=clockwise crop-top=20 crop-bottom=20 ! \
        fakesink

run_test "Crop + horizontal-flip" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaltransform method=horizontal-flip crop-left=50 crop-right=50 ! \
        fakesink

# --- HD content ---
echo "--- HD content ---"
run_test "1080p clockwise" \
    $GST_LAUNCH videotestsrc num-buffers=3 ! \
        "video/x-raw,format=BGRA,width=1920,height=1080" ! \
        vfmetaltransform method=clockwise ! \
        fakesink

run_test "1080p rotate-180 NV12" \
    $GST_LAUNCH videotestsrc num-buffers=3 ! \
        "video/x-raw,format=NV12,width=1920,height=1080" ! \
        vfmetaltransform method=rotate-180 ! \
        fakesink

# --- Summary ---
echo ""
echo "=== Results: $PASSED/$TOTAL passed, $FAILED failed ==="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
