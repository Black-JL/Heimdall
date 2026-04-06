import CoreAudio
import Foundation

/// Core engine: polls for audio source changes and switches the DAC sample rate to match.
class HeimdallEngine {
    private var targetDeviceID: AudioDeviceID?
    private var targetDeviceName: String?  // nil means auto-detect any external DAC
    private var pollInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastInfo: AudioSourceDetector.AudioInfo?
    private var lastSampleRate: Float64 = 0
    private var lastSwitchTime: Date = .distantPast
    private var consecutiveFailures = 0
    private(set) var isRunning = false
    private(set) var bitPerfectEnabled = false
    private(set) var hogModeActive = false
    private(set) var deviceConnected = false
    var onStatusChange: ((String) -> Void)?
    var onDeviceConnectionChange: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    // Debounce: don't switch rates more often than this (seconds).
    // Prevents rapid flip-flopping between sources.
    private let switchCooldown: TimeInterval = 1.5

    /// Create a Heimdall engine.
    /// - deviceName: Specific device to target (e.g. "Bifrost"). If nil, auto-detects any external USB DAC.
    init(deviceName: String? = nil, pollInterval: TimeInterval = 2.0) {
        self.targetDeviceName = deviceName
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        log("Heimdall starting...")
        if let name = targetDeviceName {
            log("Looking for device: \"\(name)\"")
        } else {
            log("Looking for external DAC...")
        }

        // Monitor for device plug/unplug
        AudioDeviceManager.addDeviceListListener { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.checkDeviceConnection()
            }
        }

        // Monitor for default device changes
        AudioDeviceManager.addDefaultOutputDeviceListener { [weak self] _, _ in
            self?.refreshTargetDevice()
        }

        // Try to connect to the device
        checkDeviceConnection()

