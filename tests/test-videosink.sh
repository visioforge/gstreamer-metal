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

# A pipeline that exits 0 is not a pipeline that drew anything: an unrendered
# frame is GST_FLOW_OK by necessity (see the note on GST_BASE_SINK_FLOW_DROPPED
# in gstvfmetalvideosink.m), so gst-launch would exit 0 either way. The element
# says on the bus at teardown when nothing ever reached the screen, which is
# what turns these back into rendering assertions.
run_pipeline() {
    local name="$1"
    shift
    local out
    TOTAL=$((TOTAL + 1))
    out="$("${GST_LAUNCH}" "$@" 2>&1)"
    if [ $? -ne 0 ]; then
        echo "  FAIL  ${name}"
        FAIL=$((FAIL + 1))
    elif echo "${out}" | grep -q "No video frame was ever displayed"; then
        echo "  FAIL  ${name} (pipeline ran but nothing was rendered)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS  ${name}"
        PASS=$((PASS + 1))
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

# Same GStreamer discovery build.sh does: the framework if it is installed,
# otherwise whatever PKG_CONFIG_PATH the caller set. Without this the harness
# does not compile and the failure is indistinguishable from a real one.
if [ -d "/Library/Frameworks/GStreamer.framework" ]; then
    export PKG_CONFIG_PATH="/Library/Frameworks/GStreamer.framework/Libraries/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

if ! command -v gtimeout > /dev/null 2>&1; then
    echo "  FAIL  headless test needs gtimeout (brew install coreutils)"
    FAIL=$((FAIL + 1))
elif ! pkg-config --exists gstreamer-1.0; then
    echo "  FAIL  headless test needs pkg-config to find gstreamer-1.0;"
    echo "        set PKG_CONFIG_PATH the way you set it for ./build.sh"
    FAIL=$((FAIL + 1))
elif ! cc "${HEADLESS_SRC}" -o "${HEADLESS_BIN}" \
        $(pkg-config --cflags --libs gstreamer-1.0) > /dev/null 2>&1; then
    echo "  FAIL  headless harness did not compile"
    FAIL=$((FAIL + 1))
else
    # GST_REGISTRY_FORK=no: the scanner helper is resolved from a path compiled
    # into libgstreamer, which is wrong whenever the SDK was relocated, and the
    # parent then waits on a child that never answers.
    HEADLESS_OUT="$(GST_REGISTRY_FORK=no gtimeout 75 "${HEADLESS_BIN}" 2>&1)"
    if [ $? -eq 0 ]; then
        echo "  PASS  no main run loop: errors out instead of hanging"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  no main run loop: errors out instead of hanging"
        echo "${HEADLESS_OUT}" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
fi

# --- Summary ---
echo ""
echo "=== Video sink results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
