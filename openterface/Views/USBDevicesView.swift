/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/
import SwiftUI

struct USBDevicesView: View {
    // Helper function to convert integers to hexadecimal strings
    func hexString(from value: Int) -> String {
        return String(format: "%X", value)
    }

    var body: some View {
        VStack {
            List(AppStatus.USBDevices, id: \.productName) { device in
                VStack(alignment: .leading) {
                    Text("Product Name: \(device.productName)")
                    Text("Vendor ID: \(device.vendorID)")
                    Text("Product ID: \(hexString(from: Int(device.productID)))")
                    Text("Location ID: \(device.locationID)")
                }
            }
            
            Text("Group Openterface Devices")
                .font(.headline)
            List(AppStatus.groupOpenterfaceDevices, id: \.first?.productName) { group in
                ForEach(group, id: \.productName) { device in
                    VStack(alignment: .leading) {
                        Text("Product Name: \(device.productName)")
                        Text("Vendor ID: \(hexString(from: Int(device.vendorID)))")
                        Text("Product ID: \(hexString(from: Int(device.productID)))")
                        Text("Location ID: \(device.locationID)")
                    }
                }
            }
            Text("DefaultVideoDevice")  
                .font(.headline)
            if let defaultDevice = AppStatus.DefaultVideoDevice {
                VStack(alignment: .leading) {
                    Text("Product Name: \(defaultDevice.productName)")
                    Text("Vendor ID: \(hexString(from: Int(defaultDevice.vendorID)))")
                    Text("Product ID: \(hexString(from: Int(defaultDevice.productID) ?? 0))")
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
