cmake_minimum_required(VERSION 3.20)

# Platform selection: pass -DPLATFORM_IOS=ON or -DPLATFORM_MACCATALYST=ON
option(PLATFORM_IOS "Build for iOS" OFF)
option(PLATFORM_MACCATALYST "Build for Mac Catalyst" OFF)

if(PLATFORM_IOS AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_SYSTEM_NAME iOS)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(BUILD_IOS TRUE)
    set(BUILD_MACCATALYST FALSE)
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "iOS deployment target")
    endif()
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "iOS architectures")
    endif()
elseif(PLATFORM_MACCATALYST)
    set(BUILD_IOS FALSE)
    set(BUILD_MACCATALYST TRUE)
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Mac Catalyst deployment target")
    endif()
else()
    set(BUILD_IOS FALSE)
    set(BUILD_MACCATALYST FALSE)
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "macOS deployment target")
    endif()
endif()

project(gst-vf-metal LANGUAGES C OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_OBJC_STANDARD 11)

# GStreamer discovery
set(GSTREAMER_ROOT "" CACHE PATH "Path to GStreamer installation root")

if(BUILD_IOS)
    # iOS: pkg-config doesn't work for cross-compilation
    if(NOT GSTREAMER_ROOT)
        message(FATAL_ERROR
            "GSTREAMER_ROOT must be set for iOS builds. "
            "Point it to the GStreamer iOS SDK root directory.")
    endif()

    set(GST_INCLUDE_DIRS
        "${GSTREAMER_ROOT}/include/gstreamer-1.0"
        "${GSTREAMER_ROOT}/include/glib-2.0"
        "${GSTREAMER_ROOT}/lib/glib-2.0/include"
    )
    set(GST_LIBRARY_DIRS "${GSTREAMER_ROOT}/lib")
    set(GST_LIBRARIES
        gstreamer-1.0
        gstvideo-1.0
        gstbase-1.0
        glib-2.0
        gobject-2.0
    )
    set(GST_CFLAGS_OTHER "")
