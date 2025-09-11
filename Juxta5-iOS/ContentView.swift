//
//  ContentView.swift
//  Juxta5-iOS
//
//  Created by Matt Gaidica on 8/11/25.
//

import SwiftUI
import CoreBluetooth
import UniformTypeIdentifiers

// MARK: - BLE UUIDs
struct HublinkUUIDs {
    static let service = CBUUID(string: "57617368-5501-0001-8000-00805f9b34fb")
    static let filename = CBUUID(string: "57617368-5502-0001-8000-00805f9b34fb")
    static let fileTransfer = CBUUID(string: "57617368-5503-0001-8000-00805f9b34fb")
    static let gateway = CBUUID(string: "57617368-5504-0001-8000-00805f9b34fb")
    static let node = CBUUID(string: "57617368-5505-0001-8000-00805f9b34fb")
}

// MARK: - App State
class AppState: ObservableObject {
    // Removed deviceNameFilter since we're filtering by service
    @Published var isScanning = false
    @Published var isConnected = true
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var terminalLog: [String] = []
    @Published var connectionStatus = "Ready"
    @Published var requestFileName = ""
    @Published var availableFiles: [String] = []
    @Published var receivedFileContent = ""
    @Published var showClearMemoryAlert = false
    @Published var showShelfModeAlert = false
    @Published var showShareSheet = false
    @Published var showOperatingModeWarning = false
    @Published var currentTime = ""
    @Published var operatingModeSet = false
    @Published var selectedOperatingMode: Int? = nil
    @Published var showSettingsSheet = false
    
    // Social Mode Settings (Mode 0)
    @Published var advInterval = 5
    @Published var scanInterval = 20
    
    // Electric Mode Settings (Mode 1) - ADC Configuration
    @Published var adcMode = 0
    @Published var adcThreshold = 100
    @Published var adcBufferSize = 1000
    @Published var adcDebounce = 5000
    @Published var adcPeaksOnly = false
    @Published var samplingRate = 10000 // 10kHz default
    
    private var clearDevicesTimer: Timer?
    private var clockTimer: Timer?
    
    func log(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        terminalLog.append("[\(timestamp)] \(message)")
        if terminalLog.count > 1000 {
            terminalLog.removeFirst(100)
        }
    }
    
    func clearLog() {
        terminalLog.removeAll()
    }
    
