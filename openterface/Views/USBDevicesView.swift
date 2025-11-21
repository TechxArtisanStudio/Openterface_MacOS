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

// MARK: - Tree Node Structure
struct TreeNode: Identifiable {
    let id: String
    let title: String
    let value: String?
    var children: [TreeNode]?
    let isExpandable: Bool
    let device: USBDeviceInfo?
    let nodeType: NodeType
    
    enum NodeType {
        case root
        case hub
        case device
        case property
    }
    
    init(title: String, value: String? = nil, children: [TreeNode]? = nil, device: USBDeviceInfo? = nil, nodeType: NodeType = .property) {
        self.title = title
        self.value = value
        self.children = children
        self.device = device
        self.nodeType = nodeType
        self.isExpandable = children != nil && !children!.isEmpty
        
        // Create a stable ID based on title, value, and device info
        if let device = device {
            self.id = "device_\(device.locationID)_\(device.productName)_\(device.vendorID)_\(device.productID)"
        } else if let value = value {
            self.id = "property_\(title)_\(value)"
        } else {
            self.id = "node_\(title)_\(nodeType)"
        }
    }
}

// MARK: - USB Hub Structure
struct USBHub: Identifiable {
    let id: String
    let name: String
    let locationPrefix: String
    var devices: [USBDeviceInfo] = []
    var subHubs: [USBHub] = []
    
    init(id: String, name: String, locationPrefix: String) {
        self.id = id
        self.name = name
        self.locationPrefix = locationPrefix
    }
}

struct USBDevicesView: View {
    @State private var expandedNodes: Set<String> = []
    @State private var selectedNode: TreeNode? = nil
    @State private var availableControlChipsets: [(chipset: ControlChipsetProtocol, type: ControlChipsetType)] = []
    
    // Helper function to convert integers to hexadecimal strings
    func hexString(from value: Int) -> String {
        return String(format: "0x%04X", value)
    }
    
    // Load available control chipsets
    private func loadAvailableControlChipsets() {
        let hal = HardwareAbstractionLayer.shared
        availableControlChipsets = hal.getAvailableControlChipsets()
    }
    
