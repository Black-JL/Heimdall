import AppKit
import Foundation

// Force line-buffered stdout
setlinebuf(stdout)

// MARK: - Entry Point

print("═══════════════════════════════════════════════")
print("  Heimdall — Lossless Audio Switcher")
print("  Auto sample rate matching for external DACs")
print("═══════════════════════════════════════════════")
print("")

// Parse command line args
let args = CommandLine.arguments
let cliMode = args.contains("--cli")
let useHogMode = args.contains("--hog")
let deviceName: String? = {
    if let idx = args.firstIndex(of: "--device"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return nil  // Auto-detect external DAC
}()
let pollInterval: TimeInterval = {
    if let idx = args.firstIndex(of: "--interval"), idx + 1 < args.count {
        return TimeInterval(args[idx + 1]) ?? 2.0
    }
    return 2.0
}()

// Show all audio devices
print("Audio Output Devices:")
print("─────────────────────")
for id in AudioDeviceManager.allOutputDeviceIDs() {
    let name = AudioDeviceManager.deviceName(id) ?? "Unknown"
    let rate = AudioDeviceManager.currentSampleRate(id).map { "\(Int($0)) Hz" } ?? "?"
    let transport = AudioDeviceManager.transportTypeName(id)
    let isDefault = id == AudioDeviceManager.defaultOutputDeviceID() ? " ← DEFAULT" : ""
    let isDAC = AudioDeviceManager.isExternalDevice(id) ? " [DAC]" : ""
    print("  [\(id)] \(name) @ \(rate) (\(transport))\(isDAC)\(isDefault)")
}
print("")

// Create the engine
let engine = HeimdallEngine(deviceName: deviceName, pollInterval: pollInterval)

if useHogMode {
    engine.setBitPerfect(true)
}

if cliMode {
    // CLI mode: run in terminal with text output
    print("Bit-perfect mode: \(engine.bitPerfectEnabled ? "ON" : "OFF")")
    print("Running in CLI mode (Ctrl+C to stop)")
    print("")
    engine.start()
    signal(SIGINT) { _ in print("\nShutting down..."); exit(0) }
    signal(SIGTERM) { _ in print("\nShutting down..."); exit(0) }
    dispatchMain()
} else {
    // GUI mode: window + menu bar
    let app = NSApplication.shared
    app.setActivationPolicy(.regular) // Show in dock so user can see it's running

    // Create the log window (main visual interface)
    let logWindow = LogWindowController()
    logWindow.setup(engine: engine)

    // Pipe engine logs to the window
    engine.onLog = { [weak logWindow] message in
        logWindow?.appendLog(message)
    }

    // Also set up device connection callback to update the window
    let originalDeviceCallback = engine.onDeviceConnectionChange
    engine.onDeviceConnectionChange = { [weak logWindow] connected in
        originalDeviceCallback?(connected)
        DispatchQueue.main.async {
            logWindow?.updateStatusBar()
        }
    }

    // Create the menu bar icon
    let menuBar = MenuBarController()
    menuBar.setup(engine: engine)

    // Start monitoring
    engine.start()

    // Keep references alive
    let _ = Unmanaged.passRetained(logWindow)
    let _ = Unmanaged.passRetained(menuBar)

    // Bring window to front
    logWindow.show()

    app.run()
}
