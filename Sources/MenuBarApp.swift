import AppKit
import CoreAudio
import Foundation

/// Menu bar app that shows status and provides controls.
class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var engine: HeimdallEngine!

    func setup(engine: HeimdallEngine) {
        self.engine = engine

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "♪"
            button.toolTip = "Heimdall — Lossless Audio Switcher"
        }

        rebuildMenu()

        engine.onStatusChange = { [weak self] _ in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }

        engine.onDeviceConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.statusItem.button?.title = connected ? "♪" : "♪?"
                self?.rebuildMenu()
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Header
        let header = NSMenuItem(title: "Heimdall", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Device info
        if let deviceID = AudioDeviceManager.findExternalDAC() {
            let name = AudioDeviceManager.deviceName(deviceID) ?? "Unknown"
            let rate = AudioDeviceManager.currentSampleRate(deviceID).map { "\(Int($0)) Hz" } ?? "?"

            let streams = AudioDeviceManager.outputStreamIDs(deviceID)
            let format = streams.first.flatMap { AudioDeviceManager.physicalFormat($0) }
            let bits = format.map { "\($0.mBitsPerChannel)-bit" } ?? "?"
            let isInteger = format.map { ($0.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 } ?? false

            addDisabledItem(menu, "DAC: \(name)")
            addDisabledItem(menu, "Output: \(rate) / \(bits)\(isInteger ? " integer" : " float")")

            // Hog mode / bit-perfect status
            if engine.hogModeActive {
                addDisabledItem(menu, "Mode: Bit-Perfect (Exclusive)")
            } else {
                addDisabledItem(menu, "Mode: Shared (macOS mixer active)")
            }

            menu.addItem(NSMenuItem.separator())

            // Bit-perfect toggle
            let bpItem = NSMenuItem(
                title: "Bit-Perfect Mode",
                action: #selector(toggleBitPerfect(_:)),
                keyEquivalent: "b"
            )
            bpItem.target = self
            bpItem.state = engine.bitPerfectEnabled ? .on : .off
            menu.addItem(bpItem)

            menu.addItem(NSMenuItem.separator())

            // Manual rate selection
            addDisabledItem(menu, "Manual Rate Override:")

            let supported = AudioDeviceManager.supportedSampleRates(deviceID)
            let currentRate = AudioDeviceManager.currentSampleRate(deviceID) ?? 0
            for rate in supported.sorted() {
                let label = "  \(formatRate(rate))"
                let item = NSMenuItem(title: label, action: #selector(switchRate(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(rate)
                if rate == currentRate {
                    item.state = .on
                }
                menu.addItem(item)
            }
        } else {
            addDisabledItem(menu, "DAC: No external DAC found")
            addDisabledItem(menu, "Plug in a USB DAC to start")
        }

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About Heimdall", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Heimdall", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addDisabledItem(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleBitPerfect(_ sender: NSMenuItem) {
        let newState = !engine.bitPerfectEnabled
        engine.setBitPerfect(newState)
        rebuildMenu()
    }

    @objc private func switchRate(_ sender: NSMenuItem) {
        let rate = Float64(sender.tag)
        engine.forceRate(rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Heimdall — Lossless Audio Switcher"
        alert.informativeText = """
        Version 1.0

        In Norse mythology, Heimdall is the guardian of the Bifrost \
        bridge — the keenest listener among the gods, able to hear \
        grass growing and see for hundreds of miles.

        This app guards the signal path to your DAC. It monitors \
        what you're playing, detects the native audio format, and \
        automatically switches your DAC's sample rate to match — \
        so macOS doesn't resample your music before it reaches \
        your hardware.

        No resampling. No manual Audio MIDI Setup. Just the \
        original signal, straight to your DAC.

        github.com/Black-JL/Heimdall
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.runModal()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        engine.stop()
        NSApp.terminate(nil)
    }

    private func formatRate(_ rate: Float64) -> String {
        let rateInt = Int(rate)
        switch rateInt {
        case 44100: return "44.1 kHz (CD Quality)"
        case 48000: return "48 kHz (DVD/Streaming)"
        case 88200: return "88.2 kHz (2x CD)"
        case 96000: return "96 kHz (Hi-Res)"
        case 176400: return "176.4 kHz (4x CD)"
        case 192000: return "192 kHz (Hi-Res Max)"
        default: return "\(rateInt) Hz"
        }
    }
}