    // Select a control chipset
    private func selectControlChipset(_ chipset: ControlChipsetProtocol, type: ControlChipsetType) {
        AppStatus.controlChipsetType = type
        let hal = HardwareAbstractionLayer.shared
        if hal.selectControlChipset(chipset, type: type) {
            // Successfully selected, refresh the available chipsets list
            loadAvailableControlChipsets()
            
            // Trigger serial port reconnection with the new chipset
            let serialManager = SerialPortManager.shared
            
            // Close any existing connection
            serialManager.closeSerialPort()
            
            // Reset connection state and attempt to reconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                serialManager.tryConnectOpenterface()
                
                // Force UI refresh by triggering a state update
                // This will update the serial port display in the tree
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Re-update USB devices to refresh serial port information in the display
                    USBDevicesManager.shared.update()
                }
            }
        }
    }
    
    // Get display name for chipset type
    private func getControlChipsetDisplayName(_ type: ControlChipsetType) -> String {
        switch type {
        case .ch9329:
            return "CH9329"
        case .ch32v208:
            return "CH32V208"
        case .unknown:
            return "Unknown"
        }
    }
    
    // Copy entire USB tree information to clipboard
    private func copyUSBTreeInfo() {
        var treeInfo = "USB Device Tree Information\n"
        treeInfo += String(repeating: "=", count: 50) + "\n\n"
        
        let treeNodes = createUSBDevicesTree()
        for (index, node) in treeNodes.enumerated() {
            let isLast = index == treeNodes.count - 1
            treeInfo += formatNodeInfo(node, level: 0, isLast: isLast)
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(treeInfo, forType: .string)
    }
    
    // Format node information recursively with tree structure
    private func formatNodeInfo(_ node: TreeNode, level: Int, isLast: Bool = true, parentPrefix: String = "") -> String {
        var info = ""
        
        // Special handling for Video Device and Keyboard Mouse Device - format as plain text
        if (node.title == "Video Device" || node.title == "Keyboard Mouse Device") && level == 0 {
            info += "\(node.title)\n"
            info += String(repeating: "-", count: node.title.count) + "\n"
            
            if let children = node.children {
                for child in children {
                    if let value = child.value {
                        info += "\(child.title): \(value)\n"
                    }
                }
            } else if let value = node.value {
                info += "\(value)\n"
            }
            
            info += "\n"
            return info
        }
        
        // Determine the icon based on node type
        let icon: String
        switch node.nodeType {
        case .root:
            icon = "📁"
        case .hub:
            icon = "🔌"
        case .device:
            icon = "💾"
        case .property:
            icon = "📄"
        }
        
        // Create the tree structure prefix
        let currentPrefix = parentPrefix + (isLast ? "└── " : "├── ")
        let childPrefix = parentPrefix + (isLast ? "    " : "│   ")
        
        // Format the current node
        if level == 0 {
            info += "\(icon) \(node.title)\n"
        } else {
            info += "\(currentPrefix)\(icon) \(node.title)\n"
        }
        
        // Add device details if available (indented properly)
        if let device = node.device {
            let detailPrefix = level == 0 ? "  " : childPrefix + "  "
            info += "\(detailPrefix)Product Name: \(device.productName)\n"
            info += "\(detailPrefix)Manufacturer: \(device.manufacturer)\n"
            info += "\(detailPrefix)Vendor ID: \(hexString(from: device.vendorID))\n"
            info += "\(detailPrefix)Product ID: \(hexString(from: device.productID))\n"
            info += "\(detailPrefix)Location ID: \(device.locationID)\n"
            info += "\(detailPrefix)Speed: \(device.speed)\n"
        }
        
        // Add value if available
        if let value = node.value {
            let detailPrefix = level == 0 ? "  " : childPrefix + "  "
            info += "\(detailPrefix)Value: \(value)\n"
        }
        
        // Process children
        if let children = node.children {
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                let nextParentPrefix = level == 0 ? "" : childPrefix
                info += formatNodeInfo(child, level: level + 1, isLast: isLastChild, parentPrefix: nextParentPrefix)
            }
        }
        
        // Add spacing after root level nodes
        if level == 0 {
            info += "\n"
        }
        
        return info
    }
    
    // Parse location ID to extract hub hierarchy
    func parseLocationID(_ locationID: String) -> [String] {
        // Remove "0x" prefix and convert to integer
        let cleanID = locationID.replacingOccurrences(of: "0x", with: "")
        guard let locationValue = UInt32(cleanID, radix: 16) else { return [] }
        
        var hierarchy: [String] = []
        
        // Extract nibbles from most significant to least significant
        // Each nibble represents a port number at that level
        // We need to process from left to right (MSB to LSB)
        for shift in stride(from: 28, through: 0, by: -4) {
            let nibble = (locationValue >> shift) & 0xF
            if nibble > 0 {
                hierarchy.append(String(format: "%X", nibble))
            }
        }
        
        return hierarchy
    }
    
    // Build hierarchical USB tree with proper parent-child relationships
    func buildUSBHierarchy() -> TreeNode? {
        // Group devices by their location hierarchy and create all path levels
        var devicesByPath: [String: [USBDeviceInfo]] = [:]
        var allPaths: Set<String> = []
        
        for device in AppStatus.USBDevices {
            let hierarchy = parseLocationID(device.locationID)
            
            if hierarchy.isEmpty {
                // Root level device
                let path = "root"
                devicesByPath[path, default: []].append(device)
                allPaths.insert(path)
            } else {
                // Build all possible parent paths and add them to allPaths
                for i in 1...hierarchy.count {
                    let path = Array(hierarchy.prefix(i)).joined(separator: ".")
                    allPaths.insert(path)
                }
                
                // Add device to its exact path
                let fullPath = hierarchy.joined(separator: ".")
                devicesByPath[fullPath, default: []].append(device)
            }
        }
        
        // Build tree recursively
        func buildNode(path: String, level: Int) -> TreeNode? {
            let pathComponents = path == "root" ? [] : path.components(separatedBy: ".")
            let devices = devicesByPath[path] ?? []
            
            // Find immediate child paths (exactly one level deeper)
            let childPaths = allPaths.filter { childPath in
                if childPath == path { return false }
                
                let childComponents = childPath == "root" ? [] : childPath.components(separatedBy: ".")
                
                // Must be exactly one level deeper
                if childComponents.count != pathComponents.count + 1 {
                    return false
                }
                
                // Must be a child of current path
                if path == "root" {
                    return childComponents.count == 1
                } else {
                    return childPath.hasPrefix(path + ".")
                }
            }.sorted()
            
            // Create child hub nodes first
            let childNodes = childPaths.compactMap { childPath in
                buildNode(path: childPath, level: level + 1)
            }
            
            // Create device nodes
            let deviceNodes = devices.map { device in
                // For leaf devices, add port information to the title
                let deviceTitle: String
                if childNodes.isEmpty && !pathComponents.isEmpty {
                    let lastComponent = pathComponents.last ?? ""
                    deviceTitle = "\(device.productName) (Port \(lastComponent))"
                } else {
                    deviceTitle = device.productName
                }
                
                return TreeNode(
                    title: deviceTitle,
                    children: nil, // Remove device details from tree, will show in bottom panel
                    device: device,
                    nodeType: .device
                )
            }
            
            // OPTIMIZATION: Merge hub devices with their port nodes
            // If this node has exactly one hub device and has child nodes,
            // we can merge the hub device with the port to simplify the hierarchy
            if devices.count == 1 && !childNodes.isEmpty {
                let device = devices[0]
                let productName = device.productName.lowercased()
                let isHub = productName.contains("hub") || 
                           productName.contains("controller") ||
                           productName.contains("usb2") ||
                           productName.contains("usb3") ||
                           productName.contains("gen2")
                
                if isHub {
                    // Determine the merged node name - Hub name first, then port info
                    let nodeName: String
                    if path == "root" {
                        nodeName = device.productName
                    } else {
                        let lastComponent = pathComponents.last ?? ""
                        // Format: "Hub Name (Port X)"
                        nodeName = "\(device.productName) (Port \(lastComponent))"
                    }
                    
                    // Count total devices including children
                    let totalDeviceCount = childNodes.reduce(0) { total, child in
                        return total + countDevicesInNode(child)
                    }
                    
                    let title = "\(nodeName) - \(totalDeviceCount) devices"
                    
                    return TreeNode(
                        title: title,
                        children: childNodes,
                        device: device,
                        nodeType: .hub
                    )
                }
            }
            
            // MERGE LOGIC: Handle various merge scenarios to simplify the hierarchy
            
            // Scenario 1: Empty port with single hub child
            if devices.isEmpty && childNodes.count == 1 {
                let childNode = childNodes[0]
                
                // Check if the child is a hub device
                if let childDevice = childNode.device {
                    let productName = childDevice.productName.lowercased()
                    let isHub = productName.contains("hub") || 
                               productName.contains("controller") ||
                               productName.contains("usb2") ||
                               productName.contains("usb3") ||
                               productName.contains("gen2")
                    
                    if isHub {
                        // Determine the merged node name - Hub name first, then port info
                        let nodeName: String
                        if path == "root" {
                            nodeName = childDevice.productName
                        } else {
                            let lastComponent = pathComponents.last ?? ""
                            // Format: "Hub Name (Port X)"
                            nodeName = "\(childDevice.productName) (Port \(lastComponent))"
                        }
                        
                        // Return merged node with child's children
                        let totalDeviceCount = countDevicesInNode(childNode)
                        let title = "\(nodeName) - \(totalDeviceCount) devices"
                        
                        return TreeNode(
                            title: title,
                            children: childNode.children,
                            device: childDevice,
                            nodeType: .hub
                        )
                    }
                }
            }
            
            // Scenario 2: Port with only device children (no hub children) - merge into single device node
            if deviceNodes.count == 1 && childNodes.isEmpty && !pathComponents.isEmpty {
                let device = devices[0]
                let lastComponent = pathComponents.last ?? ""
                
                // Create a single device node that represents both the port and the device
                return TreeNode(
                    title: "\(device.productName) (Port \(lastComponent))",
                    children: nil,
                    device: device,
                    nodeType: .device
                )
            }
            
            // Combine device nodes and child nodes
            let allChildren = deviceNodes + childNodes
            
            // Don't create a node if there are no devices and no children
            if devices.isEmpty && childNodes.isEmpty {
                return nil
            }
            
            // Determine node name
            let nodeName: String
            if path == "root" {
                nodeName = "USB Root Hub"
            } else {
                let lastComponent = pathComponents.last ?? ""
                if pathComponents.count == 1 {
                    nodeName = "USB Hub \(lastComponent)"
                } else {
                    nodeName = "Port \(lastComponent)"
                }
            }
            
            let deviceCount = devices.count
            let totalDeviceCount = deviceCount + childNodes.reduce(0) { total, child in
                // Count devices in child nodes recursively
                return total + countDevicesInNode(child)
            }
            
            let title = "\(nodeName) (\(totalDeviceCount) devices)"
            
            return TreeNode(
                title: title,
                children: allChildren.isEmpty ? nil : allChildren,
                nodeType: path == "root" ? .root : .hub
            )
        }
        
        // Helper function to count devices in a tree node recursively
        func countDevicesInNode(_ node: TreeNode) -> Int {
            var count = 0
            if node.nodeType == .device {
                count = 1
            }
            if let children = node.children {
                count += children.reduce(0) { total, child in
                    return total + countDevicesInNode(child)
                }
            }
            return count
        }
        
        // Start building from root
        return buildNode(path: "root", level: 0)
    }
    
    // Convert USB hierarchy to tree nodes
    func createUSBTopologyTree() -> [TreeNode] {
        guard let rootNode = buildUSBHierarchy() else { return [] }
        return rootNode.children ?? [rootNode]
    }
    
    // Create tree structure for USB devices
    func createUSBDevicesTree() -> [TreeNode] {
        var treeNodes: [TreeNode] = []
        
        // USB Topology section (NEW)
        let topologyNodes = createUSBTopologyTree()
        if !topologyNodes.isEmpty {
            let topologyRoot = TreeNode(
                title: "USB Device Topology",
                children: topologyNodes,
                nodeType: .root
            )
            treeNodes.append(topologyRoot)
        }
        
        // Default Video Device section
        if let defaultDevice = AppStatus.DefaultVideoDevice {
            let defaultVideoChildren = [
                TreeNode(title: "Product Name", value: defaultDevice.productName),
                TreeNode(title: "Manufacturer", value: defaultDevice.manufacturer),
                TreeNode(title: "Vendor ID", value: hexString(from: defaultDevice.vendorID)),
                TreeNode(title: "Product ID", value: hexString(from: defaultDevice.productID)),
                TreeNode(title: "Location ID", value: defaultDevice.locationID),
                TreeNode(title: "Speed", value: defaultDevice.speed),
                TreeNode(title: "Is Match Video", value: String(AppStatus.isMatchVideoDevice))
            ]
            let defaultVideoNode = TreeNode(
                title: "Video Device",
                children: defaultVideoChildren,
                nodeType: .root
            )
            treeNodes.append(defaultVideoNode)
        } else {
            let noDeviceNode = TreeNode(
                title: "Default Video Device",
                value: "No device found",
                nodeType: .root
            )
            treeNodes.append(noDeviceNode)
        }
        
        // Keyboard Mouse Device section (Serial Device)
        if let serialDevice = AppStatus.DefaultUSBSerial {
            let serialDeviceChildren = [
                TreeNode(title: "Product Name", value: serialDevice.productName),
                TreeNode(title: "Manufacturer", value: serialDevice.manufacturer),
                TreeNode(title: "Vendor ID", value: hexString(from: serialDevice.vendorID)),
                TreeNode(title: "Product ID", value: hexString(from: serialDevice.productID)),
                TreeNode(title: "Location ID", value: serialDevice.locationID),
                TreeNode(title: "Speed", value: serialDevice.speed),
                TreeNode(title: "Serial Port Name", value: AppStatus.serialPortName),
                TreeNode(title: "Baud Rate", value: String(AppStatus.serialPortBaudRate))
            ]
            let keyboardMouseNode = TreeNode(
                title: "Keyboard Mouse Device",
                children: serialDeviceChildren,
                device: serialDevice,
                nodeType: .root
            )
            treeNodes.append(keyboardMouseNode)
        } else {
            let noSerialNode = TreeNode(
                title: "Keyboard Mouse Device",
                value: "No serial device found",
                nodeType: .root
            )
            treeNodes.append(noSerialNode)
        }
        
        return treeNodes
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top panel - Tree view with copy button
            VStack(alignment: .leading, spacing: 0) {
                // Header with copy button
                HStack {
                    Text("USB Device Tree")
                        .font(.headline)
                        .padding(.leading)
                    
                    Spacer()
                    
                    Button(action: copyUSBTreeInfo) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Copy entire USB tree information")
                    .padding(.trailing)
                }
                .padding(.top)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(createUSBDevicesTree()) { node in
                            TreeNodeView(
                                node: node,
                                level: 0,
                                expandedNodes: $expandedNodes,
                                selectedNode: $selectedNode
                            )
                        }
                    }
                    .padding()
                }
            }
            .frame(minHeight: 300)
            
            // Divider
            Divider()
            
            // Middle panel - Control Chipset Selection
            if !availableControlChipsets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Control Chipset Selection")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(availableControlChipsets, id: \.type) { item in
                                let chipsetType = item.type
                                let isSelected = AppStatus.controlChipsetType == chipsetType
                                
                                Button(action: {
                                    selectControlChipset(item.chipset, type: item.type)
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(isSelected ? .green : .secondary)
                                        
                                        Text(getControlChipsetDisplayName(chipsetType))
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(isSelected ? .primary : .secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.green.opacity(0.1) : Color(.controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(isSelected ? Color.green.opacity(0.5) : Color(.separatorColor), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Click to select \(getControlChipsetDisplayName(chipsetType)) chipset")
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 50)
                }
                .padding(.vertical, 8)
                
                // Divider
                Divider()
            }
            
            // Bottom panel - Details view
            VStack(alignment: .leading, spacing: 12) {
                Text("Device Details")
                    .font(.headline)
                    .padding(.horizontal)
                
                if let selectedNode = selectedNode {
                    DeviceDetailsView(node: selectedNode, hexString: hexString)
                        .padding(.horizontal)
                } else {
                    VStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Select a device to view details")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Spacer()
            }
            .frame(minHeight: 200)
            .padding(.bottom)
        }
        .onAppear {
            loadAvailableControlChipsets()
        }
    }
}

