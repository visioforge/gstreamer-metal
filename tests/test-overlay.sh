#!/bin/bash
# Test suite for vfmetaloverlay element
# Usage: ./test-overlay.sh [path-to-plugin-dir]

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

# Create a small test PNG via GStreamer (32x32 red square)
TEST_IMG="/tmp/vfmetal_test_overlay.png"
$GST_LAUNCH videotestsrc num-buffers=1 pattern=red ! \
    "video/x-raw,format=BGRA,width=32,height=32" ! \
    videoconvert ! pngenc ! filesink location="$TEST_IMG" > /dev/null 2>&1 || true

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

echo "=== vfmetaloverlay test suite ==="
echo ""

# --- Element inspection ---
echo "--- Element inspection ---"
run_test "Element loads" \
    $GST_INSPECT vfmetaloverlay

# --- Passthrough (no overlay) ---
echo "--- Passthrough (no overlay loaded) ---"
for fmt in BGRA RGBA NV12 I420; do
    run_test "Passthrough $fmt" \
        $GST_LAUNCH videotestsrc num-buffers=10 ! \
            "video/x-raw,format=$fmt,width=640,height=480" ! \
            vfmetaloverlay ! \
            fakesink
done

# --- Graceful handling of missing file ---
echo "--- Error handling ---"
run_test "Missing file (graceful)" \
    $GST_LAUNCH videotestsrc num-buffers=5 ! \
        "video/x-raw,format=BGRA,width=640,height=480" ! \
        vfmetaloverlay location=/nonexistent/path.png ! \
        fakesink

# --- Overlay with test image ---
if [ -f "$TEST_IMG" ]; then
    echo "--- Overlay compositing ---"
    for fmt in BGRA RGBA NV12 I420; do
        run_test "Overlay $fmt default pos" \
            $GST_LAUNCH videotestsrc num-buffers=10 ! \
                "video/x-raw,format=$fmt,width=640,height=480" ! \
                vfmetaloverlay location="$TEST_IMG" ! \
                fakesink
    done

    echo "--- Position and size ---"
    run_test "Overlay at x=100 y=50" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaloverlay location="$TEST_IMG" x=100 y=50 ! \
            fakesink

    run_test "Overlay with custom size" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaloverlay location="$TEST_IMG" width=64 height=64 ! \
            fakesink

    run_test "Overlay relative position" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaloverlay location="$TEST_IMG" relative-x=0.5 relative-y=0.5 ! \
            fakesink

    echo "--- Alpha blending ---"
    run_test "Alpha=0.5" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaloverlay location="$TEST_IMG" alpha=0.5 ! \
            fakesink

    run_test "Alpha=0.0 (fully transparent)" \
        $GST_LAUNCH videotestsrc num-buffers=5 ! \
            "video/x-raw,format=BGRA,width=640,height=480" ! \
            vfmetaloverlay location="$TEST_IMG" alpha=0.0 ! \
            fakesink

    echo "--- HD content ---"
    run_test "1080p BGRA overlay" \
        $GST_LAUNCH videotestsrc num-buffers=3 ! \
            "video/x-raw,format=BGRA,width=1920,height=1080" ! \
            vfmetaloverlay location="$TEST_IMG" x=100 y=100 ! \
            fakesink

    run_test "1080p NV12 overlay" \
        $GST_LAUNCH videotestsrc num-buffers=3 ! \
            "video/x-raw,format=NV12,width=1920,height=1080" ! \
            vfmetaloverlay location="$TEST_IMG" relative-x=0.9 relative-y=0.05 ! \
            fakesink
else
    echo "--- Skipping overlay tests (could not generate test image) ---"
fi

# Cleanup
rm -f "$TEST_IMG"

# --- Summary ---
echo ""
echo "=== Results: $PASSED/$TOTAL passed, $FAILED failed ==="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
