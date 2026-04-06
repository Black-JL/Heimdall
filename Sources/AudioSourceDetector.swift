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

    // MARK: - Known streaming service output formats

    private static let streamingFormats: [String: (sampleRate: Float64, bitDepth: UInt32)] = [
        "spotify": (44100, 16),
        "youtube": (48000, 16),
        "youtube music": (48000, 16),
        "netflix": (48000, 16),
        "apple tv": (48000, 16),
        "disney": (48000, 16),
        "hbo": (48000, 16),
        "amazon music": (44100, 16),
        "tidal": (44100, 16),
        "deezer": (44100, 16),
        "soundcloud": (44100, 16),
        "pandora": (44100, 16),
        "twitch": (48000, 16),
    ]

    private static let browsers = Set(["chrome", "safari", "firefox", "brave", "arc", "edge", "opera", "google chrome", "microsoft edge"])

    // MARK: - Main detection entry point

    /// Detect what's currently playing. Uses multiple methods and picks the most
    /// reliable result. AppleScript player-state checks are ground truth for
    /// "is this app actually playing right now."
    static func detectCurrentAudio() -> AudioInfo? {
        // Step 1: Check known players via AppleScript (most reliable — verifies playing state)
        // Run these checks first because they definitively answer "is X playing?"
        var activeSource: AudioInfo?

        // Check Spotify (fast check, known format, very common)
        if let info = detectFromSpotify() {
            activeSource = info
        }

        // Check Music.app — but only prefer it over Spotify if Spotify isn't playing
        if activeSource == nil, let info = detectFromMusicApp() {
            activeSource = info
        }

        // Check VLC
        if activeSource == nil, let info = detectFromVLC() {
            activeSource = info
        }

        // If an AppleScript source was found, trust it — it verified playing state
        if let source = activeSource {
            return source
        }

        // Step 2: MediaRemote Now Playing API (catches browsers, other apps)
        if let info = detectViaNowPlaying() {
            return info
        }

        // Step 3: lsof fallback (finds open audio files — less reliable, can't verify playing)
        if let info = detectViaOpenFiles() {
            return info
        }

        return nil
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

    // MARK: - MediaRemote Now Playing (universal — browsers, other apps)

    static func detectViaNowPlaying() -> AudioInfo? {
        guard let nowPlaying = NowPlayingDetector.detectViaNowPlaying() else { return nil }

        let appName = nowPlaying.app
        let title = nowPlaying.title

        // Don't return results for apps we already checked via AppleScript
        // (they returned nil, meaning they're not playing)
        let alreadyChecked = ["spotify", "music", "vlc"]
        if alreadyChecked.contains(where: { appName.lowercased().contains($0) }) {
            return nil
        }

        // Known streaming service by app name
        for (service, format) in streamingFormats {
            if appName.lowercased().contains(service) {
                return AudioInfo(
                    sampleRate: format.sampleRate,
                    bitDepth: format.bitDepth,
                    source: appName,
                    trackName: title
                )
            }
        }

        // Browser-based audio
        if browsers.contains(where: { appName.lowercased().contains($0) }) {
            // Check title for streaming service hints
            let titleLower = title.lowercased()
            for (service, format) in streamingFormats {
                if titleLower.contains(service) {
                    return AudioInfo(
                        sampleRate: format.sampleRate,
                        bitDepth: format.bitDepth,
                        source: "\(appName) (\(service.capitalized))",
                        trackName: title
                    )
                }
            }
            // Generic browser audio — Web Audio API defaults to 48kHz
            if !title.isEmpty {
                return AudioInfo(
                    sampleRate: 48000,
                    bitDepth: 16,
                    source: appName,
                    trackName: title
                )
            }
        }

        // Unknown app with a title — use a safe default
        if !title.isEmpty {
            // Try to find an open audio file from this app
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