// MARK: - Device Details View
struct DeviceDetailsView: View {
    let node: TreeNode
    let hexString: (Int) -> String
    
    // Copy device information to clipboard
    private func copyDeviceInfo() {
        var info = "Device: \(node.title)\n"
        info += "Type: \(node.nodeType == .device ? "USB Device" : "USB Hub")\n"
        
        if let device = node.device {
            info += "Product Name: \(device.productName)\n"
            info += "Manufacturer: \(device.manufacturer)\n"
            info += "Vendor ID: \(hexString(device.vendorID))\n"
            info += "Product ID: \(hexString(device.productID))\n"
            info += "Location ID: \(device.locationID)\n"
            info += "Speed: \(device.speed)\n"
        } else {
            info += "Node Type: \(node.nodeType == .root ? "Root Hub" : "Hub Container")\n"
            if let children = node.children {
                info += "Child Devices: \(children.count)\n"
            }
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Device name and type with copy button
            HStack {
                HStack {
                    Image(systemName: node.nodeType == .device ? "externaldrive.connected.to.line.below" : "network")
                        .font(.title2)
                        .foregroundColor(node.nodeType == .device ? .green : .orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Text(node.nodeType == .device ? "USB Device" : "USB Hub")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: copyDeviceInfo) {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy device information")
            }
            
            // Device information
            if let device = node.device {
                VStack(alignment: .leading, spacing: 8) {
                    SelectableDetailRow(label: "Product Name", value: device.productName)
                    SelectableDetailRow(label: "Manufacturer", value: device.manufacturer)
                    SelectableDetailRow(label: "Vendor ID", value: hexString(device.vendorID))
                    SelectableDetailRow(label: "Product ID", value: hexString(device.productID))
                    SelectableDetailRow(label: "Location ID", value: device.locationID)
                    SelectableDetailRow(label: "Speed", value: device.speed)
                }
            } else if node.nodeType == .root || node.nodeType == .hub {
                VStack(alignment: .leading, spacing: 8) {
                    SelectableDetailRow(label: "Node Type", value: node.nodeType == .root ? "Root Hub" : "Hub Container")
                    if let children = node.children {
                        SelectableDetailRow(label: "Child Devices", value: "\(children.count)")
                    }
                }
            } else {
                Text("No additional information available")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Detail Row Component
struct DetailRow: View {
    let label: String
    let value: String
    
    // Copy specific value to clipboard
    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 100, alignment: .leading)
            
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)
                
                Button(action: copyValue) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy \(label.lowercased())")
            }
            
            Spacer()
        }
    }
}

// MARK: - Selectable Detail Row Component (for Device Details)
struct SelectableDetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 100, alignment: .leading)
                .textSelection(.enabled)
            
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.textBackgroundColor))
                .cornerRadius(4)
                .textSelection(.enabled)
            
            Spacer()
        }
    }
}

