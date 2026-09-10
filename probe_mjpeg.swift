#!/usr/bin/env swift
// Probe MS2130S USB descriptors to check for 120fps video formats
// Build: swiftc -o probe_mjpeg probe_mjpeg.swift -I libs/include/libusb-1.0 -L libs -lusb-1.0

import Foundation

// libusb imports
let libusbPath = "/Users/txa/project/Openterface_MacOS/libs/libusb-1.0.a"
_ = libusbPath // suppress unused warning

// UVC constants
let USB_CLASS_VIDEO: UInt8 = 0x0E
let CS_INTERFACE: UInt8 = 0x24
let CS_ENDPOINT: UInt8 = 0x25

// UVC Video Control interface descriptor subtypes
let VC_HEADER: UInt8 = 0x01
let VC_INPUT_TERMINAL: UInt8 = 0x02
let VC_OUTPUT_TERMINAL: UInt8 = 0x03
let VC_PROCESSING_UNIT: UInt8 = 0x05

// UVC Video Streaming interface descriptor subtypes
let VS_INPUT_HEADER: UInt8 = 0x01
let VS_OUTPUT_HEADER: UInt8 = 0x02
let VS_FORMAT_UNCOMPRESSED: UInt8 = 0x04
let VS_FRAME_UNCOMPRESSED: UInt8 = 0x05
let VS_FORMAT_MJPEG: UInt8 = 0x06
let VS_FRAME_MJPEG: UInt8 = 0x07
let VS_FORMAT_H264: UInt8 = 0x08 // not standard but some devices use it

// Transfer types
let LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: UInt8 = 0x01
let LIBUSB_TRANSFER_TYPE_BULK: UInt8 = 0x02

print("=== MS2130S USB Descriptor Probe ===")
print()

// Target device
let TARGET_VID: UInt16 = 0x345F
let TARGET_PID: UInt16 = 0x2132

var ctx: OpaquePointer?
guard libusb_init(&ctx) == LIBUSB_SUCCESS.rawValue else {
    print("ERROR: libusb_init failed")
    exit(1)
}
defer { libusb_exit(ctx) }

var list: UnsafeMutablePointer<OpaquePointer?>?
let count = libusb_get_device_list(ctx, &list)
guard count > 0, let deviceList = list else {
    print("ERROR: No USB devices found")
    exit(1)
}
defer { libusb_free_device_list(deviceList, 1) }

print("Scanning \(count) USB devices...")
print()

