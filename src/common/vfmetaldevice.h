/* Shared Metal device management
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

#ifndef __VF_METAL_DEVICE_H__
#define __VF_METAL_DEVICE_H__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <gst/gst.h>

/* Debug category for shared Metal infrastructure */
GST_DEBUG_CATEGORY_EXTERN (gst_vf_metal_debug);

@interface VfMetalDevice : NSObject

+ (instancetype)sharedDevice;

@property (nonatomic, readonly) id<MTLDevice> device;

- (id<MTLLibrary>)compileShaderSource:(NSString *)source
                                error:(NSError **)error;

@end

#endif /* __VF_METAL_DEVICE_H__ */
