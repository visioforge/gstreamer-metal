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

echo "=== vfmetalvideofilter regression tests ==="
echo ""

# --- 1. Plugin loading ---
echo "[Plugin loading]"
run_test "gst-inspect loads plugin" "${GST_INSPECT}" vfmetalvideofilter

# --- 2. Property verification ---
echo "[Property verification]"
INSPECT_OUTPUT="$("${GST_INSPECT}" vfmetalvideofilter 2>/dev/null)"

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
check_inspect "has brightness property" "brightness"
check_inspect "has contrast property" "contrast"
check_inspect "has saturation property" "saturation"
check_inspect "has hue property" "hue"
check_inspect "has gamma property" "gamma"
check_inspect "has sharpness property" "sharpness"
check_inspect "has sepia property" "sepia"
check_inspect "has invert property" "invert"
check_inspect "has noise property" "noise"
check_inspect "has vignette property" "vignette"
check_inspect "has chroma-key-enabled property" "chroma-key-enabled"
check_inspect "has chroma-key-color property" "chroma-key-color"
check_inspect "has lut-file property" "lut-file"
check_inspect "is GstVideoFilter subclass" "GstVideoFilter"

# --- 3. Passthrough mode (default properties) ---
echo "[Passthrough mode]"
run_pipeline "passthrough BGRA" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter ! fakesink

run_pipeline "passthrough NV12" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalvideofilter ! fakesink

# --- 4. Format tests ---
echo "[Format tests]"
run_pipeline "BGRA processing" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.2 ! fakesink

run_pipeline "RGBA processing" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=RGBA,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.2 ! fakesink

run_pipeline "NV12 processing" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.2 ! fakesink

run_pipeline "I420 processing" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=I420,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.2 ! fakesink

# --- 5. Individual properties ---
echo "[Color adjustments]"
run_pipeline "brightness=0.5" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.5 ! fakesink

run_pipeline "brightness=-0.5" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter brightness=-0.5 ! fakesink

run_pipeline "contrast=1.8" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter contrast=1.8 ! fakesink

run_pipeline "saturation=0 (grayscale)" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter saturation=0 ! fakesink

run_pipeline "hue=0.5" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter hue=0.5 ! fakesink

run_pipeline "gamma=2.2" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter gamma=2.2 ! fakesink

# --- 6. Effects ---
echo "[Effects]"
run_pipeline "sepia=1.0" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter sepia=1.0 ! fakesink

run_pipeline "invert=true" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter invert=true ! fakesink

run_pipeline "noise=0.3" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter noise=0.3 ! fakesink

run_pipeline "vignette=0.8" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter vignette=0.8 ! fakesink

# --- 7. Sharpness / Blur ---
echo "[Sharpness/Blur]"
run_pipeline "sharpen=0.8" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter sharpness=0.8 ! fakesink

run_pipeline "blur=-0.8" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter sharpness=-0.8 ! fakesink

# --- 8. Chroma key ---
echo "[Chroma key]"
run_pipeline "chroma key green" \
    videotestsrc num-buffers=30 pattern=smpte ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter chroma-key-enabled=true chroma-key-color=0xFF00FF00 \
    chroma-key-tolerance=0.3 chroma-key-smoothness=0.1 ! fakesink

# --- 9. Combined effects ---
echo "[Combined effects]"
run_pipeline "brightness+contrast+saturation" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.1 contrast=1.3 saturation=1.5 ! fakesink

run_pipeline "sepia+vignette+noise (film look)" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter sepia=0.7 vignette=0.6 noise=0.15 contrast=1.2 ! fakesink

run_pipeline "all color adjustments combined" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.1 contrast=1.2 saturation=0.8 hue=0.3 gamma=1.5 \
    sharpness=0.5 sepia=0.2 noise=0.1 vignette=0.3 ! fakesink

# --- 10. Resolution tests ---
echo "[Resolution tests]"
run_pipeline "1920x1080 processing" \
    videotestsrc num-buffers=10 ! "video/x-raw,format=BGRA,width=1920,height=1080" ! \
    vfmetalvideofilter brightness=0.2 contrast=1.3 ! fakesink

run_pipeline "160x120 processing" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=160,height=120" ! \
    vfmetalvideofilter saturation=0.5 ! fakesink

# --- 11. NV12/I420 with effects ---
echo "[YUV format effects]"
run_pipeline "NV12 with sepia" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalvideofilter sepia=1.0 ! fakesink

run_pipeline "I420 with brightness+contrast" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=I420,width=320,height=240" ! \
    vfmetalvideofilter brightness=0.3 contrast=1.5 ! fakesink

run_pipeline "NV12 with sharpness" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalvideofilter sharpness=0.5 ! fakesink

# --- Summary ---
echo ""
echo "=== Video filter results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
