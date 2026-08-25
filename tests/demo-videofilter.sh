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

GST_LAUNCH="${GST_CMD:+${GST_CMD}/}gst-launch-1.0"

export GST_PLUGIN_PATH="${BUILD_DIR}"

# Duration per effect in seconds
DURATION=${1:-3}
WIDTH=640
HEIGHT=480
FPS=30
NUM_BUFFERS=$((DURATION * FPS))

CAPS="video/x-raw,format=BGRA,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1"
SRC="videotestsrc num-buffers=${NUM_BUFFERS} ! ${CAPS}"
SINK="vfmetalvideosink"

if [ ! -f "${PLUGIN}" ]; then
    echo "ERROR: Plugin not found at ${PLUGIN}"
    echo "Run ./build.sh first."
    exit 1
fi

show_effect() {
    local label="$1"
    shift
    echo ">>> ${label}"
    "${GST_LAUNCH}" "$@" 2>/dev/null
    sleep 0.3
}

echo "========================================="
echo "  vfmetalvideofilter - Visual Demo"
echo "  ${DURATION}s per effect (pass duration as arg)"
echo "========================================="
echo ""

# --- Reference ---
echo "[Reference - no filter]"
show_effect "Original (no filter)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! ${SINK}

# --- Brightness ---
echo "[Brightness]"
show_effect "brightness = +0.5" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter brightness=0.5 ! ${SINK}

show_effect "brightness = -0.5" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter brightness=-0.5 ! ${SINK}

# --- Contrast ---
echo "[Contrast]"
show_effect "contrast = 1.8 (high)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter contrast=1.8 ! ${SINK}

show_effect "contrast = 0.3 (low)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter contrast=0.3 ! ${SINK}

# --- Saturation ---
echo "[Saturation]"
show_effect "saturation = 0 (grayscale)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter saturation=0 ! ${SINK}

show_effect "saturation = 2.0 (vivid)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter saturation=2.0 ! ${SINK}

# --- Hue ---
echo "[Hue]"
show_effect "hue = +0.5" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter hue=0.5 ! ${SINK}

show_effect "hue = -0.5" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter hue=-0.5 ! ${SINK}

# --- Gamma ---
echo "[Gamma]"
show_effect "gamma = 2.2 (brighter midtones)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter gamma=2.2 ! ${SINK}

show_effect "gamma = 0.5 (darker midtones)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter gamma=0.5 ! ${SINK}

# --- Sepia ---
echo "[Sepia]"
show_effect "sepia = 1.0 (full sepia)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sepia=1.0 ! ${SINK}

show_effect "sepia = 0.5 (partial sepia)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sepia=0.5 ! ${SINK}

# --- Invert ---
echo "[Invert]"
show_effect "invert = true" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter invert=true ! ${SINK}

# --- Noise ---
echo "[Noise / Film Grain]"
show_effect "noise = 0.3" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter noise=0.3 ! ${SINK}

show_effect "noise = 0.8 (heavy grain)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter noise=0.8 ! ${SINK}

# --- Vignette ---
echo "[Vignette]"
show_effect "vignette = 0.5" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter vignette=0.5 ! ${SINK}

show_effect "vignette = 1.0 (strong)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter vignette=1.0 ! ${SINK}

# --- Sharpness ---
echo "[Sharpness / Blur]"
show_effect "sharpness = 0.8 (sharpen)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sharpness=0.8 ! ${SINK}

show_effect "sharpness = -0.8 (blur)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sharpness=-0.8 ! ${SINK}

# --- Chroma Key ---
echo "[Chroma Key]"
show_effect "chroma key green (SMPTE bars)" \
    videotestsrc num-buffers=${NUM_BUFFERS} pattern=smpte ! "${CAPS}" ! \
    vfmetalvideofilter chroma-key-enabled=true chroma-key-color=0xFF00FF00 \
    chroma-key-tolerance=0.3 chroma-key-smoothness=0.1 ! ${SINK}

# --- Combined Looks ---
echo "[Combined Looks]"
show_effect "Film Look (sepia + vignette + noise + contrast)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sepia=0.7 vignette=0.6 noise=0.15 contrast=1.2 ! ${SINK}

show_effect "Dreamy (blur + brightness + low saturation)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter sharpness=-0.6 brightness=0.15 saturation=0.6 gamma=1.3 ! ${SINK}

show_effect "Noir (grayscale + high contrast + vignette)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter saturation=0 contrast=1.6 brightness=-0.05 vignette=0.7 gamma=0.8 ! ${SINK}

show_effect "Vibrant (saturation + contrast + sharpen)" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter saturation=1.8 contrast=1.3 sharpness=0.5 ! ${SINK}

show_effect "All effects combined" \
    videotestsrc num-buffers=${NUM_BUFFERS} ! "${CAPS}" ! \
    vfmetalvideofilter brightness=0.1 contrast=1.2 saturation=0.8 hue=0.3 gamma=1.5 \
    sharpness=0.5 sepia=0.2 noise=0.1 vignette=0.3 ! ${SINK}

echo ""
echo "========================================="
echo "  Demo complete!"
echo "========================================="
