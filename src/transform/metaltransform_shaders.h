/* Metal video transform shader source
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

#ifndef __METAL_TRANSFORM_SHADERS_H__
#define __METAL_TRANSFORM_SHADERS_H__

#import <Foundation/Foundation.h>

static NSString *const kTransformShaderSource = @R"(

// --- Transform uniforms ---

struct TransformUniforms {
    float2x2 uvTransform;   // 2x2 UV coordinate transform matrix
    float2 uvOffset;        // UV offset after transform
    int colorMatrix;        // 0=BT.601, 1=BT.709
    int padding;
};

// --- Vertex shader with UV transform ---

vertex VertexOut transformVertex(uint vid [[vertex_id]],
                                 constant TransformUniforms &u [[buffer(0)]]) {
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);

    // Compute base texcoord
    float2 tc = (positions[vid] + 1.0) * 0.5;
    tc.y = 1.0 - tc.y;

    // Apply UV transform: center, transform, uncenter
    tc -= 0.5;
    tc = u.uvTransform * tc;
    tc += 0.5 + u.uvOffset;

    out.texcoord = tc;
    return out;
}

// --- Fragment shaders ---

fragment float4 transformFragmentRGBA(
    VertexOut in [[stage_in]],
    constant TransformUniforms &u [[buffer(0)]],
    texture2d<float> tex [[texture(0)]]
) {
    if (in.texcoord.x < 0.0 || in.texcoord.x > 1.0 ||
        in.texcoord.y < 0.0 || in.texcoord.y > 1.0)
        return float4(0, 0, 0, 1);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texcoord);
}

fragment float4 transformFragmentNV12(
    VertexOut in [[stage_in]],
    constant TransformUniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    if (in.texcoord.x < 0.0 || in.texcoord.x > 1.0 ||
        in.texcoord.y < 0.0 || in.texcoord.y > 1.0)
        return float4(0, 0, 0, 1);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, u.colorMatrix);
    return float4(rgb, 1.0);
}

fragment float4 transformFragmentI420(
    VertexOut in [[stage_in]],
    constant TransformUniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]]
) {
    if (in.texcoord.x < 0.0 || in.texcoord.x > 1.0 ||
        in.texcoord.y < 0.0 || in.texcoord.y > 1.0)
        return float4(0, 0, 0, 1);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, u.colorMatrix);
    return float4(rgb, 1.0);
}

)";

#endif /* __METAL_TRANSFORM_SHADERS_H__ */