    func scheduleClearDevices() {
        // Cancel existing timer
        clearDevicesTimer?.invalidate()
        
        // Schedule new timer to clear devices after 30 seconds
        clearDevicesTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.discoveredDevices.removeAll()
            }
        }
        RunLoop.main.add(clearDevicesTimer!, forMode: .common)
    }
    
    func cancelClearDevices() {
        clearDevicesTimer?.invalidate()
        clearDevicesTimer = nil
    }
    
    func createShareableFile() -> URL? {
        guard !receivedFileContent.isEmpty else { return nil }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let requestedFilename = requestFileName.isEmpty ? "unknown" : requestFileName
        let filename = "juxta5_file_content_\(timestamp)_\(requestedFilename).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            try receivedFileContent.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            log("ERROR: Failed to create shareable file - \(error.localizedDescription)")
            return nil
        }
    }
    
    func startClock() {
        updateTime()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateTime()
        }
    }
    
    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }
    
    private func updateTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yy - HH:mm:ss"
        currentTime = formatter.string(from: Date())
    }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject {
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var filenameCharacteristic: CBCharacteristic?
    private var fileTransferCharacteristic: CBCharacteristic?
    private var gatewayCharacteristic: CBCharacteristic?
    private var nodeCharacteristic: CBCharacteristic?
    
    @Published var appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard let centralManager = centralManager,
              centralManager.state == .poweredOn else {
            appState.log("ERROR: Bluetooth not available - State: \(centralManager?.state.rawValue ?? -1)")
            return
        }
        
        appState.isScanning = true
        appState.discoveredDevices.removeAll()
        appState.cancelClearDevices() // Cancel any pending clear timer
        appState.log("Starting BLE scan for service: \(HublinkUUIDs.service.uuidString)")
        
        centralManager.scanForPeripherals(
            withServices: [HublinkUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        
        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.stopScanning()
        }
    }
    
    func stopScanning() {
        centralManager?.stopScan()
        appState.isScanning = false
        appState.log("Scan stopped")
        appState.scheduleClearDevices()
    }
    
    func connect(to peripheral: CBPeripheral) {
        appState.log("Connecting to \(peripheral.name ?? "Unknown")...")
        centralManager?.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        // Check if operating mode has been set
        if !appState.operatingModeSet {
            appState.showOperatingModeWarning = true
            return
        }
        
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    func forceDisconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    func sendTimestamp() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let payload = "{\"timestamp\": \(timestamp)}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func sendFilenamesRequest() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"sendFilenames\": true}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func clearMemory() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"clearMemory\": true}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
            
            // Clear file-related UI state since memory is cleared
            DispatchQueue.main.async {
                self.appState.availableFiles = []
                self.appState.requestFileName = ""
                self.appState.receivedFileContent = ""
            }
        }
    }
    
    func resetToShelfMode() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"reset\": true}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func setOperatingMode(_ mode: Int) {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"operatingMode\":\(mode)}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
            
            // Update operating mode state
            appState.operatingModeSet = true
            appState.selectedOperatingMode = mode
        }
    }
    
    func saveSettings() {
        guard let characteristic = gatewayCharacteristic,
              let mode = appState.selectedOperatingMode else {
            appState.log("ERROR: Gateway characteristic not available or no mode selected")
            return
        }
        
        var command: [String: Any] = ["operatingMode": mode]
        
        if mode == 0 {
            // Social Mode - add advertising and scanning intervals
            command["advInterval"] = appState.advInterval
            command["scanInterval"] = appState.scanInterval
        } else if mode == 1 {
            // Electric Mode - add ADC configuration
            command["adcMode"] = appState.adcMode
            command["adcThreshold"] = appState.adcThreshold
            command["adcBufferSize"] = appState.adcBufferSize
            command["adcDebounce"] = appState.adcDebounce
            command["adcPeaksOnly"] = appState.adcPeaksOnly
            command["sampling_rate"] = appState.samplingRate
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            if let payload = String(data: jsonData, encoding: .utf8) {
                connectedPeripheral?.writeValue(jsonData, for: characteristic, type: .withResponse)
                appState.log("SENT: \(payload)")
                
                // Update operating mode state
                appState.operatingModeSet = true
            }
        } catch {
            appState.log("ERROR: Failed to serialize settings - \(error.localizedDescription)")
        }
    }
    
    func requestFilenames() {
        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }
        
        let payload = "request"
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: Request filenames")
        }
    }
    
    func startFileTransfer(filename: String) {
        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }
        
        // Clear previous file content when starting new transfer
        appState.receivedFileContent = ""
        
        if let data = filename.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: Request file transfer for '\(filename)'")
        }
    }
    
    private func checkAndSendInitialTimestamp() {
        // Check if all required characteristics are discovered
        guard gatewayCharacteristic != nil else {
            // Still discovering characteristics, wait for next discovery
            return
        }
        
        // Send timestamp automatically after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendTimestamp()
            
            // Send file request after timestamp with a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.sendFilenamesRequest()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appState.log("Bluetooth ready")
        case .poweredOff:
            appState.log("ERROR: Bluetooth powered off")
        case .unauthorized:
            appState.log("ERROR: Bluetooth unauthorized")
        case .unsupported:
            appState.log("ERROR: Bluetooth unsupported")
        default:
            appState.log("ERROR: Bluetooth state: \(central.state.rawValue)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name {
            if !appState.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                appState.discoveredDevices.append(peripheral)
                appState.log("DISCOVERED: \(name) (RSSI: \(RSSI))")
            }
        } else {
            if !appState.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                appState.discoveredDevices.append(peripheral)
                appState.log("DISCOVERED: Unnamed device \(peripheral.identifier.uuidString) (RSSI: \(RSSI))")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Stop scanning when we connect
        stopScanning()
        
        appState.isConnected = true
        appState.connectedDevice = peripheral
        appState.connectionStatus = peripheral.name ?? "Unknown"
        appState.log("CONNECTED: \(peripheral.name ?? "Unknown")")
        
        // Clear file content on new connection
        appState.receivedFileContent = ""
        
        // Reset operating mode state for new connection
        appState.operatingModeSet = false
        appState.selectedOperatingMode = nil
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([HublinkUUIDs.service])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appState.log("ERROR: Failed to connect - \(error?.localizedDescription ?? "Unknown error")")
        appState.connectionStatus = "Connection failed"
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appState.isConnected = false
        appState.connectedDevice = nil
        appState.connectionStatus = "Disconnected"
        
        if let error = error {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Error: \(error.localizedDescription)")
        } else {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Device disconnected")
        }
        
        // Clear connected state
        connectedPeripheral = nil
        filenameCharacteristic = nil
        fileTransferCharacteristic = nil
        gatewayCharacteristic = nil
        nodeCharacteristic = nil
        
        // Clear any pending timers
        appState.cancelClearDevices()
        
        // Clear the request filename field, available files, and file content
        appState.requestFileName = ""
        appState.availableFiles = []
        appState.receivedFileContent = ""
        
        // Hide share sheet if it's open
        appState.showShareSheet = false
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Service discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case HublinkUUIDs.filename:
                filenameCharacteristic = characteristic
                appState.log("Found filename characteristic")
            case HublinkUUIDs.fileTransfer:
                fileTransferCharacteristic = characteristic
                appState.log("Found file transfer characteristic")
            case HublinkUUIDs.gateway:
                gatewayCharacteristic = characteristic
                appState.log("Found gateway characteristic")
            case HublinkUUIDs.node:
                nodeCharacteristic = characteristic
                appState.log("Found node characteristic")
            default:
                break
            }
        }
        
        // Enable notifications for relevant characteristics
        if let filenameChar = filenameCharacteristic {
            peripheral.setNotifyValue(true, for: filenameChar)
        }
        if let fileTransferChar = fileTransferCharacteristic {
            peripheral.setNotifyValue(true, for: fileTransferChar)
        }
        
        // Check if all required characteristics are discovered and send timestamp automatically
        checkAndSendInitialTimestamp()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic update failed - \(error!.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            appState.log("ERROR: No data received from characteristic")
            return
        }
        
        // Log raw data for debugging
        let hexString = data.map { String(format: "%02X", $0) }.joined()
        // appState.log("RAW DATA: \(hexString)")
        
        // Try to decode as UTF-8 string first (for commands/responses)
        if let string = String(data: data, encoding: .utf8) {
            appState.log("RECEIVED: \(string)")
            
            // Handle NFF (No File Found) response
            if string.trimmingCharacters(in: .whitespacesAndNewlines) == "NFF" {
                DispatchQueue.main.async {
                    self.appState.log("ERROR: File not found on device")
                    self.appState.receivedFileContent = ""
                }
                return
            }
            
            // Handle EOF in file transfer (end of file data)
            if string.trimmingCharacters(in: .whitespacesAndNewlines) == "EOF" {
                DispatchQueue.main.async {
                    self.appState.log("✓ File transfer completed")
                }
                return
            }
            
            // Check if this is a filename response and populate the file list
            if string.contains("|") && string.contains(";") && string.contains("EOF") {
                let components = string.components(separatedBy: ";")
                var files: [String] = []
                
                for component in components {
                    if component.contains("|") && !component.contains("EOF") {
                        let filename = component.components(separatedBy: "|").first ?? ""
                        if !filename.isEmpty {
                            files.append(filename)
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.appState.availableFiles = files
                    // Auto-select first file if available
                    if let firstFile = files.first {
                        self.appState.requestFileName = firstFile
                    }
                }
            } else if characteristic.uuid == HublinkUUIDs.fileTransfer {
                // Handle UTF-8 file content data
                DispatchQueue.main.async {
                    // Check if the string looks like hex (only contains 0-9, A-F)
                    let hexPattern = "^[0-9A-Fa-f]+$"
                    let isHexString = string.range(of: hexPattern, options: .regularExpression) != nil
                    
                    if isHexString {
                        // Hardware sent hex string as UTF-8 text, use it directly
                        self.appState.receivedFileContent += string.uppercased()
                    } else {
                        // Hardware sent regular text, convert to hex
                        let hexString = data.map { String(format: "%02X", $0) }.joined()
                        self.appState.receivedFileContent += hexString
                    }
                }
            }
        } else {
            // Handle binary data (file content)
            if characteristic.uuid == HublinkUUIDs.fileTransfer {
                DispatchQueue.main.async {
                    // Convert binary data to hex string for display
                    self.appState.receivedFileContent += hexString
                }
            } else {
                appState.log("WARNING: Received binary data on non-file-transfer characteristic")
            }
        }
    }
}

