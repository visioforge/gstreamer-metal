/* Shared Metal shader source
 *
 * Copyright (C) 2026 Roman Miniailov
 * Author: Roman Miniailov <miniailovr@gmail.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#import "vfmetalshaders.h"

NSString *const kVfMetalCommonShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

struct Uniforms {
    float alpha;
    int colorMatrix;    // 0=BT.601, 1=BT.709
    float2 padding;
};

/* BT.601 limited range YUV->RGB matrix */
constant float3 bt601_offset = float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
constant float3x3 bt601_matrix = float3x3(
    float3(1.164383,  1.164383, 1.164383),
    float3(0.0,      -0.391762, 2.017232),
    float3(1.596027, -0.812968, 0.0)
);

/* BT.709 limited range YUV->RGB matrix */
constant float3 bt709_offset = float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
constant float3x3 bt709_matrix = float3x3(
    float3(1.164383,  1.164383, 1.164383),
    float3(0.0,      -0.213249, 2.112402),
    float3(1.792741, -0.532909, 0.0)
);

/* BT.601 limited range RGB->YUV matrix (columns = R, G, B coefficient vectors) */
constant float3 bt601_rgb_offset = float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
constant float3x3 bt601_rgb_matrix = float3x3(
    float3( 0.256788, -0.148223,  0.439216),
    float3( 0.504129, -0.290993, -0.367788),
    float3( 0.097906,  0.439216, -0.071427)
);

/* BT.709 limited range RGB->YUV matrix (columns = R, G, B coefficient vectors) */
constant float3 bt709_rgb_offset = float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
constant float3x3 bt709_rgb_matrix = float3x3(
    float3( 0.182586, -0.100644,  0.439216),
    float3( 0.614231, -0.338572, -0.398942),
    float3( 0.062007,  0.439216, -0.040274)
);

static inline float3 yuvToRGB(float y, float cb, float cr, int colorMatrix) {
    float3 yuv = (colorMatrix == 1)
        ? float3(y, cb, cr) - bt709_offset
        : float3(y, cb, cr) - bt601_offset;
    float3 rgb = (colorMatrix == 1)
        ? bt709_matrix * yuv
        : bt601_matrix * yuv;
    return clamp(rgb, 0.0, 1.0);
}

// --- Compute shaders for RGB->YUV output conversion ---

struct ComputeUniforms {
    uint width;
    uint height;
    int colorMatrix;    // 0=BT.601, 1=BT.709
    uint padding;
};

kernel void rgbaToNV12(
    texture2d<float, access::read> rgbaTex [[texture(0)]],
    texture2d<float, access::write> yTex [[texture(1)]],
    texture2d<float, access::write> uvTex [[texture(2)]],
    constant ComputeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float3x3 mat = (uniforms.colorMatrix == 1) ? bt709_rgb_matrix : bt601_rgb_matrix;
    float3 off = (uniforms.colorMatrix == 1) ? bt709_rgb_offset : bt601_rgb_offset;

    // Write Y for every pixel
    if (gid.x < uniforms.width && gid.y < uniforms.height) {
        float4 rgba = rgbaTex.read(gid);
        float3 yuv = mat * rgba.rgb + off;
        yTex.write(float4(clamp(yuv.r, 0.0, 1.0), 0, 0, 1), gid);
    }

    // Write UV at half resolution (one UV pair per 2x2 block)
    if ((gid.x % 2 == 0) && (gid.y % 2 == 0)) {
        uint2 uvPos = gid / 2;
        uint2 halfSize = uint2((uniforms.width + 1) / 2, (uniforms.height + 1) / 2);
        if (uvPos.x < halfSize.x && uvPos.y < halfSize.y) {
            // Average 2x2 block
            float3 sum = float3(0);
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) {
                    uint2 p = gid + uint2(dx, dy);
                    p = min(p, uint2(uniforms.width - 1, uniforms.height - 1));
                    float4 rgba = rgbaTex.read(p);
                    sum += rgba.rgb;
                }
            }
            sum *= 0.25;
            float3 yuv = mat * sum + off;
            uvTex.write(float4(clamp(yuv.g, 0.0, 1.0),
                               clamp(yuv.b, 0.0, 1.0), 0, 1), uvPos);
        }
    }
}

kernel void rgbaToI420(
    texture2d<float, access::read> rgbaTex [[texture(0)]],
    texture2d<float, access::write> yTex [[texture(1)]],
    texture2d<float, access::write> uTex [[texture(2)]],
    texture2d<float, access::write> vTex [[texture(3)]],
    constant ComputeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float3x3 mat = (uniforms.colorMatrix == 1) ? bt709_rgb_matrix : bt601_rgb_matrix;
    float3 off = (uniforms.colorMatrix == 1) ? bt709_rgb_offset : bt601_rgb_offset;

    // Write Y for every pixel
    if (gid.x < uniforms.width && gid.y < uniforms.height) {
        float4 rgba = rgbaTex.read(gid);
        float3 yuv = mat * rgba.rgb + off;
        yTex.write(float4(clamp(yuv.r, 0.0, 1.0), 0, 0, 1), gid);
    }

    // Write U and V at half resolution
    if ((gid.x % 2 == 0) && (gid.y % 2 == 0)) {
        uint2 uvPos = gid / 2;
        uint2 halfSize = uint2((uniforms.width + 1) / 2, (uniforms.height + 1) / 2);
        if (uvPos.x < halfSize.x && uvPos.y < halfSize.y) {
            float3 sum = float3(0);
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) {
                    uint2 p = gid + uint2(dx, dy);
                    p = min(p, uint2(uniforms.width - 1, uniforms.height - 1));
                    float4 rgba = rgbaTex.read(p);
                    sum += rgba.rgb;
                }
            }
            sum *= 0.25;
            float3 yuv = mat * sum + off;
            uTex.write(float4(clamp(yuv.g, 0.0, 1.0), 0, 0, 1), uvPos);
            vTex.write(float4(clamp(yuv.b, 0.0, 1.0), 0, 0, 1), uvPos);
        }
    }
}
)";
