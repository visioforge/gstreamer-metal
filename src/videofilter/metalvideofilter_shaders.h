/* Metal video filter shader source
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

#ifndef __METAL_VIDEO_FILTER_SHADERS_H__
#define __METAL_VIDEO_FILTER_SHADERS_H__

#import <Foundation/Foundation.h>

/* Video filter shader source — concatenated after kVfMetalCommonShaderSource.
 * Contains compute kernels for color adjustment, blur/sharpen, chroma key,
 * LUT application, and output format conversion. */

static NSString *const kVideoFilterShaderSource = @R"(

// --- Filter uniforms ---

struct FilterUniforms {
    float brightness;       // [-1, 1]
    float contrast;         // [0, 2]
    float saturation;       // [0, 2]
    float hue;              // [-pi, pi]
    float gamma;            // [0.01, 10]
    float sharpness;        // [-1, 1]
    float sepia;            // [0, 1]
    float noise;            // [0, 1]
    float vignette;         // [0, 1]
    int invert;             // 0 or 1
    int chromaKeyEnabled;   // 0 or 1
    float chromaKeyR;       // key color R
    float chromaKeyG;       // key color G
    float chromaKeyB;       // key color B
    float chromaKeyTolerance;   // [0, 1]
    float chromaKeySmoothness;  // [0, 1]
    uint width;
    uint height;
    int colorMatrix;        // 0=BT.601, 1=BT.709
    uint frameIndex;        // for noise randomization
    int hasLUT;             // 0 or 1
    int lutSize;            // LUT dimension (e.g. 33 or 64)
    float padding;
};

// --- Hash function for noise ---

static inline float hash12(float2 p, uint frame) {
    float3 p3 = fract(float3(p.xyx) * 0.1031 + float(frame) * 0.00137);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// --- RGB <-> HSV helpers for hue rotation ---

static inline float3 rgbToHsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float3 hsvToRgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// --- Core color adjustment (applied to linear RGB) ---

static inline float4 applyColorAdjustments(float4 color,
                                            constant FilterUniforms &u,
                                            float2 texcoord) {
    float3 rgb = color.rgb;
    float alpha = color.a;

    // Brightness
    rgb += u.brightness;

    // Contrast
    rgb = (rgb - 0.5) * u.contrast + 0.5;

    // Saturation
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(lum), rgb, u.saturation);

    // Hue rotation (only if hue != 0)
    if (abs(u.hue) > 0.001) {
        float3 hsv = rgbToHsv(clamp(rgb, 0.0, 1.0));
        hsv.x = fract(hsv.x + u.hue / (2.0 * M_PI_F));
        rgb = hsvToRgb(hsv);
    }

    // Gamma
    rgb = pow(clamp(rgb, 0.0001, 1.0), float3(1.0 / u.gamma));

    // Sepia
    if (u.sepia > 0.001) {
        float3 sepiaColor = float3(
            dot(rgb, float3(0.393, 0.769, 0.189)),
            dot(rgb, float3(0.349, 0.686, 0.168)),
            dot(rgb, float3(0.272, 0.534, 0.131))
        );
        rgb = mix(rgb, sepiaColor, u.sepia);
    }

    // Invert
    if (u.invert) {
        rgb = 1.0 - rgb;
    }

    // Chroma key
    if (u.chromaKeyEnabled) {
        float3 keyColor = float3(u.chromaKeyR, u.chromaKeyG, u.chromaKeyB);
        float dist = distance(rgb, keyColor);
        float mask = smoothstep(u.chromaKeyTolerance,
                                u.chromaKeyTolerance + u.chromaKeySmoothness,
                                dist);
        alpha *= mask;
    }

    // Vignette
    if (u.vignette > 0.001) {
        float2 center = texcoord - 0.5;
        float dist = length(center) * 1.414;  // normalize to [0,1] at corners
        float vig = 1.0 - smoothstep(0.5, 1.0, dist) * u.vignette;
        rgb *= vig;
    }

    // Noise (film grain)
    if (u.noise > 0.001) {
        float n = hash12(texcoord * float2(u.width, u.height), u.frameIndex);
        n = (n - 0.5) * u.noise * 0.5;
        rgb += n;
    }

    return float4(clamp(rgb, 0.0, 1.0), alpha);
}

// --- Full-screen vertex shader ---

vertex VertexOut filterVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texcoord = (positions[vid] + 1.0) * 0.5;
    out.texcoord.y = 1.0 - out.texcoord.y;
    return out;
}

// --- Fragment shaders for RGBA render target ---

