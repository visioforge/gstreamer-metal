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

#import "vfmetaldevice.h"

GST_DEBUG_CATEGORY (gst_vf_metal_debug);

@implementation VfMetalDevice {
    id<MTLDevice> _device;
}

+ (instancetype)sharedDevice
{
    static VfMetalDevice *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VfMetalDevice alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate
{
    self = [super init];
    if (!self) return nil;

    /* Initialize debug category on first use */
    static dispatch_once_t catOnce;
    dispatch_once(&catOnce, ^{
        GST_DEBUG_CATEGORY_INIT (gst_vf_metal_debug,
            "vfmetal", 0, "VF Metal shared infrastructure");
    });

#if TARGET_OS_IOS
    _device = MTLCreateSystemDefaultDevice();
#else
    /* macOS: prefer discrete GPU if available */
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    _device = devices.firstObject;
    for (id<MTLDevice> dev in devices) {
        if (!dev.isLowPower) {
            _device = dev;
            break;
        }
    }
#endif

    if (!_device) {
        GST_ERROR ("VfMetalDevice: No Metal device available");
        return nil;
    }

    GST_INFO ("VfMetalDevice: Using device '%s'", _device.name.UTF8String);

    return self;
}

- (instancetype)init
{
    /* Prevent direct init — use +sharedDevice */
    return nil;
}

- (id<MTLDevice>)device
{
    return _device;
}

- (id<MTLLibrary>)compileShaderSource:(NSString *)source
                                error:(NSError **)error
{
    return [_device newLibraryWithSource:source
                                options:nil
                                  error:error];
}

@end
