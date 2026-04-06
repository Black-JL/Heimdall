import AppKit
import CoreAudio
import Foundation

/// A visible window that shows live audio monitoring activity.
class LogWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var statusField: NSTextField!
    private var deviceField: NSTextField!
    private var formatField: NSTextField!
    private var hogField: NSTextField!
    private var engine: HeimdallEngine!

    func setup(engine: HeimdallEngine) {
        self.engine = engine
        createWindow()
    }

    private func createWindow() {
        // Window — taller to accommodate banner image
        let frame = NSRect(x: 200, y: 100, width: 640, height: 720)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Heimdall — Source Matching Audio Switcher"
        window.minSize = NSSize(width: 480, height: 400)
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        var y = contentView.bounds.height

        // Header area: image on left, description on right
        let headerHeight: CGFloat = 180
        y -= headerHeight
        let headerView = NSView(frame: NSRect(x: 0, y: y, width: contentView.bounds.width, height: headerHeight))
        headerView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(headerView)

        // Banner image — left third
        let imageWidth: CGFloat = 140
        let bannerView = NSImageView(frame: NSRect(x: 16, y: 10, width: imageWidth, height: headerHeight - 20))
        bannerView.imageScaling = .scaleProportionallyUpOrDown
        bannerView.imageAlignment = .alignCenter

        // Load the banner image — try multiple locations
        let imagePaths = [
            Bundle.main.path(forResource: "heimdall_banner", ofType: "png"),
            Bundle(for: type(of: self)).path(forResource: "heimdall_banner", ofType: "png"),
            Bundle.main.bundlePath + "/Contents/Resources/heimdall_banner.png",
            (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/../Resources/heimdall_banner.png",
        ]
        for path in imagePaths.compactMap({ $0 }) {
            if let img = NSImage(contentsOfFile: path) {
                bannerView.image = img
                break
            }
        }
        headerView.addSubview(bannerView)

        // Description text — right of the image
        let textX = imageWidth + 32
        let descText = NSTextField(wrappingLabelWithString:
            "Heimdall guards your music on its way to your DAC.\n\n" +
            "macOS resamples all audio to a single fixed rate before " +
            "sending it to your hardware. Apple's own fix is to manually " +
            "switch the rate in Audio MIDI Setup every time you change " +
            "tracks \u{2014} tedious. Heimdall does this automatically, " +
            "matching your DAC to the original source so your music " +
            "arrives untouched.\n\n" +
            "Just as Heimdall guards the Bifrost from the frost giants, " +
            "this app guards your signal path from resampling."
        )
        descText.frame = NSRect(x: textX, y: 10, width: contentView.bounds.width - textX - 16, height: headerHeight - 20)
        descText.autoresizingMask = [.width]
        descText.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        descText.textColor = NSColor(red: 0.65, green: 0.65, blue: 0.70, alpha: 1.0)
        descText.isBezeled = false
        descText.drawsBackground = false
        descText.isEditable = false
        descText.isSelectable = false
        descText.maximumNumberOfLines = 0
        descText.cell?.truncatesLastVisibleLine = true
        headerView.addSubview(descText)

        // Status bar below banner
        y -= 70
        let statusBar = NSView(frame: NSRect(x: 0, y: y, width: contentView.bounds.width, height: 70))
        statusBar.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(statusBar)

        // Device name
        deviceField = makeLabel(
            frame: NSRect(x: 16, y: 40, width: 600, height: 22),
            fontSize: 15, bold: true
        )
        deviceField.stringValue = "Waiting for DAC..."
        deviceField.autoresizingMask = [.width]
        statusBar.addSubview(deviceField)

        // Format line
        formatField = makeLabel(
            frame: NSRect(x: 16, y: 20, width: 600, height: 18),
            fontSize: 13, bold: false
        )
        formatField.stringValue = ""
        formatField.textColor = NSColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1.0)
        formatField.autoresizingMask = [.width]
        statusBar.addSubview(formatField)

        // Hog mode / bit-perfect status
        hogField = makeLabel(
            frame: NSRect(x: 16, y: 2, width: 600, height: 16),
            fontSize: 11, bold: false
        )
        hogField.stringValue = ""
        hogField.textColor = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        hogField.autoresizingMask = [.width]
        statusBar.addSubview(hogField)

        // Separator
        y -= 1
        let sep = NSBox(frame: NSRect(x: 0, y: y, width: contentView.bounds.width, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(sep)

        // Log text view (scrollable)
        y -= 1
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: y))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0)

        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0)
        textView.textColor = NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        // Show the window
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Set up engine callbacks
        engine.onStatusChange = { [weak self] message in
            DispatchQueue.main.async {
                self?.updateStatusBar()
            }
        }

        engine.onDeviceConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.updateStatusBar()
            }
        }

        // Initial log message
        appendLog("Heimdall started")
        appendLog("")
    }

    func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let textView = self.textView else { return }

            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

            // Color-code the message
            let attributed = NSMutableAttributedString()

            // Timestamp in dim color
            let tsAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0),
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]
            attributed.append(NSAttributedString(string: "[\(timestamp)] ", attributes: tsAttrs))

            // Message with color coding
            let color: NSColor
            if message.contains("✓") || message.contains("Switched") {
                color = NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0) // Green for success
            } else if message.contains("▶") || message.contains("Now playing") {
                color = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0) // Blue for now playing
            } else if message.contains("↻") || message.contains("Switching") {
                color = NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0) // Yellow for switching
            } else if message.contains("⚠") || message.contains("✗") {
                color = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0) // Red for errors
            } else if message.contains("🔌") {
                color = NSColor(red: 0.9, green: 0.6, blue: 1.0, alpha: 1.0) // Purple for connection
            } else {
                color = NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0) // Default gray
            }

            let msgAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]
            attributed.append(NSAttributedString(string: message + "\n", attributes: msgAttrs))

            textView.textStorage?.append(attributed)

            // Auto-scroll to bottom
            textView.scrollToEndOfDocument(nil)
        }
    }

    func updateStatusBar() {
        guard let deviceID = AudioDeviceManager.findExternalDAC() else {
            deviceField.stringValue = "Waiting for external DAC..."
            deviceField.textColor = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)
            formatField.stringValue = "Plug in a USB DAC to start monitoring"
            hogField.stringValue = ""
            return
        }

        let name = AudioDeviceManager.deviceName(deviceID) ?? "Unknown DAC"
        let rate = AudioDeviceManager.currentSampleRate(deviceID) ?? 0
        let streams = AudioDeviceManager.outputStreamIDs(deviceID)
        let format = streams.first.flatMap { AudioDeviceManager.physicalFormat($0) }
        let bits = format?.mBitsPerChannel ?? 0
        let isInteger = format.map { ($0.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 } ?? false

        let transport = AudioDeviceManager.transportTypeName(deviceID)
        deviceField.stringValue = "Connected — \(name) (\(transport))"
        deviceField.textColor = NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
        formatField.stringValue = "\(formatRate(rate)) / \(bits)-bit \(isInteger ? "Integer" : "Float") — \(format?.mChannelsPerFrame ?? 2) channels"

        if engine.hogModeActive {
            hogField.stringValue = "Exclusive Mode ON — Hog Mode active, bypassing macOS mixer"
            hogField.textColor = NSColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1.0)
        } else {
            hogField.stringValue = "Auto-switching sample rate to match source audio"
            hogField.textColor = NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
        }
    }

    private func makeLabel(frame: NSRect, fontSize: CGFloat, bold: Bool) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.textColor = .white
        field.font = bold
            ? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: fontSize, weight: .regular)
        return field
    }

    private func formatRate(_ rate: Float64) -> String {
        let rateInt = Int(rate)
        switch rateInt {
        case 44100: return "44.1 kHz"
        case 48000: return "48 kHz"
        case 88200: return "88.2 kHz"
        case 96000: return "96 kHz"
        case 176400: return "176.4 kHz"
        case 192000: return "192 kHz"
        default: return "\(rateInt) Hz"
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Don't quit — just hide. The menu bar icon keeps running.
    }
}