        if targetDeviceID == nil {
            log("⏳ Waiting for external DAC to be connected...")
            isRunning = true
            startPolling()
        }
    }

    private func activateDevice(_ deviceID: AudioDeviceID) {
        self.targetDeviceID = deviceID
        self.deviceConnected = true
        self.consecutiveFailures = 0

        let name = AudioDeviceManager.deviceName(deviceID) ?? "Unknown"
        let transport = AudioDeviceManager.transportTypeName(deviceID)
        log("✓ Found: \(name) (\(transport), ID: \(deviceID))")
        AudioDeviceManager.printDeviceInfo(deviceID)

        if let rate = AudioDeviceManager.currentSampleRate(deviceID) {
            lastSampleRate = rate
        }

        // Acquire hog mode for bit-perfect (if enabled)
        if bitPerfectEnabled {
            let defaultBefore = AudioDeviceManager.defaultOutputDeviceID()
            acquireHogMode(deviceID)
            if let before = defaultBefore, AudioDeviceManager.defaultOutputDeviceID() != before {
                AudioDeviceManager.setDefaultOutputDevice(before)
                log("  ✓ Restored default output device")
            }
        }

        if !isRunning {
            startPolling()
        }
        isRunning = true
        log("✓ Monitoring active (polling every \(pollInterval)s)")
        onDeviceConnectionChange?(true)
    }

    private func deactivateDevice() {
        if let deviceID = targetDeviceID, hogModeActive {
            AudioDeviceManager.releaseHogMode(deviceID)
            hogModeActive = false
            log("Released hog mode")
        }
        targetDeviceID = nil
        deviceConnected = false
        lastInfo = nil
        lastSampleRate = 0
        onDeviceConnectionChange?(false)
    }

    func stop() {
        log("Shutting down...")
        if let deviceID = targetDeviceID, hogModeActive {
            AudioDeviceManager.releaseHogMode(deviceID)
            hogModeActive = false
            log("Released hog mode")
        }
        timer?.cancel()
        timer = nil
        isRunning = false
        log("Monitoring stopped")
    }

    // MARK: - Bit-Perfect Control

    func setBitPerfect(_ enabled: Bool) {
        bitPerfectEnabled = enabled
        guard let deviceID = targetDeviceID else { return }

        if enabled {
            acquireHogMode(deviceID)
        } else {
            if hogModeActive {
                AudioDeviceManager.releaseHogMode(deviceID)
                hogModeActive = false
                log("Bit-perfect OFF — released hog mode")
            }
        }
        onStatusChange?(enabled ? "Bit-Perfect ON" : "Bit-Perfect OFF")
    }

    private func acquireHogMode(_ deviceID: AudioDeviceID) {
        if AudioDeviceManager.acquireHogMode(deviceID) {
            hogModeActive = true
            log("✓ Hog mode acquired — exclusive device access")
        } else {
            log("⚠ Could not acquire hog mode — output goes through macOS mixer")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let deviceID = targetDeviceID else { return }

        // Verify the device is still alive
        guard AudioDeviceManager.currentSampleRate(deviceID) != nil else {
            log("⚠ Device not responding — checking connection...")
            checkDeviceConnection()
            return
        }

        let detected = AudioSourceDetector.detectCurrentAudio()

        if let info = detected {
            if info != lastInfo {
                lastInfo = info
                log("▶ Now playing: \(info)")

                // Debounce: don't switch too rapidly
                let timeSinceLastSwitch = Date().timeIntervalSince(lastSwitchTime)
                if timeSinceLastSwitch < switchCooldown {
                    let wait = switchCooldown - timeSinceLastSwitch
                    log("  ⏱ Waiting \(String(format: "%.1f", wait))s before switching...")
                    Thread.sleep(forTimeInterval: wait)
                }

                switchIfNeeded(deviceID: deviceID, targetRate: info.sampleRate, bitDepth: info.bitDepth)
            }
        } else {
            if lastInfo != nil {
                lastInfo = nil
                log("⏸ No active audio source detected")
            }
        }
    }

    private func switchIfNeeded(deviceID: AudioDeviceID, targetRate: Float64, bitDepth: UInt32) {
        guard let currentRate = AudioDeviceManager.currentSampleRate(deviceID) else { return }

        let streams = AudioDeviceManager.outputStreamIDs(deviceID)
        let currentFormat = streams.first.flatMap { AudioDeviceManager.physicalFormat($0) }
        let currentBits = currentFormat?.mBitsPerChannel ?? 0

        let rateMatch = currentRate == targetRate
        let bitsMatch = currentBits == bitDepth || bitDepth == 0

        if rateMatch && bitsMatch {
            log("  ✓ Device already at \(Int(targetRate)) Hz / \(bitDepth)-bit")
            consecutiveFailures = 0
            return
        }

        // Only switch rate if needed (rate change is the important thing — it prevents resampling)
        guard let bestRate = AudioDeviceManager.bestMatchingSampleRate(deviceID, for: targetRate) else {
            log("  ✗ No suitable sample rate found")
            return
        }

        if bestRate != targetRate {
            log("  ≈ Target \(Int(targetRate)) Hz not available, using closest: \(Int(bestRate)) Hz")
        }

        log("  ↻ Switching \(Int(currentRate)) Hz/\(currentBits)-bit → \(Int(bestRate)) Hz/\(bitDepth)-bit...")

        // Set sample rate
        if !rateMatch {
            if AudioDeviceManager.setSampleRate(deviceID, to: bestRate) {
                lastSampleRate = bestRate
                lastSwitchTime = Date()
                // Brief pause for DAC to lock onto new clock
                Thread.sleep(forTimeInterval: 0.3)
            } else {
                consecutiveFailures += 1
                log("  ✗ Failed to set sample rate")
                if consecutiveFailures >= 3 {
                    log("  ⚠ Multiple failures — device may be in use by another app")
                }
                return
            }
        }

        // Set physical format (bit depth)
        if let streamID = streams.first, bitDepth > 0 {
            if bitPerfectEnabled {
                AudioDeviceManager.setBitPerfectFormat(streamID, sampleRate: bestRate, bitsPerChannel: bitDepth)
            } else {
                AudioDeviceManager.setPhysicalFormat(streamID, sampleRate: bestRate, bitsPerChannel: bitDepth)
            }
        }

        // Verify the change
        if let newRate = AudioDeviceManager.currentSampleRate(deviceID) {
            let newFormat = streams.first.flatMap { AudioDeviceManager.physicalFormat($0) }
            let newBits = newFormat?.mBitsPerChannel ?? 0
            log("  ✓ Now at \(Int(newRate)) Hz / \(newBits)-bit")
            consecutiveFailures = 0
            onStatusChange?("\(Int(newRate)) Hz / \(newBits)-bit")
        }
    }

    // MARK: - Device Connection

    private func checkDeviceConnection() {
        let deviceID: AudioDeviceID?

        if let name = targetDeviceName {
            deviceID = AudioDeviceManager.findDevice(matching: name)
        } else {
            deviceID = AudioDeviceManager.findExternalDAC()
        }

        if let deviceID = deviceID {
            if targetDeviceID == nil || targetDeviceID != deviceID {
                activateDevice(deviceID)
            }
        } else {
            if targetDeviceID != nil {
                let name = targetDeviceID.flatMap { AudioDeviceManager.deviceName($0) } ?? "DAC"
                log("🔌 \(name) disconnected")
                deactivateDevice()
            }
        }
    }

    private func refreshTargetDevice() {
        checkDeviceConnection()
    }

    // MARK: - Manual Control

    func forceRate(_ sampleRate: Float64) {
        guard let deviceID = targetDeviceID else {
            log("No target device")
            return
        }
        log("Manual override: setting \(Int(sampleRate)) Hz")
        AudioDeviceManager.setSampleRate(deviceID, to: sampleRate)
        lastSwitchTime = Date()

        let streams = AudioDeviceManager.outputStreamIDs(deviceID)
        if let streamID = streams.first {
            AudioDeviceManager.setPhysicalFormat(streamID, sampleRate: sampleRate, bitsPerChannel: 24)
        }
    }

    func printStatus() {
        guard let deviceID = targetDeviceID else {
            log("No target device found")
            return
        }
        let name = AudioDeviceManager.deviceName(deviceID) ?? "Unknown"
        let rate = AudioDeviceManager.currentSampleRate(deviceID).map { "\(Int($0)) Hz" } ?? "?"
        let hog = hogModeActive ? " | Hog: YES" : ""
        log("Device: \(name) | Rate: \(rate) | Monitoring: \(isRunning)\(hog)")
        if let info = lastInfo {
            log("Source: \(info)")
        }
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let msg = "[\(timestamp)] \(message)"
        print(msg)
        onLog?(message)
        onStatusChange?(message)
    }
}
