/* Metal deinterlace shader source
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

#ifndef __METAL_DEINTERLACE_SHADERS_H__
#define __METAL_DEINTERLACE_SHADERS_H__

#import <Foundation/Foundation.h>

static NSString *const kDeinterlaceShaderSource = @R"(

// --- YUV-to-RGBA render pass (GPU-side input conversion) ---

vertex VertexOut deinterlacePassVertex(uint vid [[vertex_id]]) {
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

fragment float4 deinterlaceNV12ToRGBA(
    VertexOut in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, u.colorMatrix);
    return float4(rgb, 1.0);
}

fragment float4 deinterlaceI420ToRGBA(
    VertexOut in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, u.colorMatrix);
    return float4(rgb, 1.0);
}

// --- Deinterlace uniforms ---

struct DeinterlaceUniforms {
    uint width;
    uint height;
    int topFieldFirst;      // 1=top field first, 0=bottom field first
    int method;             // 0=bob, 1=weave, 2=linear, 3=greedyh
    float motionThreshold;  // for greedyh method
    int padding1;
    int padding2;
    int padding3;
};

// --- Bob deinterlace: duplicate lines from one field ---

kernel void deinterlaceBob(
    texture2d<float, access::read> inTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant DeinterlaceUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) return;

    uint y = gid.y;
    bool isTopField = (y % 2 == 0);
    bool keepField = (u.topFieldFirst != 0) ? isTopField : !isTopField;

    float4 color;
    if (keepField) {
        // This line belongs to the kept field — use directly
        color = inTex.read(gid);
    } else {
        // This line belongs to the discarded field — interpolate from neighbors
        uint above = (y > 0) ? y - 1 : 0;
        uint below = (y < u.height - 1) ? y + 1 : u.height - 1;
        float4 a = inTex.read(uint2(gid.x, above));
        float4 b = inTex.read(uint2(gid.x, below));
        color = (a + b) * 0.5;
    }

    outTex.write(color, gid);
}

// --- Linear deinterlace: 3-tap vertical filter ---

kernel void deinterlaceLinear(
    texture2d<float, access::read> inTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant DeinterlaceUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) return;

    uint y = gid.y;
    bool isTopField = (y % 2 == 0);
    bool keepField = (u.topFieldFirst != 0) ? isTopField : !isTopField;

    float4 color;
    if (keepField) {
        color = inTex.read(gid);
    } else {
        // 3-tap filter: weight neighbors at -1, +1 with center from -2, +2
        uint y0 = (y >= 2) ? y - 2 : 0;
        uint y1 = (y > 0) ? y - 1 : 0;
        uint y2 = (y < u.height - 1) ? y + 1 : u.height - 1;
        uint y3 = (y < u.height - 2) ? y + 2 : u.height - 1;

        float4 a = inTex.read(uint2(gid.x, y0));
        float4 b = inTex.read(uint2(gid.x, y1));
        float4 c = inTex.read(uint2(gid.x, y2));
        float4 d = inTex.read(uint2(gid.x, y3));

        // Weighted: -1/8 * a + 5/8 * b + 5/8 * c - 1/8 * d
        // Simplified: (b + c) * 0.625 - (a + d) * 0.125
        // Or just use linear: (b + c) * 0.5
        color = (b + c) * 0.5;
    }

    outTex.write(color, gid);
}

// --- Weave deinterlace: merge fields from current and previous frame ---

kernel void deinterlaceWeave(
    texture2d<float, access::read> curTex [[texture(0)]],
    texture2d<float, access::read> prevTex [[texture(1)]],
    texture2d<float, access::write> outTex [[texture(2)]],
    constant DeinterlaceUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) return;

    uint y = gid.y;
    bool isTopField = (y % 2 == 0);
    bool keepFromCurrent = (u.topFieldFirst != 0) ? isTopField : !isTopField;

    float4 color;
    if (keepFromCurrent) {
        color = curTex.read(gid);
    } else {
        color = prevTex.read(gid);
    }

    outTex.write(color, gid);
}

// --- GreedyH deinterlace: motion-adaptive with previous frame ---

kernel void deinterlaceGreedyH(
    texture2d<float, access::read> curTex [[texture(0)]],
    texture2d<float, access::read> prevTex [[texture(1)]],
    texture2d<float, access::write> outTex [[texture(2)]],
    constant DeinterlaceUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) return;

    uint y = gid.y;
    bool isTopField = (y % 2 == 0);
    bool keepFromCurrent = (u.topFieldFirst != 0) ? isTopField : !isTopField;

    if (keepFromCurrent) {
        outTex.write(curTex.read(gid), gid);
        return;
    }

    // For lines from the other field, choose between weave and bob
    // based on motion detection
    float4 curLine = curTex.read(gid);
    float4 prevLine = prevTex.read(gid);

    // Motion: difference between current and previous frame at this position
    float motion = length(curLine.rgb - prevLine.rgb);

    if (motion < u.motionThreshold) {
        // Low motion: weave (use previous frame's field line)
        outTex.write(prevLine, gid);
    } else {
        // High motion: bob (interpolate from current frame's kept field)
        uint above = (y > 0) ? y - 1 : 0;
        uint below = (y < u.height - 1) ? y + 1 : u.height - 1;
        float4 a = curTex.read(uint2(gid.x, above));
        float4 b = curTex.read(uint2(gid.x, below));
        outTex.write((a + b) * 0.5, gid);
    }
}

)";

#endif /* __METAL_DEINTERLACE_SHADERS_H__ */