else()
    # macOS: use pkg-config
    if(GSTREAMER_ROOT)
        set(ENV{PKG_CONFIG_PATH}
            "${GSTREAMER_ROOT}/Libraries/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    elseif(EXISTS "/Library/Frameworks/GStreamer.framework/Libraries/pkgconfig")
        set(ENV{PKG_CONFIG_PATH}
            "/Library/Frameworks/GStreamer.framework/Libraries/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    endif()

    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GST REQUIRED
        gstreamer-1.0
        gstreamer-video-1.0
        gstreamer-base-1.0
    )
endif()

# ===== Source file lists =====

# Shared infrastructure
set(COMMON_SOURCES
    src/common/vfmetaldevice.m
    src/common/vfmetaltextureutil.m
    src/common/vfmetalshaders.m
    src/common/vfmetalyuvoutput.m
)

# Compositor element
set(COMPOSITOR_SOURCES
    src/compositor/gstvfmetalcompositor.m
    src/compositor/gstvfmetalcompositorpad.m
    src/compositor/metalcomprenderer.m
)

# Video sink element
set(VIDEOSINK_SOURCES
    src/videosink/gstvfmetalvideosink.m
    src/videosink/metalvideosinkrenderer.m
)

# Video filter element
set(VIDEOFILTER_SOURCES
    src/videofilter/gstvfmetalvideofilter.m
    src/videofilter/metalvideofilterrenderer.m
    src/videofilter/metalvideofilter_shaders.h
)

# Convert and scale element
set(CONVERTSCALE_SOURCES
    src/convertscale/gstvfmetalconvertscale.m
    src/convertscale/metalconvertscalerenderer.m
    src/convertscale/metalconvertscale_shaders.h
)

# Video transform element
set(TRANSFORM_SOURCES
    src/transform/gstvfmetaltransform.m
    src/transform/metaltransformrenderer.m
    src/transform/metaltransform_shaders.h
)

# Deinterlace element
set(DEINTERLACE_SOURCES
    src/deinterlace/gstvfmetaldeinterlace.m
    src/deinterlace/metaldeinterlacerenderer.m
    src/deinterlace/metaldeinterlace_shaders.h
)

# Overlay element
set(OVERLAY_SOURCES
    src/overlay/gstvfmetaloverlay.m
    src/overlay/metaloverlayrenderer.m
    src/overlay/metaloverlay_shaders.h
)

# Plugin registration
set(PLUGIN_SOURCES
    src/plugin.m
)

# All sources combined
set(ALL_SOURCES
    ${COMMON_SOURCES}
    ${COMPOSITOR_SOURCES}
    ${VIDEOFILTER_SOURCES}
    ${CONVERTSCALE_SOURCES}
    ${TRANSFORM_SOURCES}
    ${DEINTERLACE_SOURCES}
    ${OVERLAY_SOURCES}
    ${PLUGIN_SOURCES}
)

# Videosink requires AppKit (macOS only, not available on iOS or Mac Catalyst)
if(NOT BUILD_IOS AND NOT BUILD_MACCATALYST)
    list(APPEND ALL_SOURCES ${VIDEOSINK_SOURCES})
endif()

# ===== Library target =====

if(BUILD_IOS)
    add_library(gstvfmetal STATIC ${ALL_SOURCES})
else()
    add_library(gstvfmetal SHARED ${ALL_SOURCES})
endif()

target_include_directories(gstvfmetal PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/common
    ${CMAKE_CURRENT_SOURCE_DIR}/src/compositor
    ${CMAKE_CURRENT_SOURCE_DIR}/src/videosink
    ${CMAKE_CURRENT_SOURCE_DIR}/src/videofilter
    ${CMAKE_CURRENT_SOURCE_DIR}/src/convertscale
    ${CMAKE_CURRENT_SOURCE_DIR}/src/transform
    ${CMAKE_CURRENT_SOURCE_DIR}/src/deinterlace
    ${CMAKE_CURRENT_SOURCE_DIR}/src/overlay
    ${GST_INCLUDE_DIRS}
)

target_link_directories(gstvfmetal PRIVATE
    ${GST_LIBRARY_DIRS}
)

target_link_libraries(gstvfmetal
    ${GST_LIBRARIES}
    "-framework Metal"
    "-framework CoreVideo"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework CoreGraphics"
    "-framework ImageIO"
)

# AppKit is needed for video sink window management (macOS only)
if(NOT BUILD_IOS AND NOT BUILD_MACCATALYST)
    target_link_libraries(gstvfmetal "-framework AppKit")
endif()

target_compile_options(gstvfmetal PRIVATE
    ${GST_CFLAGS_OTHER}
    -Wall
    -Wno-deprecated-declarations
    -fobjc-arc
)

# Videosink is excluded on iOS and Mac Catalyst (requires AppKit)
if(BUILD_IOS OR BUILD_MACCATALYST)
    target_compile_definitions(gstvfmetal PRIVATE DISABLE_VIDEOSINK=1)
endif()

# ===== Install rules =====

if(BUILD_IOS)
    set_target_properties(gstvfmetal PROPERTIES
        PREFIX ""
        OUTPUT_NAME "gstvfmetal"
    )

    install(TARGETS gstvfmetal
        ARCHIVE DESTINATION lib
    )
    install(FILES
        src/gstvfmetal_static.h
        src/compositor/gstvfmetalcompositor.h
        src/compositor/metalcomprenderer.h
        src/videosink/gstvfmetalvideosink.h
        src/videosink/metalvideosinkrenderer.h
        src/videofilter/gstvfmetalvideofilter.h
        src/videofilter/metalvideofilterrenderer.h
        src/convertscale/gstvfmetalconvertscale.h
        src/convertscale/metalconvertscalerenderer.h
        src/transform/gstvfmetaltransform.h
        src/transform/metaltransformrenderer.h
        src/deinterlace/gstvfmetaldeinterlace.h
        src/deinterlace/metaldeinterlacerenderer.h
        src/overlay/gstvfmetaloverlay.h
        src/overlay/metaloverlayrenderer.h
        src/common/vfmetaldevice.h
        src/common/vfmetaltextureutil.h
        src/common/vfmetalshaders.h
        src/common/vfmetalyuvoutput.h
        DESTINATION include/gst-vf-metal
    )
else()
    set_target_properties(gstvfmetal PROPERTIES
        PREFIX ""
        SUFFIX ".dylib"
    )

    # Install to GStreamer plugin directory
    execute_process(
        COMMAND pkg-config --variable=pluginsdir gstreamer-1.0
        OUTPUT_VARIABLE GST_PLUGINS_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE PKG_CONFIG_RESULT
    )

    if(PKG_CONFIG_RESULT EQUAL 0 AND GST_PLUGINS_DIR)
        install(TARGETS gstvfmetal
            LIBRARY DESTINATION ${GST_PLUGINS_DIR}
        )
        message(STATUS "GStreamer plugin dir: ${GST_PLUGINS_DIR}")
    else()
        message(WARNING "Could not determine GStreamer plugin directory")
        install(TARGETS gstvfmetal
            LIBRARY DESTINATION lib/gstreamer-1.0
        )
    endif()
endif()
