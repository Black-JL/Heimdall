import CoreAudio
import Foundation

/// Manages CoreAudio output devices — finding, querying, and switching sample rates.
struct AudioDeviceManager {

    // MARK: - Device Discovery

    /// Returns all audio output device IDs on the system.
    static func allOutputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.filter { hasOutputStreams($0) }
    }

    /// Check if a device has output streams.
    static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    /// Get the name of an audio device.
    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() else {
            return nil
        }
        return name as String
    }

    /// Get the manufacturer of an audio device.
    static func deviceManufacturer(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() else {
            return nil
        }
        return name as String
    }

    /// Find the default output device.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    /// Set the default output device.
    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        return status == noErr
    }

    /// Get the transport type of a device (USB, Built-in, Virtual, etc.)
    static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport)
        return transport
    }

    /// Check if a device is an external DAC (USB, Thunderbolt, FireWire — not built-in, virtual, or Apple displays).
    static func isExternalDevice(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(deviceID)
        let externalTransports: Set<UInt32> = [
            0x75736220, // 'usb ' — USB
            0x7468756E, // 'thun' — Thunderbolt
            0x31333934, // '1394' — FireWire
        ]
        guard externalTransports.contains(transport) else { return false }

        // Filter out Apple devices (displays, built-in speakers exposed via USB)
        // Real external DACs are made by Schiit, Topping, SMSL, RME, Chord, etc.
        let manufacturer = deviceManufacturer(deviceID)?.lowercased() ?? ""
        if manufacturer.contains("apple") { return false }

        // Filter out virtual/software devices that might claim USB transport
        let name = (deviceName(deviceID) ?? "").lowercased()
        let virtualKeywords = ["microsoft teams", "zoom", "blackhole", "soundflower", "loopback"]
        if virtualKeywords.contains(where: { name.contains($0) }) { return false }

        return true
    }

    /// Human-readable transport type name.
    static func transportTypeName(_ deviceID: AudioDeviceID) -> String {
        let transport = transportType(deviceID)
        switch transport {
        case 0x75736220: return "USB"       // 'usb '
        case 0x626C746E: return "Built-in"  // 'bltn'
        case 0x7468756E: return "Thunderbolt" // 'thun'
        case 0x31333934: return "FireWire"  // '1394'
        case 0x6275696C: return "Built-in"  // 'buil'
        case 0x76697274: return "Virtual"   // 'virt'
        case 0x64697370: return "DisplayPort" // 'disp'
        case 0x68646D69: return "HDMI"      // 'hdmi'
        case 0x61697270: return "AirPlay"   // 'airp'
        case 0x626C7565: return "Bluetooth" // 'blue'
        case 0: return "System"
        default:
            // Try to decode as ASCII
            let bytes = withUnsafeBytes(of: transport.bigEndian) { Array($0) }
            if let str = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces), !str.isEmpty {
                return str
            }
            return "External"
        }
    }

    /// Find a device by name (partial match, case-insensitive).
    static func findDevice(matching name: String) -> AudioDeviceID? {
        let lower = name.lowercased()
        return allOutputDeviceIDs().first { id in
            guard let deviceName = deviceName(id) else { return false }
            return deviceName.lowercased().contains(lower)
        }
    }

    /// Auto-detect the first external DAC (USB/Thunderbolt/FireWire output device).
    /// Returns nil if no external DAC is found.
    static func findExternalDAC() -> AudioDeviceID? {
        return allOutputDeviceIDs().first { isExternalDevice($0) }
    }

    /// Find all external DACs.
    static func allExternalDACs() -> [AudioDeviceID] {
        return allOutputDeviceIDs().filter { isExternalDevice($0) }
    }

    // MARK: - Sample Rate

    /// Get the current nominal sample rate of a device.
    static func currentSampleRate(_ deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr else {
            return nil
        }
        return sampleRate
    }

    /// Get all supported sample rates for a device.
    static func availableSampleRates(_ deviceID: AudioDeviceID) -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ranges) == noErr else {
            return []
        }
        return ranges
    }

    /// Get the list of discrete supported sample rates as Float64 values.
    static func supportedSampleRates(_ deviceID: AudioDeviceID) -> [Float64] {
        availableSampleRates(deviceID).map { $0.mMinimum }
    }

    /// Set the sample rate of a device. Returns true on success.
    @discardableResult
    static func setSampleRate(_ deviceID: AudioDeviceID, to sampleRate: Float64) -> Bool {
        // Check if already at the desired rate
        if let current = currentSampleRate(deviceID), current == sampleRate {
            return true
        }

        // Verify the device supports this rate
        let supported = availableSampleRates(deviceID)
        let isSupported = supported.contains { range in
            sampleRate >= range.mMinimum && sampleRate <= range.mMaximum
        }
        guard isSupported else {
            print("⚠ Sample rate \(Int(sampleRate)) Hz not supported by device")
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &rate
        )

        if status != noErr {
            print("⚠ Failed to set sample rate: OSStatus \(status)")
            return false
        }
        return true
    }

    // MARK: - Stream Format (Bit Depth)

    /// Get the output stream IDs for a device.
    static func outputStreamIDs(_ deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &streamIDs) == noErr else {
            return []
        }
        return streamIDs
    }

    /// Get the physical format of a stream.
    static func physicalFormat(_ streamID: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &format) == noErr else {
            return nil
        }
        return format
    }

    /// Set the physical format of a stream (sample rate + bit depth).
    /// Queries available formats to find a compatible one rather than guessing the ASBD layout.
    @discardableResult
    static func setPhysicalFormat(_ streamID: AudioStreamID, sampleRate: Float64, bitsPerChannel: UInt32) -> Bool {
        // Use the format-query approach for reliability
        return setBitPerfectFormat(streamID, sampleRate: sampleRate, bitsPerChannel: bitsPerChannel)
    }

    // MARK: - Hog Mode (Exclusive Access for Bit-Perfect)

    /// Get the current hog mode PID. Returns -1 if not hogged, or the PID of the hogging process.
    static func hogModePID(_ deviceID: AudioDeviceID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &pid)
        return pid
    }

    /// Take exclusive (hog) mode on a device. Returns true if this process now owns it.
    @discardableResult
    static func acquireHogMode(_ deviceID: AudioDeviceID) -> Bool {
        let currentPID = hogModePID(deviceID)
        let myPID = ProcessInfo.processInfo.processIdentifier

        if currentPID == myPID { return true } // Already hogged by us
        if currentPID != -1 {
            print("⚠ Device hogged by PID \(currentPID)")
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = myPID
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        if status != noErr {
            print("⚠ Failed to acquire hog mode: OSStatus \(status)")
            return false
        }
        return true
    }

    /// Release hog mode on a device.
    @discardableResult
    static func releaseHogMode(_ deviceID: AudioDeviceID) -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let currentPID = hogModePID(deviceID)
        guard currentPID == myPID else { return true } // Not ours to release

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        if status != noErr {
            print("⚠ Failed to release hog mode: OSStatus \(status)")
            return false
        }
        return true
    }

    // MARK: - Available Physical Formats (for Integer Mode / Bit-Perfect)

    /// Get all available physical formats for a stream (sample rate + bit depth + format combos).
    static func availablePhysicalFormats(_ streamID: AudioStreamID) -> [AudioStreamRangedDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioStreamRangedDescription>.size
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: count
        )
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &formats) == noErr else {
            return []
        }
        return formats
    }

    /// Find the best physical format matching the target sample rate and bit depth.
    /// Prefers integer (non-mixable) formats for bit-perfect output.
    static func bestPhysicalFormat(
        _ streamID: AudioStreamID,
        sampleRate: Float64,
        bitsPerChannel: UInt32
    ) -> AudioStreamBasicDescription? {
        let formats = availablePhysicalFormats(streamID)

        // Filter to formats matching our target sample rate
        let matching = formats.filter { desc in
            let fmt = desc.mFormat
            guard fmt.mFormatID == kAudioFormatLinearPCM else { return false }
            // Check sample rate is in range
            return sampleRate >= desc.mSampleRateRange.mMinimum
                && sampleRate <= desc.mSampleRateRange.mMaximum
        }

        // Prefer: exact bit depth match with integer format, then any integer format, then any format
        let sorted = matching.sorted { a, b in
            let aInt = (a.mFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            let bInt = (b.mFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            let aBits = a.mFormat.mBitsPerChannel == bitsPerChannel
            let bBits = b.mFormat.mBitsPerChannel == bitsPerChannel

            if aBits != bBits { return aBits }
            if aInt != bInt { return aInt }
            // Prefer higher bit depth
            return a.mFormat.mBitsPerChannel > b.mFormat.mBitsPerChannel
        }

        guard var best = sorted.first?.mFormat else { return nil }
        best.mSampleRate = sampleRate
        return best
    }

    /// Set the stream to the best available bit-perfect format.
    @discardableResult
    static func setBitPerfectFormat(
        _ streamID: AudioStreamID,
        sampleRate: Float64,
        bitsPerChannel: UInt32
    ) -> Bool {
        guard var format = bestPhysicalFormat(streamID, sampleRate: sampleRate, bitsPerChannel: bitsPerChannel) else {
            print("⚠ No suitable physical format found for \(Int(sampleRate)) Hz / \(bitsPerChannel)-bit")
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            streamID, &address, 0, nil,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format
        )

        if status != noErr {
            print("⚠ Failed to set bit-perfect format: OSStatus \(status)")
            return false
        }

        let isInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        print("  ✓ Physical format: \(Int(format.mSampleRate)) Hz, \(format.mBitsPerChannel)-bit, \(isInteger ? "integer" : "float")")
        return true
    }

    // MARK: - Device Connection Monitoring

    /// Install a listener for device list changes (plug/unplug events).
    static func addDeviceListListener(
        callback: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, callback
        )
    }

    // MARK: - Listeners

    /// Install a listener for sample rate changes on a device.
    static func addSampleRateListener(
        _ deviceID: AudioDeviceID,
        callback: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, callback)
    }

    /// Install a listener for default output device changes.
    static func addDefaultOutputDeviceListener(
        callback: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, callback
        )
    }

    // MARK: - Convenience

    /// Pretty-print device info.
    static func printDeviceInfo(_ deviceID: AudioDeviceID) {
        let name = deviceName(deviceID) ?? "Unknown"
        let manufacturer = deviceManufacturer(deviceID) ?? "Unknown"
        let rate = currentSampleRate(deviceID).map { "\(Int($0)) Hz" } ?? "Unknown"
        let rates = supportedSampleRates(deviceID).map { "\(Int($0))" }.joined(separator: ", ")

        print("  Device: \(name)")
        print("  Manufacturer: \(manufacturer)")
        print("  Current Sample Rate: \(rate)")
        print("  Supported Rates: \(rates) Hz")

        for streamID in outputStreamIDs(deviceID) {
            if let fmt = physicalFormat(streamID) {
                print("  Stream Format: \(Int(fmt.mSampleRate)) Hz, \(fmt.mBitsPerChannel)-bit, \(fmt.mChannelsPerFrame) ch")
            }
        }
    }

    /// Find the best matching sample rate the device supports for a given target.
    static func bestMatchingSampleRate(_ deviceID: AudioDeviceID, for target: Float64) -> Float64? {
        let supported = supportedSampleRates(deviceID)
        // Exact match first
        if supported.contains(target) { return target }
        // Find closest
        return supported.min(by: { abs($0 - target) < abs($1 - target) })
    }
}