for i in 0..<count {
    guard let dev = deviceList[Int(i)] else { continue }
    var desc = libusb_device_descriptor()
    guard libusb_get_device_descriptor(dev, &desc) == LIBUSB_SUCCESS.rawValue else { continue }

    if desc.idVendor == TARGET_VID && desc.idProduct == TARGET_PID {
        print("✅ FOUND MS2130S: VID=0x\(String(format: "%04X", desc.idVendor)) PID=0x\(String(format: "%04X", desc.idProduct))")
        print("   bcdUSB: 0x\(String(format: "%04X", desc.bcdUSB))")
        print("   bDeviceClass: 0x\(String(format: "%02X", desc.bDeviceClass))")
        print("   bDeviceSubClass: 0x\(String(format: "%02X", desc.bDeviceSubClass))")
        print("   bDeviceProtocol: 0x\(String(format: "%02X", desc.bDeviceProtocol))")
        print("   bNumConfigurations: \(desc.bNumConfigurations)")
        print()

        // Open device for detailed descriptor reading
        var handle: OpaquePointer?
        let openResult = libusb_open(dev, &handle)
        guard openResult == LIBUSB_SUCCESS.rawValue, let devHandle = handle else {
            print("   ⚠️ Cannot open device (error \(openResult)), trying config descriptors from device...")

            // Try to get config descriptors without opening
            for cfgIdx in 0..<desc.bNumConfigurations {
                var configDesc: UnsafeMutablePointer<libusb_config_descriptor>?
                let cfgResult = libusb_get_config_descriptor(dev, UInt8(cfgIdx), &configDesc)
                guard cfgResult == LIBUSB_SUCCESS.rawValue, let cfg = configDesc else {
                    print("   ⚠️ Cannot read config \(cfgIdx)")
                    continue
                }

                print("   Configuration \(cfgIdx):")
                print("     bNumInterfaces: \(cfg.pointee.bNumInterfaces)")

                for ifaceIdx in 0..<Int(cfg.pointee.bNumInterfaces) {
                    let iface = cfg.pointee.interface.advanced(by: ifaceIdx).pointee
                    for altIdx in 0..<Int(iface.num_altsetting) {
                        let alt = iface.altsetting.advanced(by: altIdx).pointee

                        print()
                        print("     Interface \(ifaceIdx) AltSetting \(altIdx):")
                        print("       bInterfaceClass: 0x\(String(format: "%02X", alt.bInterfaceClass))",
                              alt.bInterfaceClass == USB_CLASS_VIDEO ? "(VIDEO)" : "")
                        print("       bInterfaceSubClass: 0x\(String(format: "%02X", alt.bInterfaceSubClass))",
                              alt.bInterfaceClass == USB_CLASS_VIDEO && alt.bInterfaceSubClass == 0x01 ? "(VIDEO_CONTROL)" :
                              alt.bInterfaceClass == USB_CLASS_VIDEO && alt.bInterfaceSubClass == 0x02 ? "(VIDEO_STREAMING)" : "")
                        print("       bInterfaceProtocol: 0x\(String(format: "%02X", alt.bInterfaceProtocol))")
                        print("       bNumEndpoints: \(alt.bNumEndpoints)")

                        // Print endpoint info
                        for epIdx in 0..<Int(alt.bNumEndpoints) {
                            let ep = alt.endpoint.advanced(by: epIdx).pointee
                            let epType = ep.bmAttributes & 0x03
                            let epTypeStr = epType == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS ? "ISOCHRONOUS" :
                                           epType == LIBUSB_TRANSFER_TYPE_BULK ? "BULK" :
                                           epType == 0x03 ? "INTERRUPT" : "CONTROL"

                            print("       Endpoint 0x\(String(format: "%02X", ep.bEndpointAddress)):")
                            print("         Type: \(epTypeStr) (0x\(String(format: "%02X", epType)))")
                            print("         MaxPacketSize: \(ep.wMaxPacketSize)")
                        }

                        // Parse extra descriptors (UVC descriptors are in extra)
                        if alt.bInterfaceClass == USB_CLASS_VIDEO {
                            print("       --- UVC Descriptors ---")
                            if let extra = alt.extra, alt.extra_length > 0 {
                                let extraBytes = Data(bytes: extra, count: Int(alt.extra_length))
                                var offset = 0
                                while offset < extraBytes.count {
                                    guard offset + 2 <= extraBytes.count else { break }
                                    let len = Int(extraBytes[offset])
                                    let type = extraBytes[offset + 1]

                                    guard len > 0 && offset + len <= extraBytes.count else { break }

                                    let descBytes = Array(extraBytes[offset..<(offset + len)])

                                    if type == CS_INTERFACE {
                                        guard descBytes.count > 2 else { offset += len; continue }
                                        let subtype = descBytes[2]

                                        switch subtype {
                                        case VC_HEADER:
                                            print("       VC_HEADER (len=\(len))")
                                        case VC_INPUT_TERMINAL:
                                            if descBytes.count >= 5 {
                                                let termType = UInt16(descBytes[4]) | (UInt16(descBytes[5]) << 8)
                                                let termTypeStr = termType == 0x0201 ? "ITT_CAMERA" :
                                                                 termType == 0x0402 ? "ITT_MEDIA_TRANSPORT_INPUT" :
                                                                 "0x\(String(format: "%04X", termType))"
                                                print("       VC_INPUT_TERMINAL: type=\(termTypeStr)")
                                            }
                                        case VC_OUTPUT_TERMINAL:
                                            if descBytes.count >= 5 {
                                                let termType = UInt16(descBytes[4]) | (UInt16(descBytes[5]) << 8)
                                                let termTypeStr = termType == 0x0301 ? "OTT_DISPLAY" :
                                                                 termType == 0x0401 ? "TT_STREAMING" :
                                                                 "0x\(String(format: "%04X", termType))"
                                                print("       VC_OUTPUT_TERMINAL: type=\(termTypeStr)")
                                            }
                                        case VC_PROCESSING_UNIT:
                                            print("       VC_PROCESSING_UNIT")
                                        default:
                                            print("       CS_INTERFACE subtype=0x\(String(format: "%02X", subtype))")
                                        }

                                    } else if type == CS_ENDPOINT {
                                        print("       CS_ENDPOINT")

                                    } else if alt.bInterfaceSubClass == 0x02 { // Video Streaming
                                        switch type {
                                        case VS_INPUT_HEADER:
                                            if descBytes.count >= 13 {
                                                let numFormats = descBytes[3]
                                                print("       VS_INPUT_HEADER: \(numFormats) format(s)")
                                            }
                                        case VS_FORMAT_UNCOMPRESSED:
                                            if descBytes.count >= 4 {
                                                let formatIndex = descBytes[3]
                                                print("       📦 VS_FORMAT_UNCOMPRESSED index=\(formatIndex)")
                                            }
                                        case VS_FRAME_UNCOMPRESSED:
                                            if descBytes.count >= 26 {
                                                let frameIndex = descBytes[3]
                                                let width = UInt32(descBytes[5]) | (UInt32(descBytes[6]) << 8) |
                                                           (UInt32(descBytes[7]) << 16) | (UInt32(descBytes[8]) << 24)
                                                let height = UInt32(descBytes[9]) | (UInt32(descBytes[10]) << 8) |
                                                            (UInt32(descBytes[11]) << 16) | (UInt32(descBytes[12]) << 24)
                                                print("       🖼️ VS_FRAME_UNCOMPRESSED[\(frameIndex)]: \(width)x\(height)")
                                            }
                                        case VS_FORMAT_MJPEG:
                                            if descBytes.count >= 4 {
                                                let formatIndex = descBytes[3]
                                                print("       🎬 VS_FORMAT_MJPEG index=\(formatIndex)")
                                            }
                                        case VS_FRAME_MJPEG:
                                            if descBytes.count >= 26 {
                                                let frameIndex = descBytes[3]
                                                let width = UInt32(descBytes[5]) | (UInt32(descBytes[6]) << 8) |
                                                           (UInt32(descBytes[7]) << 16) | (UInt32(descBytes[8]) << 24)
                                                let height = UInt32(descBytes[9]) | (UInt32(descBytes[10]) << 8) |
                                                            (UInt32(descBytes[11]) << 16) | (UInt32(descBytes[12]) << 24)

                                                // Parse frame intervals
                                                let intervalType = descBytes[25]
                                                if intervalType == 0 {
                                                    // Continuous
                                                    if descBytes.count >= 38 {
                                                        let minInterval = UInt32(descBytes[26]) | (UInt32(descBytes[27]) << 8) |
                                                                         (UInt32(descBytes[28]) << 16) | (UInt32(descBytes[29]) << 24)
                                                        let maxInterval = UInt32(descBytes[30]) | (UInt32(descBytes[31]) << 8) |
                                                                         (UInt32(descBytes[32]) << 16) | (UInt32(descBytes[33]) << 24)
                                                        let minFps = minInterval > 0 ? 10000000.0 / Double(minInterval) : 0
                                                        let maxFps = maxInterval > 0 ? 10000000.0 / Double(maxInterval) : 0
                                                        print("       🎞️ VS_FRAME_MJPEG[\(frameIndex)]: \(width)x\(height) @ \(String(format: "%.1f", maxFps))-\(String(format: "%.1f", minFps))fps (continuous)")
                                                    }
                                                } else {
                                                    // Discrete
                                                    var intervals: [Double] = []
                                                    for j in 0..<Int(intervalType) {
                                                        let base = 26 + j * 4
                                                        if descBytes.count >= base + 4 {
                                                            let interval = UInt32(descBytes[base]) | (UInt32(descBytes[base+1]) << 8) |
                                                                          (UInt32(descBytes[base+2]) << 16) | (UInt32(descBytes[base+3]) << 24)
                                                            let fps = interval > 0 ? 10000000.0 / Double(interval) : 0
                                                            intervals.append(fps)
                                                        }
                                                    }
                                                    let fpsStr = intervals.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                                                    print("       🎞️ VS_FRAME_MJPEG[\(frameIndex)]: \(width)x\(height) @ [\(fpsStr)]fps (discrete)")
                                                }
                                            }
                                        default:
                                            print("       VS descriptor type=0x\(String(format: "%02X", type))")
                                        }
                                    }

                                    offset += len
                                }
                            } else {
                                print("       (no extra descriptors)")
                            }
                        }
                    }
                }

                libusb_free_config_descriptor(cfg)
            }
            continue
        }

        print("   Device opened successfully")
        libusb_close(devHandle)

        // Also try config descriptors
        for cfgIdx in 0..<desc.bNumConfigurations {
            var configDesc: UnsafeMutablePointer<libusb_config_descriptor>?
            let cfgResult = libusb_get_config_descriptor(dev, UInt8(cfgIdx), &configDesc)
            guard cfgResult == LIBUSB_SUCCESS.rawValue, let cfg = configDesc else {
                print("   ⚠️ Cannot read config \(cfgIdx)")
                continue
            }

            print("   Configuration \(cfgIdx):")
            print("     bNumInterfaces: \(cfg.pointee.bNumInterfaces)")

            for ifaceIdx in 0..<Int(cfg.pointee.bNumInterfaces) {
                let iface = cfg.pointee.interface.advanced(by: ifaceIdx).pointee
                for altIdx in 0..<Int(iface.num_altsetting) {
                    let alt = iface.altsetting.advanced(by: altIdx).pointee

                    print()
                    print("     Interface \(ifaceIdx) AltSetting \(altIdx):")
                    print("       bInterfaceClass: 0x\(String(format: "%02X", alt.bInterfaceClass))",
                          alt.bInterfaceClass == USB_CLASS_VIDEO ? "(VIDEO)" : "")
                    print("       bInterfaceSubClass: 0x\(String(format: "%02X", alt.bInterfaceSubClass))",
                          alt.bInterfaceClass == USB_CLASS_VIDEO && alt.bInterfaceSubClass == 0x01 ? "(VIDEO_CONTROL)" :
                          alt.bInterfaceClass == USB_CLASS_VIDEO && alt.bInterfaceSubClass == 0x02 ? "(VIDEO_STREAMING)" : "")
                    print("       bInterfaceProtocol: 0x\(String(format: "%02X", alt.bInterfaceProtocol))")
                    print("       bNumEndpoints: \(alt.bNumEndpoints)")

                    // Print endpoint info
                    for epIdx in 0..<Int(alt.bNumEndpoints) {
                        let ep = alt.endpoint.advanced(by: epIdx).pointee
                        let epType = ep.bmAttributes & 0x03
                        let epTypeStr = epType == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS ? "ISOCHRONOUS" :
                                       epType == LIBUSB_TRANSFER_TYPE_BULK ? "BULK" :
                                       epType == 0x03 ? "INTERRUPT" : "CONTROL"

                        print("       Endpoint 0x\(String(format: "%02X", ep.bEndpointAddress)):")
                        print("         Type: \(epTypeStr) (0x\(String(format: "%02X", epType)))")
                        print("         MaxPacketSize: \(ep.wMaxPacketSize)")
                    }

                    // Parse extra descriptors
                    if alt.bInterfaceClass == USB_CLASS_VIDEO {
                        print("       --- UVC Descriptors ---")
                        if let extra = alt.extra, alt.extra_length > 0 {
                            let extraBytes = Data(bytes: extra, count: Int(alt.extra_length))
                            var offset = 0
                            while offset < extraBytes.count {
                                guard offset + 2 <= extraBytes.count else { break }
                                let len = Int(extraBytes[offset])
                                let type = extraBytes[offset + 1]

                                guard len > 0 && offset + len <= extraBytes.count else { break }

                                let descBytes = Array(extraBytes[offset..<(offset + len)])

                                if type == CS_INTERFACE {
                                    guard descBytes.count > 2 else { offset += len; continue }
                                    let subtype = descBytes[2]

                                    switch subtype {
                                    case VC_HEADER:
                                        print("       VC_HEADER (len=\(len))")
                                    case VC_INPUT_TERMINAL:
                                        if descBytes.count >= 5 {
                                            let termType = UInt16(descBytes[4]) | (UInt16(descBytes[5]) << 8)
                                            let termTypeStr = termType == 0x0201 ? "ITT_CAMERA" :
                                                             termType == 0x0402 ? "ITT_MEDIA_TRANSPORT_INPUT" :
                                                             "0x\(String(format: "%04X", termType))"
                                            print("       VC_INPUT_TERMINAL: type=\(termTypeStr)")
                                        }
                                    case VC_OUTPUT_TERMINAL:
                                        if descBytes.count >= 5 {
                                            let termType = UInt16(descBytes[4]) | (UInt16(descBytes[5]) << 8)
                                            let termTypeStr = termType == 0x0301 ? "OTT_DISPLAY" :
                                                             termType == 0x0401 ? "TT_STREAMING" :
                                                             "0x\(String(format: "%04X", termType))"
                                            print("       VC_OUTPUT_TERMINAL: type=\(termTypeStr)")
                                        }
                                    case VC_PROCESSING_UNIT:
                                        print("       VC_PROCESSING_UNIT")
                                    default:
                                        print("       CS_INTERFACE subtype=0x\(String(format: "%02X", subtype))")
                                    }

                                } else if alt.bInterfaceSubClass == 0x02 { // Video Streaming
                                    switch type {
                                    case VS_INPUT_HEADER:
                                        if descBytes.count >= 13 {
                                            let numFormats = descBytes[3]
                                            print("       VS_INPUT_HEADER: \(numFormats) format(s)")
                                        }
                                    case VS_FORMAT_UNCOMPRESSED:
                                        if descBytes.count >= 4 {
                                            let formatIndex = descBytes[3]
                                            print("       📦 VS_FORMAT_UNCOMPRESSED index=\(formatIndex)")
                                        }
                                    case VS_FRAME_UNCOMPRESSED:
                                        if descBytes.count >= 26 {
                                            let frameIndex = descBytes[3]
                                            let width = UInt32(descBytes[5]) | (UInt32(descBytes[6]) << 8) |
                                                       (UInt32(descBytes[7]) << 16) | (UInt32(descBytes[8]) << 24)
                                            let height = UInt32(descBytes[9]) | (UInt32(descBytes[10]) << 8) |
                                                        (UInt32(descBytes[11]) << 16) | (UInt32(descBytes[12]) << 24)
                                            print("       🖼️ VS_FRAME_UNCOMPRESSED[\(frameIndex)]: \(width)x\(height)")
                                        }
                                    case VS_FORMAT_MJPEG:
                                        if descBytes.count >= 4 {
                                            let formatIndex = descBytes[3]
                                            print("       🎬 VS_FORMAT_MJPEG index=\(formatIndex)")
                                        }
                                    case VS_FRAME_MJPEG:
                                        if descBytes.count >= 26 {
                                            let frameIndex = descBytes[3]
                                            let width = UInt32(descBytes[5]) | (UInt32(descBytes[6]) << 8) |
                                                       (UInt32(descBytes[7]) << 16) | (UInt32(descBytes[8]) << 24)
                                            let height = UInt32(descBytes[9]) | (UInt32(descBytes[10]) << 8) |
                                                        (UInt32(descBytes[11]) << 16) | (UInt32(descBytes[12]) << 24)

                                            let intervalType = descBytes[25]
                                            if intervalType == 0 {
                                                if descBytes.count >= 38 {
                                                    let minInterval = UInt32(descBytes[26]) | (UInt32(descBytes[27]) << 8) |
                                                                     (UInt32(descBytes[28]) << 16) | (UInt32(descBytes[29]) << 24)
                                                    let maxInterval = UInt32(descBytes[30]) | (UInt32(descBytes[31]) << 8) |
                                                                     (UInt32(descBytes[32]) << 16) | (UInt32(descBytes[33]) << 24)
                                                    let minFps = minInterval > 0 ? 10000000.0 / Double(minInterval) : 0
                                                    let maxFps = maxInterval > 0 ? 10000000.0 / Double(maxInterval) : 0
                                                    print("       🎞️ VS_FRAME_MJPEG[\(frameIndex)]: \(width)x\(height) @ \(String(format: "%.1f", maxFps))-\(String(format: "%.1f", minFps))fps (continuous)")
                                                }
                                            } else {
                                                var intervals: [Double] = []
                                                for j in 0..<Int(intervalType) {
                                                    let base = 26 + j * 4
                                                    if descBytes.count >= base + 4 {
                                                        let interval = UInt32(descBytes[base]) | (UInt32(descBytes[base+1]) << 8) |
                                                                      (UInt32(descBytes[base+2]) << 16) | (UInt32(descBytes[base+3]) << 24)
                                                        let fps = interval > 0 ? 10000000.0 / Double(interval) : 0
                                                        intervals.append(fps)
                                                    }
                                                }
                                                let fpsStr = intervals.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                                                print("       🎞️ VS_FRAME_MJPEG[\(frameIndex)]: \(width)x\(height) @ [\(fpsStr)]fps (discrete)")
                                            }
                                        }
                                    default:
                                        print("       VS descriptor type=0x\(String(format: "%02X", type))")
                                    }
                                }

                                offset += len
                            }
                        } else {
                            print("       (no extra descriptors)")
                        }
                    }
                }
            }

            libusb_free_config_descriptor(cfg)
        }
    }
}

print()
print("=== Probe Complete ===")