// BGRA/RGBA input
fragment float4 filterFragmentRGBA(
    VertexOut in [[stage_in]],
    constant FilterUniforms &uniforms [[buffer(0)]],
    texture2d<float> tex [[texture(0)]],
    texture3d<float> lutTex [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(s, in.texcoord);

    color = applyColorAdjustments(color, uniforms, in.texcoord);

    // LUT
    if (uniforms.hasLUT) {
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float scale = float(uniforms.lutSize - 1) / float(uniforms.lutSize);
        float offset = 0.5 / float(uniforms.lutSize);
        float3 lutCoord = color.rgb * scale + offset;
        color.rgb = lutTex.sample(lutSampler, lutCoord).rgb;
    }

    return color;
}

// NV12 input
fragment float4 filterFragmentNV12(
    VertexOut in [[stage_in]],
    constant FilterUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]],
    texture3d<float> lutTex [[texture(2)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, uniforms.colorMatrix);
    float4 color = float4(rgb, 1.0);

    color = applyColorAdjustments(color, uniforms, in.texcoord);

    if (uniforms.hasLUT) {
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float scale = float(uniforms.lutSize - 1) / float(uniforms.lutSize);
        float offset = 0.5 / float(uniforms.lutSize);
        float3 lutCoord = color.rgb * scale + offset;
        color.rgb = lutTex.sample(lutSampler, lutCoord).rgb;
    }

    return color;
}

// I420 input
fragment float4 filterFragmentI420(
    VertexOut in [[stage_in]],
    constant FilterUniforms &uniforms [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]],
    texture3d<float> lutTex [[texture(3)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, uniforms.colorMatrix);
    float4 color = float4(rgb, 1.0);

    color = applyColorAdjustments(color, uniforms, in.texcoord);

    if (uniforms.hasLUT) {
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float scale = float(uniforms.lutSize - 1) / float(uniforms.lutSize);
        float offset = 0.5 / float(uniforms.lutSize);
        float3 lutCoord = color.rgb * scale + offset;
        color.rgb = lutTex.sample(lutSampler, lutCoord).rgb;
    }

    return color;
}

// --- Gaussian blur compute kernels (separable, for sharpness) ---

constant int BLUR_KERNEL_SIZE = 9;
constant float blurWeights[9] = {
    0.028532, 0.067234, 0.124009, 0.179044, 0.20236,
    0.179044, 0.124009, 0.067234, 0.028532
};

kernel void blurHorizontal(
    texture2d<float, access::read> inputTex [[texture(0)]],
    texture2d<float, access::write> outputTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = inputTex.get_width();
    uint h = inputTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 sum = float4(0);
    int halfKernel = BLUR_KERNEL_SIZE / 2;
    for (int i = 0; i < BLUR_KERNEL_SIZE; i++) {
        int x = int(gid.x) + i - halfKernel;
        x = clamp(x, 0, int(w) - 1);
        sum += inputTex.read(uint2(x, gid.y)) * blurWeights[i];
    }
    outputTex.write(sum, gid);
}

kernel void blurVertical(
    texture2d<float, access::read> inputTex [[texture(0)]],
    texture2d<float, access::write> outputTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = inputTex.get_width();
    uint h = inputTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 sum = float4(0);
    int halfKernel = BLUR_KERNEL_SIZE / 2;
    for (int i = 0; i < BLUR_KERNEL_SIZE; i++) {
        int y = int(gid.y) + i - halfKernel;
        y = clamp(y, 0, int(h) - 1);
        sum += inputTex.read(uint2(gid.x, y)) * blurWeights[i];
    }
    outputTex.write(sum, gid);
}

// Unsharp mask: sharp = original + (original - blurred) * amount
kernel void unsharpMask(
    texture2d<float, access::read> originalTex [[texture(0)]],
    texture2d<float, access::read> blurredTex [[texture(1)]],
    texture2d<float, access::write> outputTex [[texture(2)]],
    constant float &amount [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = originalTex.get_width();
    uint h = originalTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 original = originalTex.read(gid);
    float4 blurred = blurredTex.read(gid);

    if (amount > 0) {
        // Sharpen: original + (original - blurred) * amount
        float4 result = original + (original - blurred) * amount;
        result = clamp(result, 0.0, 1.0);
        result.a = original.a;
        outputTex.write(result, gid);
    } else {
        // Blur: mix original with blurred based on |amount|
        float4 result = mix(original, blurred, abs(amount));
        result.a = original.a;
        outputTex.write(result, gid);
    }
}

)";

#endif /* __METAL_VIDEO_FILTER_SHADERS_H__ */