// MARK: - Tree Node View
struct TreeNodeView: View {
    let node: TreeNode
    let level: Int
    @Binding var expandedNodes: Set<String>
    @Binding var selectedNode: TreeNode?
    
    private var isExpanded: Bool {
        expandedNodes.contains(node.id)
    }
    
    private var isSelected: Bool {
        selectedNode?.id == node.id
    }
    
    private var leadingPadding: CGFloat {
        CGFloat(level * 20)
    }
    
    private var nodeIcon: String {
        switch node.nodeType {
        case .root:
            return "folder"
        case .hub:
            return "network"
        case .device:
            return "externaldrive.connected.to.line.below"
        case .property:
            return ""
        }
    }
    
    private var nodeColor: Color {
        switch node.nodeType {
        case .root:
            return .blue
        case .hub:
            return .orange
        case .device:
            return .green
        case .property:
            return .secondary
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Node row
            HStack(spacing: 8) {
                // Indentation
                if level > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: leadingPadding, height: 1)
                }
                
                // Expand/collapse button or icon
                if node.isExpandable {
                    HStack(spacing: 4) {
                        Button(action: {
                            if isExpanded {
                                expandedNodes.remove(node.id)
                            } else {
                                expandedNodes.insert(node.id)
                            }
                        }) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if !nodeIcon.isEmpty {
                            Image(systemName: nodeIcon)
                                .font(.system(size: 14))
                                .foregroundColor(nodeColor)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        if level > 0 && node.nodeType == .property {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 4, height: 4)
                                .padding(.leading, 4)
                        } else if !nodeIcon.isEmpty {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 16, height: 1)
                            Image(systemName: nodeIcon)
                                .font(.system(size: 14))
                                .foregroundColor(nodeColor)
                        }
                    }
                }
                