// MARK: - Date Formatter Extension
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Custom Button Style
struct JuxtaButtonStyle: ButtonStyle {
    let color: Color
    let isDestructive: Bool
    let isOperatingMode: Bool
    let isSubtle: Bool
    
    init(color: Color = .blue, isDestructive: Bool = false, isOperatingMode: Bool = false, isSubtle: Bool = false) {
        self.color = color
        self.isDestructive = isDestructive
        self.isOperatingMode = isOperatingMode
        self.isSubtle = isSubtle
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .default))
            .foregroundColor(isOperatingMode ? color : (isDestructive ? .white : .primary))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSubtle ? AnyShapeStyle(Color(.systemGray6)) :
                        isDestructive ? 
                        AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .top, endPoint: .bottom)) :
                        isOperatingMode ?
                        AnyShapeStyle(Color(.systemBackground)) :
                        AnyShapeStyle(LinearGradient(colors: [Color(.systemGray6), Color(.systemGray5)], startPoint: .top, endPoint: .bottom))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isOperatingMode ? color : color.opacity(0.3), 
                        lineWidth: isOperatingMode ? 2 : 0.5
                    )
            )
            .shadow(
                color: isSubtle ? Color.black.opacity(0.1) : 
                       isOperatingMode ? color.opacity(0.3) : color.opacity(0.2), 
                radius: configuration.isPressed ? 1 : (isSubtle ? 1 : (isOperatingMode ? 2 : 3)), 
                x: 0, 
                y: configuration.isPressed ? 1 : (isSubtle ? 1 : (isOperatingMode ? 1 : 2))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var bleManager: BLEManager
    
    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _bleManager = StateObject(wrappedValue: BLEManager(appState: state))
        state.startClock()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Clock - always at the top
            clockView
            
            // Header
            headerView
            
            // Main Content
            if appState.isConnected {
                connectedView
            } else {
                deviceListView
            }
            
            Spacer()
            
            // Terminal - pinned to bottom
            terminalView
        }
        .background(Color(.systemBackground))
    }
    
    // MARK: - Clock View
    private var clockView: some View {
        HStack {
            Spacer()
            Text(appState.currentTime)
                .font(.system(size: 16, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
    
    // MARK: - Header View
    private var headerView: some View {
        VStack(spacing: 16) {
            if !appState.isConnected {
                Button(action: {
                    if appState.isScanning {
                        bleManager.stopScanning()
                    } else {
                        bleManager.startScanning()
                    }
                }) {
                    Text(appState.isScanning ? "Stop" : "Scan")
                        .font(.system(size: 20, weight: .semibold, design: .default))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.42, green: 0.05, blue: 0.68), // Deep purple ~#6A0DAD
                                    Color(red: 1.0, green: 0.0, blue: 1.0)     // Vibrant fuchsia ~#FF00FF
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
    
    // MARK: - Device List View
    private var deviceListView: some View {
        List {
            ForEach(appState.discoveredDevices, id: \.identifier) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name ?? "Unknown")
                            .font(.system(size: 16, weight: .medium, design: .default))
                        
                        Text(device.identifier.uuidString)
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        bleManager.connect(to: device)
                    }) {
                        Text("Connect")
                            .font(.system(size: 14, weight: .medium, design: .default))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isConnected)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(PlainListStyle())
    }
    
    // MARK: - Connected View
    private var connectedView: some View {
        VStack(spacing: 20) {
            // Header with disconnect
            HStack {
                Text(appState.connectedDevice?.name ?? "Not Connected")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    bleManager.disconnect()
                }) {
                    Text("Disconnect")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .red, isDestructive: true))
            }
            
            // Operating mode buttons
            HStack(spacing: 12) {
                Button(action: {
                    appState.selectedOperatingMode = 0
                    appState.showSettingsSheet = true
                }) {
                    Text("Social Mode")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(
                    color: appState.operatingModeSet ? (appState.selectedOperatingMode == 0 ? .green : .blue) : .red,
                    isOperatingMode: true
                ))
                
                Button(action: {
                    appState.selectedOperatingMode = 1
                    appState.showSettingsSheet = true
                }) {
                    Text("Electric Mode")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(
                    color: appState.operatingModeSet ? (appState.selectedOperatingMode == 1 ? .green : .blue) : .red,
                    isOperatingMode: true
                ))
            }
            
            // Section divider
            Divider()
                .background(Color(.systemGray4))
                .padding(.vertical, 8)
            
            // JSON commands - single row
            HStack(spacing: 12) {
                Button(action: {
                    appState.showShelfModeAlert = true
                }) {
                    Text("Shelf Mode")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .orange))
                
                Button(action: {
                    appState.showClearMemoryAlert = true
                }) {
                    Text("Clear Memory")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .orange))
            }
            
            // File request dropdown
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(appState.availableFiles.count) total files")
                        .font(.system(size: 10, weight: .regular, design: .default))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    
                    Picker("Select File", selection: $appState.requestFileName) {
                        if appState.availableFiles.isEmpty {
                            Text("No files available").tag("")
                        } else {
                            ForEach(appState.availableFiles, id: \.self) { filename in
                                Text(filename).tag(filename)
                            }
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Button(action: {
                    if !appState.requestFileName.isEmpty {
                        bleManager.startFileTransfer(filename: appState.requestFileName)
                    }
                }) {
                    Text("Transfer Data")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .blue))
                .disabled(appState.requestFileName.isEmpty || appState.availableFiles.isEmpty)
            }
            
            // File content display area
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("File Content:")
                        .font(.system(size: 14, weight: .medium, design: .default))
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = appState.receivedFileContent
                        appState.log("✓ Copied file content to clipboard (\(appState.receivedFileContent.count) characters)")
                    }
                    .buttonStyle(JuxtaButtonStyle(isSubtle: true))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .disabled(appState.receivedFileContent.isEmpty)
                    
                    Button("Share") {
                        appState.showShareSheet = true
                    }
                    .buttonStyle(JuxtaButtonStyle(isSubtle: true))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .disabled(appState.receivedFileContent.isEmpty)
                    
                    Button("Clear") {
                        appState.receivedFileContent = ""
                    }
                    .buttonStyle(JuxtaButtonStyle(isSubtle: true))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .disabled(appState.receivedFileContent.isEmpty)
                }
                
                ScrollView {
                    Text(appState.receivedFileContent.isEmpty ? "No file content received" : appState.receivedFileContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Removed utility buttons - not needed
        }
        .padding()
        .background(Color(.systemBackground))
        .alert("Clear Memory", isPresented: $appState.showClearMemoryAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Memory", role: .destructive) {
                bleManager.clearMemory()
            }
        } message: {
            Text("This will permanently clear all memory on the device. This action cannot be undone. Are you absolutely sure?")
        }
        .alert("Shelf Mode", isPresented: $appState.showShelfModeAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset to Shelf Mode", role: .destructive) {
                bleManager.resetToShelfMode()
            }
        } message: {
            Text("This will reset the device to shelf mode. The device will restart and return to its default state. Are you sure?")
        }
        .alert("Operating Mode Required", isPresented: $appState.showOperatingModeWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect Anyway", role: .destructive) {
                bleManager.forceDisconnect()
            }
        } message: {
            Text("You haven't set an operating mode yet. The device will disconnect without a mode selected. Are you sure you want to disconnect?")
        }
        .sheet(isPresented: $appState.showShareSheet) {
            if let fileURL = appState.createShareableFile() {
                ShareSheet(items: [fileURL], onComplete: {
                    appState.showShareSheet = false
                })
            }
        }
        .sheet(isPresented: $appState.showSettingsSheet) {
            settingsView
        }
    }
    
    // MARK: - Terminal View
    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.terminalLog.enumerated()), id: \.offset) { index, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: appState.terminalLog.count) { oldValue, newValue in
                if let lastIndex = appState.terminalLog.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(.systemGray6))
        .frame(maxHeight: 150 )
    }
    
    // MARK: - Settings View
    private var settingsView: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let mode = appState.selectedOperatingMode {
                    if mode == 0 {
                        // Social Mode Settings
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Social Mode Settings")
                                .font(.system(size: 20, weight: .bold, design: .default))
                                .foregroundColor(.primary)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Advertising Interval (seconds)")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(appState.advInterval) },
                                        set: { 
                                            let rounded = Int(($0 / 5).rounded()) * 5
                                            appState.advInterval = max(5, min(60, rounded))
                                        }
                                    ), in: 5...60, step: 5)
                                    Text("\(appState.advInterval)s")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 40)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Scanning Interval (seconds)")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(appState.scanInterval) },
                                        set: { 
                                            let rounded = Int(($0 / 5).rounded()) * 5
                                            appState.scanInterval = max(5, min(60, rounded))
                                        }
                                    ), in: 5...60, step: 5)
                                    Text("\(appState.scanInterval)s")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 40)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                    } else if mode == 1 {
                        // Electric Mode Settings - ADC Configuration
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Electric Mode Settings")
                                .font(.system(size: 20, weight: .bold, design: .default))
                                .foregroundColor(.primary)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ADC Mode")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                Picker("ADC Mode", selection: $appState.adcMode) {
                                    Text("Timer Bursts (0)").tag(0)
                                    Text("Threshold Events (1)").tag(1)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            
                            // Separator
                            Divider()
                                .background(Color(.systemGray4))
                                .padding(.vertical, 8)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Sampling Rate")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                Picker("Sampling Rate", selection: $appState.samplingRate) {
                                    Text("1 kHz").tag(1000)
                                    Text("10 kHz").tag(10000)
                                    Text("100 kHz").tag(100000)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ADC Threshold (mV)")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(appState.adcThreshold) },
                                        set: { 
                                            let rounded = Int(($0 / 10).rounded()) * 10
                                            appState.adcThreshold = max(0, min(1000, rounded))
                                        }
                                    ), in: 0...1000, step: 10)
                                    Text("\(appState.adcThreshold)mV")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 60)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Buffer Size (samples)")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(appState.adcBufferSize) },
                                        set: { 
                                            let rounded = Int(($0 / 10).rounded()) * 10
                                            appState.adcBufferSize = max(10, min(1000, rounded))
                                        }
                                    ), in: 10...1000, step: 10)
                                    Text("\(appState.adcBufferSize)")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 50)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Debounce (ms)")
                                    .font(.system(size: 16, weight: .medium, design: .default))
                                
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(appState.adcDebounce) },
                                        set: { appState.adcDebounce = Int($0) }
                                    ), in: 100...10000, step: 100)
                                    Text("\(appState.adcDebounce)ms")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 70)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Peaks Only")
                                        .font(.system(size: 16, weight: .medium, design: .default))
                                    Spacer()
                                    Toggle("", isOn: $appState.adcPeaksOnly)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Device Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        appState.showSettingsSheet = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        bleManager.saveSettings()
                        appState.showSettingsSheet = false
                    }
                }
            }
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // Set completion handler to hide the sheet after sharing
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                onComplete()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
