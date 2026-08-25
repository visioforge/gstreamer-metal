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

echo "=== vfmetalvideosink regression tests ==="
echo ""

# --- 1. Plugin loading ---
echo "[Plugin loading]"
run_test "gst-inspect loads plugin" "${GST_INSPECT}" vfmetalvideosink

# --- 2. Property verification ---
echo "[Property verification]"
INSPECT_OUTPUT="$("${GST_INSPECT}" vfmetalvideosink 2>/dev/null)"

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
check_inspect "has force-aspect-ratio property" "force-aspect-ratio"
check_inspect "implements GstVideoOverlay" "GstVideoOverlay"
check_inspect "implements GstNavigation" "GstNavigation"

# --- 3. Single-input BGRA ---
echo "[Single-input pipelines]"
run_pipeline "BGRA rendering" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideosink

# --- 4. Single-input RGBA ---
run_pipeline "RGBA rendering" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=RGBA,width=320,height=240" ! \
    vfmetalvideosink

# --- 5. NV12 input ---
run_pipeline "NV12 rendering" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=NV12,width=320,height=240" ! \
    vfmetalvideosink

# --- 6. I420 input ---
run_pipeline "I420 rendering" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=I420,width=320,height=240" ! \
    vfmetalvideosink

# --- 7. Resolution tests ---
echo "[Resolution tests]"
run_pipeline "1920x1080 rendering" \
    videotestsrc num-buffers=10 ! "video/x-raw,format=BGRA,width=1920,height=1080" ! \
    vfmetalvideosink

run_pipeline "160x120 rendering" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=160,height=120" ! \
    vfmetalvideosink

# --- 8. force-aspect-ratio property ---
echo "[Properties]"
run_pipeline "force-aspect-ratio=false" \
    videotestsrc num-buffers=30 ! "video/x-raw,format=BGRA,width=320,height=240" ! \
    vfmetalvideosink force-aspect-ratio=false

# --- 9. Headless process (issue #878) ---
# gst-launch-1.0 goes through gst_macos_main(), which runs NSApplication on the
# main thread and hides the hang. This one compiles a harness that does not.
echo "[Headless process]"
HEADLESS_SRC="${SCRIPT_DIR}/test-videosink-headless.c"
HEADLESS_BIN="${BUILD_DIR}/test-videosink-headless"
TOTAL=$((TOTAL + 1))
if cc "${HEADLESS_SRC}" -o "${HEADLESS_BIN}" \
        $(pkg-config --cflags --libs gstreamer-1.0) > /dev/null 2>&1; then
    # GST_REGISTRY_FORK=no: the scanner helper is resolved from a path compiled
    # into libgstreamer, which is wrong whenever the SDK was relocated, and the
    # parent then waits on a child that never answers.
    if GST_REGISTRY_FORK=no gtimeout 30 "${HEADLESS_BIN}" > /dev/null 2>&1; then
        echo "  PASS  no main run loop: errors out instead of hanging"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  no main run loop: errors out instead of hanging"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  FAIL  headless harness did not compile"
    FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "=== Video sink results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
