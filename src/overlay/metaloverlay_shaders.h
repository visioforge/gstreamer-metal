/* Metal overlay shader source
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

#ifndef __METAL_OVERLAY_SHADERS_H__
#define __METAL_OVERLAY_SHADERS_H__

#import <Foundation/Foundation.h>

static NSString *const kOverlayShaderSource = @R"(

// --- Overlay uniforms ---

struct OverlayUniforms {
    float overlayX;        // overlay position (pixels)
    float overlayY;
    float overlayWidth;    // overlay size (pixels)
    float overlayHeight;
    float frameWidth;      // frame dimensions
    float frameHeight;
    float alpha;           // overlay opacity [0, 1]
    int colorMatrix;       // 0=BT.601, 1=BT.709
};

// --- Pass-through vertex shader ---

vertex VertexOut overlayVertex(uint vid [[vertex_id]]) {
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

// --- Fragment: sample video + composite overlay ---

fragment float4 overlayFragmentRGBA(
    VertexOut in [[stage_in]],
    constant OverlayUniforms &u [[buffer(0)]],
    texture2d<float> videoTex [[texture(0)]],
    texture2d<float> overlayTex [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 video = videoTex.sample(s, in.texcoord);

    // Check if pixel is within overlay rectangle
    float px = in.texcoord.x * u.frameWidth;
    float py = in.texcoord.y * u.frameHeight;

    if (px >= u.overlayX && px < u.overlayX + u.overlayWidth &&
        py >= u.overlayY && py < u.overlayY + u.overlayHeight) {
        float2 overlayUV = float2(
            (px - u.overlayX) / u.overlayWidth,
            (py - u.overlayY) / u.overlayHeight
        );
        float4 overlay = overlayTex.sample(s, overlayUV);
        float a = overlay.a * u.alpha;
        video.rgb = mix(video.rgb, overlay.rgb, a);
    }

    return video;
}

fragment float4 overlayFragmentNV12(
    VertexOut in [[stage_in]],
    constant OverlayUniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]],
    texture2d<float> overlayTex [[texture(2)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float2 uv = uvTex.sample(s, in.texcoord).rg;
    float3 rgb = yuvToRGB(y, uv.r, uv.g, u.colorMatrix);
    float4 video = float4(rgb, 1.0);

    float px = in.texcoord.x * u.frameWidth;
    float py = in.texcoord.y * u.frameHeight;

    if (px >= u.overlayX && px < u.overlayX + u.overlayWidth &&
        py >= u.overlayY && py < u.overlayY + u.overlayHeight) {
        float2 overlayUV = float2(
            (px - u.overlayX) / u.overlayWidth,
            (py - u.overlayY) / u.overlayHeight
        );
        float4 overlay = overlayTex.sample(s, overlayUV);
        float a = overlay.a * u.alpha;
        video.rgb = mix(video.rgb, overlay.rgb, a);
    }

    return video;
}

fragment float4 overlayFragmentI420(
    VertexOut in [[stage_in]],
    constant OverlayUniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uTex [[texture(1)]],
    texture2d<float> vTex [[texture(2)]],
    texture2d<float> overlayTex [[texture(3)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = yTex.sample(s, in.texcoord).r;
    float cb = uTex.sample(s, in.texcoord).r;
    float cr = vTex.sample(s, in.texcoord).r;
    float3 rgb = yuvToRGB(y, cb, cr, u.colorMatrix);
    float4 video = float4(rgb, 1.0);

    float px = in.texcoord.x * u.frameWidth;
    float py = in.texcoord.y * u.frameHeight;

    if (px >= u.overlayX && px < u.overlayX + u.overlayWidth &&
        py >= u.overlayY && py < u.overlayY + u.overlayHeight) {
        float2 overlayUV = float2(
            (px - u.overlayX) / u.overlayWidth,
            (py - u.overlayY) / u.overlayHeight
        );
        float4 overlay = overlayTex.sample(s, overlayUV);
        float a = overlay.a * u.alpha;
        video.rgb = mix(video.rgb, overlay.rgb, a);
    }

    return video;
}

)";

#endif /* __METAL_OVERLAY_SHADERS_H__ */
