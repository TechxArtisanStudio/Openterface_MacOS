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
        }
        .padding()
    }
} 