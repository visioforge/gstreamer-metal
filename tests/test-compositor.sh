#!/bin/bash
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

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" > /dev/null 2>&1; then
        echo "  PASS  ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  ${name}"
        FAIL=$((FAIL + 1))
    fi
}

run_pipeline() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "${GST_LAUNCH}" "$@" > /dev/null 2>&1; then
        echo "  PASS  ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  ${name}"
        FAIL=$((FAIL + 1))
    fi
}

# --- Pre-checks ---

if [ ! -f "${PLUGIN}" ]; then
    echo "ERROR: Plugin not found at ${PLUGIN}"
    echo "Run ./build.sh first."
    exit 1
fi

echo "=== vfmetalcompositor regression tests ==="
echo ""

# --- 1. Plugin loading ---
echo "[Plugin loading]"
run_test "gst-inspect loads plugin" "${GST_INSPECT}" vfmetalcompositor

# --- 2. Property/pad verification ---
echo "[Property verification]"
INSPECT_OUTPUT="$("${GST_INSPECT}" vfmetalcompositor 2>/dev/null)"

check_inspect() {
    local label="$1"
    local pattern="$2"
    TOTAL=$((TOTAL + 1))
    if echo "${INSPECT_OUTPUT}" | grep -q "${pattern}"; then
        echo "  PASS  ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  ${label}"
        FAIL=$((FAIL + 1))
    fi
}

check_inspect "has sink pad template" "SINK template"
check_inspect "has src pad template" "SRC template"
check_inspect "has background property" "background"
check_inspect "has xpos property" "xpos"
check_inspect "has alpha property" "alpha"
check_inspect "has operator property" "operator"
check_inspect "has sizing-policy property" "sizing-policy"

# --- 3. Single-input BGRA ---
echo "[Single-input pipelines]"
run_pipeline "BGRA single-input" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalcompositor ! fakesink

# --- 4. Single-input RGBA ---
run_pipeline "RGBA single-input" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=RGBA,width=320,height=240" ! \
    vfmetalcompositor ! fakesink

# --- 5. Two-input with positioning and alpha ---
echo "[Multi-input pipelines]"
run_pipeline "two-input with xpos/ypos/alpha" \
    vfmetalcompositor name=comp sink_0::xpos=0 sink_0::ypos=0 \
        sink_1::xpos=160 sink_1::ypos=120 sink_1::alpha=0.7 ! \
    fakesink \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! comp. \
    videotestsrc num-buffers=30 pattern=snow ! "video/x-raw,format=BGRA,width=320,height=240" ! comp.

# --- 6. Three-input with mixed blend modes ---
run_pipeline "three-input with mixed operators" \
    vfmetalcompositor name=comp \
        sink_0::operator=source \
        sink_1::operator=over sink_1::xpos=50 sink_1::ypos=50 sink_1::alpha=0.8 \
        sink_2::operator=add sink_2::xpos=100 sink_2::ypos=100 sink_2::alpha=0.5 ! \
    fakesink \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! comp. \
    videotestsrc num-buffers=30 pattern=snow ! "video/x-raw,format=BGRA,width=160,height=120" ! comp. \
    videotestsrc num-buffers=30 pattern=smpte ! "video/x-raw,format=BGRA,width=160,height=120" ! comp.

# --- 7. Background modes ---
echo "[Background modes]"
for bg in checker black white transparent; do
    run_pipeline "background=${bg}" \
        videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
        vfmetalcompositor background=${bg} ! fakesink
done

# --- 8. Z-order ---
echo "[Z-order]"
check_inspect "has zorder property" "zorder"

run_pipeline "zorder reordering" \
    vfmetalcompositor name=comp sink_0::zorder=1 sink_1::zorder=0 ! \
    fakesink \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! comp. \
    videotestsrc num-buffers=30 pattern=snow ! "video/x-raw,format=BGRA,width=320,height=240" ! comp.

# --- 9. Sizing policy ---
echo "[Sizing policy]"
run_pipeline "sizing-policy=keep-aspect-ratio" \
    vfmetalcompositor name=comp sink_0::sizing-policy=keep-aspect-ratio \
        sink_0::width=200 sink_0::height=200 ! \
    fakesink \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! comp.

# --- 10. Different output resolutions ---
echo "[Resolution edge cases]"
run_pipeline "1920x1080 output" \
    videotestsrc num-buffers=10 ! "video/x-raw,format=BGRA,width=1920,height=1080" ! \
    vfmetalcompositor ! fakesink

run_pipeline "160x120 output" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=160,height=120" ! \
    vfmetalcompositor ! fakesink

# --- 11. YUV input formats ---
echo "[YUV input formats]"
run_pipeline "NV12 single-input" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalcompositor ! fakesink

run_pipeline "I420 single-input" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=I420,width=320,height=240" ! \
    vfmetalcompositor ! fakesink

# --- 12. Mixed format inputs ---
echo "[Mixed format inputs]"
run_pipeline "BGRA + NV12 two-input" \
    vfmetalcompositor name=comp sink_1::xpos=160 sink_1::ypos=120 ! \
    fakesink \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! comp. \
    videotestsrc num-buffers=30 pattern=snow ! "video/x-raw,format=NV12,width=160,height=120" ! comp.

# --- 13. YUV output formats ---
echo "[YUV output formats]"
run_pipeline "NV12 output" \
    videotestsrc num-buffers=30 ! \
    vfmetalcompositor ! "video/x-raw,format=NV12,width=320,height=240" ! fakesink

run_pipeline "I420 output" \
    videotestsrc num-buffers=30 ! \
    vfmetalcompositor ! "video/x-raw,format=I420,width=320,height=240" ! fakesink

# --- Summary ---
echo ""
echo "=== Compositor results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
