//
//  USBDevicesView.swift
//  openterface
//
//  Created by Shawn on 2024/11/12.
//

import SwiftUI

struct USBDevicesView: View {
    var body: some View {
        VStack {
            Text("USB Devices")
                .font(.headline)
            List(AppStatus.USBDevices, id: \.productName) { device in
                VStack(alignment: .leading) {
                    Text("Product Name: \(device.productName)")
                    Text("Vendor ID: \(device.vendorID)")
                    Text("Product ID: \(device.productID)")
                    Text("Location ID: \(device.locationID)")
                }
            }
            
            Text("Group Openterface Devices")
                .font(.headline)
            List(AppStatus.groupOpenterfaceDevices, id: \.first?.productName) { group in
                ForEach(group, id: \.productName) { device in
                    VStack(alignment: .leading) {
                        Text("Product Name: \(device.productName)")
                        Text("Vendor ID: \(device.vendorID)")
                        Text("Product ID: \(device.productID)")
                        Text("Location ID: \(device.locationID)")
                    }
                }
            }
            Text("DefaultVideoDevice")  
                .font(.headline)
            if let defaultDevice = AppStatus.DefaultVideoDevice {
                VStack(alignment: .leading) {
                    Text("Product Name: \(defaultDevice.productName)")
                    Text("Vendor ID: \(defaultDevice.vendorID)")
                    Text("Product ID: \(defaultDevice.productID)")
                    Text("Location ID: \(defaultDevice.locationID)")
                    Text("Is Match Video: \(String(AppStatus.isMatchVideoDevice))")
                }
            } else {
                Text("No Default Video Device")
            }
        }
        .padding()
    }
}
