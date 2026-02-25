/* Metal convertscale shader source
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

#ifndef __METAL_CONVERTSCALE_SHADERS_H__
#define __METAL_CONVERTSCALE_SHADERS_H__

#import <Foundation/Foundation.h>

/* Convertscale shader source — concatenated after kVfMetalCommonShaderSource.
 * Contains vertex/fragment shaders for format conversion + scaling,
 * and compute kernels for UYVY/YUY2 output. */

static NSString *const kConvertScaleShaderSource = @R"(

// --- Convertscale uniforms ---

struct ConvertScaleUniforms {
    int colorMatrix;        // 0=BT.601, 1=BT.709
    int padding1;
    float2 padding2;
};

// --- Full-screen vertex shader (with letterbox support) ---

struct ConvertScaleVertexIn {
    float2 position;
    float2 texcoord;
};

vertex VertexOut convertScaleVertex(uint vid [[vertex_id]],
                                     constant float4 &viewport [[buffer(0)]]) {
    // viewport: x=offsetX, y=offsetY, z=scaleX, w=scaleY (in NDC)
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };

    VertexOut out;
    float2 pos = positions[vid];
    out.position = float4(pos.x * viewport.z + viewport.x,
                          pos.y * viewport.w + viewport.y,
                          0.0, 1.0);
    out.texcoord = (pos + 1.0) * 0.5;
    out.texcoord.y = 1.0 - out.texcoord.y;
    return out;
}

// --- Fragment shaders: sample input and output RGBA ---

// BGRA/RGBA input
fragment float4 convertScaleFragmentRGBA(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texcoord);
}

// Nearest-neighbor BGRA/RGBA input
fragment float4 convertScaleFragmentRGBANearest(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.texcoord);
}

// NV12 input
fragment float4 convertScaleFragmentNV12(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// Nearest-neighbor NV12 input
fragment float4 convertScaleFragmentNV12Nearest(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// I420 input
fragment float4 convertScaleFragmentI420(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// Nearest-neighbor I420 input
fragment float4 convertScaleFragmentI420Nearest(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// UYVY input (packed as RGBA8 at half width: U0 Y0 V0 Y1)
fragment float4 convertScaleFragmentUYVY(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float texWidth = float(tex.get_width());
    float fullWidth = texWidth * 2.0;

    float pixelX = in.texcoord.x * fullWidth;
    float macroX = floor(pixelX / 2.0);
    float subPixel = pixelX - macroX * 2.0;

    float2 macroCoord = float2((macroX + 0.5) / texWidth, in.texcoord.y);
    float4 packed = tex.sample(s, macroCoord);

    float u = packed.r;
    float v = packed.b;
    float y = (subPixel < 1.0) ? packed.g : packed.a;

    float3 rgb = yuvToRGB(y, u, v, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// YUY2 input (packed as RGBA8 at half width: Y0 U0 Y1 V0)
fragment float4 convertScaleFragmentYUY2(
    VertexOut in [[stage_in]],
    constant ConvertScaleUniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float texWidth = float(tex.get_width());
    float fullWidth = texWidth * 2.0;

    float pixelX = in.texcoord.x * fullWidth;
    float macroX = floor(pixelX / 2.0);
    float subPixel = pixelX - macroX * 2.0;

    float2 macroCoord = float2((macroX + 0.5) / texWidth, in.texcoord.y);
    float4 packed = tex.sample(s, macroCoord);

    float u = packed.g;
    float v = packed.a;
    float y = (subPixel < 1.0) ? packed.r : packed.b;

    float3 rgb = yuvToRGB(y, u, v, uniforms.colorMatrix);
    return float4(rgb, 1.0);
}

// --- Compute kernels for packed YUV output ---

kernel void rgbaToUYVY(
    texture2d<float, access::read> rgbaTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant ComputeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Each thread writes one macro-pixel (2 source pixels -> 1 output texel)
    uint outWidth = uniforms.width / 2;
    if (gid.x >= outWidth || gid.y >= uniforms.height) return;

    float3x3 mat = (uniforms.colorMatrix == 1) ? bt709_rgb_matrix : bt601_rgb_matrix;
    float3 off = (uniforms.colorMatrix == 1) ? bt709_rgb_offset : bt601_rgb_offset;

    uint2 p0 = uint2(gid.x * 2, gid.y);
    uint2 p1 = uint2(min(gid.x * 2 + 1, uniforms.width - 1), gid.y);

    float3 rgb0 = rgbaTex.read(p0).rgb;
    float3 rgb1 = rgbaTex.read(p1).rgb;

    float3 yuv0 = mat * rgb0 + off;
    float3 yuv1 = mat * rgb1 + off;

    float u = (yuv0.g + yuv1.g) * 0.5;
    float v = (yuv0.b + yuv1.b) * 0.5;

    // UYVY: U Y0 V Y1
    float4 packed = float4(
        clamp(u, 0.0, 1.0),
        clamp(yuv0.r, 0.0, 1.0),
        clamp(v, 0.0, 1.0),
        clamp(yuv1.r, 0.0, 1.0)
    );
    outTex.write(packed, gid);
}

kernel void rgbaToYUY2(
    texture2d<float, access::read> rgbaTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant ComputeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outWidth = uniforms.width / 2;
    if (gid.x >= outWidth || gid.y >= uniforms.height) return;

    float3x3 mat = (uniforms.colorMatrix == 1) ? bt709_rgb_matrix : bt601_rgb_matrix;
    float3 off = (uniforms.colorMatrix == 1) ? bt709_rgb_offset : bt601_rgb_offset;

    uint2 p0 = uint2(gid.x * 2, gid.y);
    uint2 p1 = uint2(min(gid.x * 2 + 1, uniforms.width - 1), gid.y);

    float3 rgb0 = rgbaTex.read(p0).rgb;
    float3 rgb1 = rgbaTex.read(p1).rgb;

    float3 yuv0 = mat * rgb0 + off;
    float3 yuv1 = mat * rgb1 + off;

    float u = (yuv0.g + yuv1.g) * 0.5;
    float v = (yuv0.b + yuv1.b) * 0.5;

    // YUY2: Y0 U Y1 V
    float4 packed = float4(
        clamp(yuv0.r, 0.0, 1.0),
        clamp(u, 0.0, 1.0),
        clamp(yuv1.r, 0.0, 1.0),
        clamp(v, 0.0, 1.0)
    );
    outTex.write(packed, gid);
}

)";

#endif /* __METAL_CONVERTSCALE_SHADERS_H__ */