                // Node content - Make clickable for selection
                HStack(spacing: 8) {
                    Button(action: {
                        selectedNode = node
                        
                        // Auto-expand nodes that have children when selected (especially useful for leaf containers)
                        if node.isExpandable && !isExpanded {
                            expandedNodes.insert(node.id)
                        }
                    }) {
                        HStack {
                            Text(node.title)
                                .font(.system(size: 14, weight: level == 0 ? .semibold : (node.nodeType == .device ? .medium : .regular)))
                                .foregroundColor(isSelected ? .white : (level == 0 ? .primary : (node.nodeType == .device ? .primary : .secondary)))
                            
                            if let value = node.value {
                                Spacer()
                                Text(value)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(isSelected ? Color.white.opacity(0.2) : Color(.controlBackgroundColor))
                                    .cornerRadius(4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        Rectangle()
                            .fill(isSelected ? Color.accentColor : (level == 0 ? Color(.controlBackgroundColor).opacity(0.5) : Color.clear))
                    )
                    .cornerRadius(6)
                }
                
                Spacer(minLength: 0)
            }
            
            // Children
            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    TreeNodeView(
                        node: child,
                        level: level + 1,
                        expandedNodes: $expandedNodes,
                        selectedNode: $selectedNode
                    )
                }
            }
        }
    }
}
