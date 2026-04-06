import AVFoundation
import Foundation

/// Detects the native sample rate and bit depth of currently playing audio.
struct AudioSourceDetector {

    /// Info about the currently playing audio source.
    struct AudioInfo: Equatable, CustomStringConvertible {
        let sampleRate: Float64
        let bitDepth: UInt32
        let source: String
        let trackName: String?

        var description: String {
            let bits = bitDepth > 0 ? "\(bitDepth)-bit" : "unknown-bit"
            let rate = "\(Int(sampleRate)) Hz"
            let track = trackName.map { " — \($0)" } ?? ""
            return "\(bits) / \(rate) [\(source)]\(track)"
        }
    }

    // MARK: - Known audio formats by bundle ID

    /// Apps where we know the output format — keyed by bundle ID prefix.
    private static let knownAppFormats: [String: (sampleRate: Float64, bitDepth: UInt32)] = [
        "com.spotify.client": (44100, 16),            // Ogg Vorbis, always 44.1kHz
        "com.tidal": (44100, 16),                      // Default; MQA would differ
        "com.amazon.music": (44100, 16),
        "com.pandora": (44100, 16),
        "com.soundcloud": (44100, 16),
        "com.deezer": (44100, 16),
    ]

    /// Browser bundle IDs
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",  // Arc
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    /// Known streaming service output formats — matched against video/page title
    private static let streamingServiceFormats: [(pattern: String, sampleRate: Float64, bitDepth: UInt32, label: String)] = [
        ("youtube", 48000, 16, "YouTube"),
        ("youtube music", 48000, 16, "YouTube Music"),
        ("netflix", 48000, 16, "Netflix"),
        ("disney+", 48000, 16, "Disney+"),
        ("hbo max", 48000, 16, "HBO Max"),
        ("apple tv", 48000, 16, "Apple TV+"),
        ("twitch", 48000, 16, "Twitch"),
        ("soundcloud", 44100, 16, "SoundCloud"),
        ("bandcamp", 44100, 16, "Bandcamp"),
        ("spotify", 44100, 16, "Spotify Web"),
        ("tidal", 44100, 16, "Tidal"),
    ]

    // MARK: - Main detection entry point

    /// Detect what's currently playing. Combines multiple methods:
    /// 1. Core Audio Tap — reads the actual sample rate of audio flowing to output (universal, works for any app)
    /// 2. AppleScript — identifies which app is playing and gets track names (Spotify, Music.app, VLC)
    /// 3. MediaRemote Now Playing — catches browsers and other apps
    /// 4. lsof — finds open audio files for local file players
    ///
    /// The tap gives us the TRUE sample rate; app detection gives us the name/context.
    static func detectCurrentAudio() -> AudioInfo? {
        // Step 1: Core Audio Tap — get the actual sample rate of audio flowing to output.
        // This is ground truth for the sample rate, works for Chrome, YouTube, anything.
        let tapFormat: TapFormat?
        if #available(macOS 14.2, *) {
            tapFormat = AudioTapDetector.detectOutputFormat()
        } else {
            tapFormat = nil
        }

        // Step 2: Identify what's playing (for display purposes + file-based format override)
        var activeSource: AudioInfo?

        // Check dedicated music apps via AppleScript (verifies playing state)
        if let info = detectFromSpotify() { activeSource = info }
        if activeSource == nil, let info = detectFromMusicApp() { activeSource = info }
        if activeSource == nil, let info = detectFromVLC() { activeSource = info }

        // Check MediaRemote (catches browsers, other apps)
        if activeSource == nil, let info = detectViaNowPlaying() { activeSource = info }

        // lsof fallback
        if activeSource == nil, let info = detectViaOpenFiles() { activeSource = info }

