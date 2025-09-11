# HublinkGateway iOS

A Bluetooth Low Energy (BLE) gateway application for iOS that enables communication with Hublink devices for file transfer and data management.

## Overview

HublinkGateway is a developer-focused iOS app that replicates core functionality from a Raspberry Pi-based gateway system. It provides a clean, efficient interface for discovering, connecting to, and managing Hublink devices over BLE.

## Features

- **BLE Device Discovery** - Scan for Hublink devices using custom service UUID
- **Device Connection** - Connect to discovered devices with automatic service discovery
- **Manual Controls** - Send timestamp, request filenames, and clear device memory
- **File Transfer** - Request and receive files from connected devices
- **Real-time Terminal** - View all BLE communication with timestamps
- **File Content Display** - Hex view of received file data with copy functionality
- **Auto-cleanup** - Device list automatically clears after 30 seconds of inactivity

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Bluetooth-enabled device
- Hublink-compatible peripheral devices

## Installation

1. Clone the repository
2. Open `HublinkGateway-iOS.xcodeproj` in Xcode
3. Configure Bluetooth permissions in project settings
4. Build and run on device (BLE requires physical device)

## Usage

### Scanning for Devices
- Tap "Scan" to discover nearby Hublink devices
- Devices are filtered by the Hublink service UUID
- Scan automatically stops after 10 seconds

### Connecting to Devices
- Tap "Connect" on any discovered device
- App automatically discovers Hublink characteristics
- Connection status is displayed in the header

### Manual Operations
- **Timestamp** - Send current timestamp to device
- **Get Files** - Request list of available files
- **Clear Memory** - Clear device memory (requires double confirmation)
- **Request File** - Enter filename and request file transfer

### File Management
- Received file content is displayed as hexadecimal
- Copy button to copy file content to clipboard
- Clear button to clear the display area

## BLE Protocol

The app communicates using custom Hublink UUIDs:
- Service: `57617368-5501-0001-8000-00805f9b34fb`
- Filename: `57617368-5502-0001-8000-00805f9b34fb`
- File Transfer: `57617368-5503-0001-8000-00805f9b34fb`
- Gateway: `57617368-5504-0001-8000-00805f9b34fb`
- Node: `57617368-5505-0001-8000-00805f9b34fb`

## Development

This app is designed for developers working with Hublink devices. The terminal provides real-time feedback for debugging BLE communication, and the interface is optimized for development workflows.

## License

[Add your license information here]
