#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
BUILD_TYPE="Release"
RUN_TESTS=0
PLATFORM="macos"
GSTREAMER_ROOT_IOS=""

for arg in "$@"; do
    case "$arg" in
        --test|-t) RUN_TESTS=1 ;;
        --platform=*) PLATFORM="${arg#--platform=}" ;;
        --gst-root=*) GSTREAMER_ROOT_IOS="${arg#--gst-root=}" ;;
        Debug|Release) BUILD_TYPE="$arg" ;;
    esac
done

if [ "$PLATFORM" = "ios" ]; then
    # ==================== iOS build ====================
    BUILD_DIR="${SCRIPT_DIR}/build-ios"

    echo "=== Building gst-vf-metal for iOS (${BUILD_TYPE}) ==="
    echo ""

    if [ -z "$GSTREAMER_ROOT_IOS" ]; then
        echo "ERROR: --gst-root=<path> is required for iOS builds"
        echo "  Point it to the GStreamer iOS SDK root directory"
        exit 1
    fi

    if ! command -v cmake &> /dev/null; then
        echo "ERROR: cmake not found. Install with: brew install cmake"
        exit 1
    fi

    mkdir -p "${BUILD_DIR}"

    cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DPLATFORM_IOS=ON \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DGSTREAMER_ROOT="${GSTREAMER_ROOT_IOS}"

    cmake --build "${BUILD_DIR}" --config "${BUILD_TYPE}" -j$(sysctl -n hw.ncpu)

    echo ""
    echo "=== Build complete ==="
    echo "Static library: ${BUILD_DIR}/gstvfmetal.a"
    echo ""
    echo "Link this library into your iOS app and register the plugin with:"
    echo "  #include \"gstvfmetal_static.h\""
    echo "  GST_PLUGIN_STATIC_REGISTER(vfmetal);"

    if [ ${RUN_TESTS} -eq 1 ]; then
        echo ""
        echo "WARNING: Tests cannot run for iOS builds from the command line."
    fi
elif [ "$PLATFORM" = "maccatalyst" ]; then
    # ==================== Mac Catalyst build ====================
    BUILD_DIR="${SCRIPT_DIR}/build-maccatalyst"

    echo "=== Building gst-vf-metal for Mac Catalyst (${BUILD_TYPE}) ==="
    echo ""

    if ! command -v cmake &> /dev/null; then
        echo "ERROR: cmake not found. Install with: brew install cmake"
        exit 1
    fi

    if ! command -v pkg-config &> /dev/null; then
        echo "ERROR: pkg-config not found. Install with: brew install pkg-config"
        exit 1
    fi

    if [ -d "/Library/Frameworks/GStreamer.framework" ]; then
        export PKG_CONFIG_PATH="/Library/Frameworks/GStreamer.framework/Libraries/pkgconfig:${PKG_CONFIG_PATH}"
        GST_CMD_PATH="/Library/Frameworks/GStreamer.framework/Commands"
        echo "Using GStreamer framework at /Library/Frameworks/GStreamer.framework"
    fi

    if ! pkg-config --exists gstreamer-1.0; then
        echo "ERROR: GStreamer not found."
        echo "  Install the GStreamer framework from https://gstreamer.freedesktop.org/download/"
        echo "  Or: brew install gstreamer gst-plugins-base"
        exit 1
    fi

    echo "GStreamer version: $(pkg-config --modversion gstreamer-1.0)"
    echo ""

    mkdir -p "${BUILD_DIR}"

    cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DPLATFORM_MACCATALYST=ON \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0

    cmake --build "${BUILD_DIR}" --config "${BUILD_TYPE}" -j$(sysctl -n hw.ncpu)

    echo ""
    echo "=== Build complete ==="
    echo "Plugin: ${BUILD_DIR}/gstvfmetal.dylib"
    echo ""

    GST_INSPECT="gst-inspect-1.0"
    if [ -n "${GST_CMD_PATH:-}" ] && [ -x "${GST_CMD_PATH}/gst-inspect-1.0" ]; then
        GST_INSPECT="${GST_CMD_PATH}/gst-inspect-1.0"
    fi

    echo "Test with:"
    echo "  GST_PLUGIN_PATH=${BUILD_DIR} ${GST_INSPECT} vfmetalcompositor"

    if [ ${RUN_TESTS} -eq 1 ]; then
        echo ""
        echo "WARNING: Tests for Mac Catalyst builds should be verified in a Catalyst app context."
    fi
else
    # ==================== macOS build ====================
    BUILD_DIR="${SCRIPT_DIR}/build"

    echo "=== Building gst-vf-metal (${BUILD_TYPE}) ==="
    echo ""

    # Check prerequisites
    if ! command -v cmake &> /dev/null; then
        echo "ERROR: cmake not found. Install with: brew install cmake"
        exit 1
    fi

    if ! command -v pkg-config &> /dev/null; then
        echo "ERROR: pkg-config not found. Install with: brew install pkg-config"
        exit 1
    fi

    # Try to find GStreamer: framework first, then Homebrew
    if [ -d "/Library/Frameworks/GStreamer.framework" ]; then
        export PKG_CONFIG_PATH="/Library/Frameworks/GStreamer.framework/Libraries/pkgconfig:${PKG_CONFIG_PATH}"
        GST_CMD_PATH="/Library/Frameworks/GStreamer.framework/Commands"
        echo "Using GStreamer framework at /Library/Frameworks/GStreamer.framework"
    fi

    if ! pkg-config --exists gstreamer-1.0; then
        echo "ERROR: GStreamer not found."
        echo "  Install the GStreamer framework from https://gstreamer.freedesktop.org/download/"
        echo "  Or: brew install gstreamer gst-plugins-base"
        exit 1
    fi

    echo "GStreamer version: $(pkg-config --modversion gstreamer-1.0)"
    echo ""

    # Create build directory
    mkdir -p "${BUILD_DIR}"

    # Configure
    cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0

    # Build
    cmake --build "${BUILD_DIR}" --config "${BUILD_TYPE}" -j$(sysctl -n hw.ncpu)

    echo ""
    echo "=== Build complete ==="
    echo "Plugin: ${BUILD_DIR}/gstvfmetal.dylib"
    echo ""

    # Determine gst-inspect path
    GST_INSPECT="gst-inspect-1.0"
    if [ -n "${GST_CMD_PATH}" ] && [ -x "${GST_CMD_PATH}/gst-inspect-1.0" ]; then
        GST_INSPECT="${GST_CMD_PATH}/gst-inspect-1.0"
    fi

    echo "Test with:"
    echo "  GST_PLUGIN_PATH=${BUILD_DIR} ${GST_INSPECT} vfmetalcompositor"
    echo ""
    echo "Run pipeline:"
    GST_LAUNCH="gst-launch-1.0"
    if [ -n "${GST_CMD_PATH}" ] && [ -x "${GST_CMD_PATH}/gst-launch-1.0" ]; then
        GST_LAUNCH="${GST_CMD_PATH}/gst-launch-1.0"
    fi
    echo "  GST_PLUGIN_PATH=${BUILD_DIR} ${GST_LAUNCH} \\"
    echo "    videotestsrc ! video/x-raw,format=BGRA ! vfmetalcompositor ! videoconvert ! autovideosink"

    # Run tests if requested
    if [ ${RUN_TESTS} -eq 1 ]; then
        echo ""
        "${SCRIPT_DIR}/tests/test-all.sh"
    fi
fi