        // Step 3: Combine tap format with app identification
        if let tap = tapFormat {
            if let source = activeSource {
                // For Music.app with local files, trust the file's native format
                // (the tap may report a different rate if multiple apps are sending audio)
                // Trust file-based detection over tap when we have a local file's exact format.
                // The tap can be misleading when multiple apps send audio simultaneously.
                let hasLocalFileFormat = source.source.contains("Music") || source.source == "VLC"
                if hasLocalFileFormat && source.sampleRate > 0 {
                    return source  // File metadata is more accurate for local files
                }

                // For everything else, use the tap's sample rate (it's what's actually
                // being sent to the output) but keep the app name from detection
                return AudioInfo(
                    sampleRate: tap.sampleRate,
                    bitDepth: { if #available(macOS 14.2, *) { return AudioTapDetector.inferBitDepth(sampleRate: tap.sampleRate) } else { return 16 } }(),
                    source: source.source,
                    trackName: source.trackName
                )
            }

            // Tap detected audio but we couldn't identify the app
            return AudioInfo(
                sampleRate: tap.sampleRate,
                bitDepth: { if #available(macOS 14.2, *) { return AudioTapDetector.inferBitDepth(sampleRate: tap.sampleRate) } else { return 16 } }(),
                source: "System Audio",
                trackName: nil
            )
        }

        // No tap available — fall back to app-based detection only
        return activeSource
    }

    // MARK: - AppleScript-based detection (ground truth: checks player state)

    // IMPORTANT: Always check with pgrep BEFORE running AppleScript.
    // `tell application "X"` causes macOS to search for / launch the app,
    // even inside `if exists process` blocks, because the script is compiled
    // before the conditional runs.

    static func detectFromSpotify() -> AudioInfo? {
        guard isProcessRunning("Spotify") else { return nil }

        let checkScript = """
        tell application "Spotify"
            if player state is not playing then return "not_playing"
            set n to name of current track
            set a to artist of current track
            return n & " - " & a
        end tell
        """

        guard let result = runAppleScript(checkScript, timeout: 3) else { return nil }
        if result == "not_playing" { return nil }

        return AudioInfo(
            sampleRate: 44100,
            bitDepth: 16,
            source: "Spotify",
            trackName: result
        )
    }

    static func detectFromMusicApp() -> AudioInfo? {
        guard isProcessRunning("Music") else { return nil }

        let checkScript = """
        tell application "Music"
            if player state is not playing then return "not_playing"
            set t to current track
            try
                set loc to POSIX path of (location of t)
                set n to name of t
                set a to artist of t
                return loc & "|" & n & " - " & a
            on error
                return "no_file"
            end try
        end tell
        """

        guard let result = runAppleScript(checkScript, timeout: 3) else { return nil }
        if result == "not_playing" || result == "no_file" { return nil }

        let parts = result.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let filePath = String(parts[0])
        let trackName = String(parts[1])
        guard let fileInfo = readAudioFileFormat(path: filePath) else { return nil }

        return AudioInfo(
            sampleRate: fileInfo.sampleRate,
            bitDepth: fileInfo.bitDepth,
            source: "Music.app",
            trackName: trackName
        )
    }

    static func detectFromVLC() -> AudioInfo? {
        guard isProcessRunning("VLC") else { return nil }

        let checkScript = """
        tell application "VLC"
            try
                if not playing then return "not_playing"
                set p to path of current item
                set n to name of current item
                return p & "|" & n
            on error
                return "error"
            end try
        end tell
        """

        guard let result = runAppleScript(checkScript, timeout: 3) else { return nil }
        if result == "not_playing" || result == "error" { return nil }

        let parts = result.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let filePath = String(parts[0])
        let trackName = String(parts[1])
        guard let fileInfo = readAudioFileFormat(path: filePath) else { return nil }

        return AudioInfo(
            sampleRate: fileInfo.sampleRate,
            bitDepth: fileInfo.bitDepth,
            source: "VLC",
            trackName: trackName
        )
    }

    // MARK: - MediaRemote Now Playing (universal — browsers, any app)

    static func detectViaNowPlaying() -> AudioInfo? {
        guard let info = NowPlayingDetector.getFullNowPlayingInfo() else { return nil }

        let bundleID = info.appBundleID
        let appName = info.appName
        let title = info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"

        // Skip apps we already checked via AppleScript (they returned nil = not playing)
        let alreadyChecked = ["com.apple.Music", "com.spotify.client"]
        if alreadyChecked.contains(bundleID) { return nil }

        // 1. Known app by bundle ID (exact format known)
        for (prefix, format) in knownAppFormats {
            if bundleID.hasPrefix(prefix) {
                return AudioInfo(
                    sampleRate: format.sampleRate,
                    bitDepth: format.bitDepth,
                    source: appName,
                    trackName: title
                )
            }
        }

        // 2. Browser — identify the streaming service from the page/video title
        if browserBundleIDs.contains(bundleID) {
            let titleLower = title.lowercased()

            for service in streamingServiceFormats {
                if titleLower.contains(service.pattern) {
                    return AudioInfo(
                        sampleRate: service.sampleRate,
                        bitDepth: service.bitDepth,
                        source: "\(appName) — \(service.label)",
                        trackName: title
                    )
                }
            }

            // Generic browser audio (Web Audio API defaults to 48kHz)
            if !title.isEmpty {
                return AudioInfo(
                    sampleRate: 48000,
                    bitDepth: 16,
                    source: appName,
                    trackName: title
                )
            }
        }

        // 3. Apple Music (isMusicApp flag but different bundle ID, e.g. streaming)
        if info.isMusicApp {
            // Try to get file format via lsof
            if let fileDetection = NowPlayingDetector.detectViaOpenFiles() {
                if let fileInfo = readAudioFileFormat(path: fileDetection.path) {
                    return AudioInfo(
                        sampleRate: fileInfo.sampleRate,
                        bitDepth: fileInfo.bitDepth,
                        source: appName,
                        trackName: title
                    )
                }
            }
            // Streaming Apple Music defaults to 44.1kHz AAC (or lossless if enabled)
            return AudioInfo(
                sampleRate: 44100,
                bitDepth: 16,
                source: appName,
                trackName: title
            )
        }

        // 4. Unknown app — try lsof, then default to 44.1kHz
        if !title.isEmpty {
            if let fileDetection = NowPlayingDetector.detectViaOpenFiles() {
                if let fileInfo = readAudioFileFormat(path: fileDetection.path) {
                    return AudioInfo(
                        sampleRate: fileInfo.sampleRate,
                        bitDepth: fileInfo.bitDepth,
                        source: appName,
                        trackName: title
                    )
                }
            }

            return AudioInfo(
                sampleRate: 44100,
                bitDepth: 16,
                source: appName,
                trackName: title
            )
        }

        return nil
    }

    // MARK: - lsof fallback (finds open audio files, can't verify playing state)

    static func detectViaOpenFiles() -> AudioInfo? {
        guard let detected = NowPlayingDetector.detectViaOpenFiles() else { return nil }
        guard let fileInfo = readAudioFileFormat(path: detected.path) else { return nil }

        let trackName = (detected.path as NSString).lastPathComponent
        return AudioInfo(
            sampleRate: fileInfo.sampleRate,
            bitDepth: fileInfo.bitDepth,
            source: detected.app,
            trackName: trackName
        )
    }

    // MARK: - File Format Reading

    struct FileFormat {
        let sampleRate: Float64
        let bitDepth: UInt32
    }

    static func readAudioFileFormat(path: String) -> FileFormat? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var audioFileID: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFileID)
        guard status == noErr, let fileID = audioFileID else {
            return readWithAVAudioFile(url: url)
        }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let propStatus = AudioFileGetProperty(
            fileID, kAudioFilePropertyDataFormat, &dataSize, &asbd
        )
        guard propStatus == noErr else {
            return readWithAVAudioFile(url: url)
        }

        let bitDepth: UInt32
        if asbd.mBitsPerChannel > 0 {
            bitDepth = asbd.mBitsPerChannel
        } else {
            var srcBitDepth: UInt32 = 0
            var srcSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileGetProperty(fileID, kAudioFilePropertySourceBitDepth, &srcSize, &srcBitDepth) == noErr {
                bitDepth = srcBitDepth > 0 ? srcBitDepth : 16
            } else {
                bitDepth = 16
            }
        }

        return FileFormat(sampleRate: asbd.mSampleRate, bitDepth: bitDepth)
    }

    private static func readWithAVAudioFile(url: URL) -> FileFormat? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        return FileFormat(
            sampleRate: format.sampleRate,
            bitDepth: UInt32(format.streamDescription.pointee.mBitsPerChannel)
        )
    }

    // MARK: - Helpers

    /// Run AppleScript with a timeout. Returns nil on timeout or error.
    private static func runAppleScript(_ script: String, timeout: TimeInterval = 5) -> String? {
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                semaphore.signal()
                return
            }
            let output = appleScript.executeAndReturnError(&error)
            if error == nil {
                result = output.stringValue
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return result
    }

    static func isProcessRunning(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }
}
