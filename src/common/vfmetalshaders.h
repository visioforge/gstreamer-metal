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

#ifndef __VF_METAL_SHADERS_H__
#define __VF_METAL_SHADERS_H__

#import <Foundation/Foundation.h>

/* Shared shader source containing:
 * - VertexOut struct
 * - Uniforms / ComputeUniforms structs
 * - BT.601 / BT.709 YUV<->RGB matrices
 * - yuvToRGB() helper function
 * - rgbaToNV12 / rgbaToI420 compute kernels
 *
 * Element-specific shaders should be concatenated after this source
 * before compilation. */
extern NSString *const kVfMetalCommonShaderSource;

/* Uniform struct matching shader Uniforms — used by host code */
typedef struct {
    float alpha;
    int32_t colorMatrix;    /* 0=BT.601, 1=BT.709 */
    float padding[2];
} VfMetalUniforms;

/* Compute uniform struct matching shader ComputeUniforms */
typedef struct {
    uint32_t width;
    uint32_t height;
    int32_t colorMatrix;
    uint32_t padding;
} VfMetalComputeUniforms;

#endif /* __VF_METAL_SHADERS_H__ */
