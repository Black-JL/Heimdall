import Foundation

/// Detects currently playing audio using macOS MediaRemote framework and lsof.
struct NowPlayingDetector {

    /// Info from the system's Now Playing center.
    struct NowPlayingInfo {
        let appBundleID: String    // e.g. "com.apple.Music", "com.spotify.client", "com.google.Chrome"
        let appName: String        // e.g. "Music", "Spotify", "Google Chrome"
        let title: String          // Track/video title
        let artist: String         // Artist (may be empty)
        let isMusicApp: Bool       // true if Apple Music
    }

    // MARK: - MediaRemote Now Playing (universal)

    /// Get now playing info from macOS MediaRemote framework.
    /// Works for any app that registers with the Now Playing system:
    /// Music.app, Spotify, Chrome (YouTube), Safari, etc.
    static func detectViaNowPlaying() -> (app: String, title: String)? {
        guard let info = getFullNowPlayingInfo() else { return nil }
        let fullTitle = info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"
        return (app: info.appName, title: fullTitle)
    }

    /// Get detailed now playing info including bundle ID.
    static func getFullNowPlayingInfo() -> NowPlayingInfo? {
        guard let bundle = loadMediaRemoteBundle() else { return nil }

        // Step 1: Get the now playing client (tells us which app)
        var appBundleID = ""
        var appName = ""

        if let clientPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) {
            typealias GetClientFunc = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
            let getClient = unsafeBitCast(clientPtr, to: GetClientFunc.self)
            let clientSem = DispatchSemaphore(value: 0)

            getClient(DispatchQueue.global()) { client in
                if let client = client {
                    if client.responds(to: Selector(("bundleIdentifier"))) {
                        appBundleID = client.perform(Selector(("bundleIdentifier")))?.takeUnretainedValue() as? String ?? ""
                    }
                    if client.responds(to: Selector(("displayName"))) {
                        appName = client.perform(Selector(("displayName")))?.takeUnretainedValue() as? String ?? ""
                    }
                }
                clientSem.signal()
            }
            _ = clientSem.wait(timeout: .now() + 2.0)
        }

        // Step 2: Get the now playing info (tells us track details)
        guard let infoPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
            return nil
        }

        typealias GetInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let getInfo = unsafeBitCast(infoPtr, to: GetInfoFunc.self)

        var result: NowPlayingInfo?
        let sem = DispatchSemaphore(value: 0)

        getInfo(DispatchQueue.global()) { info in
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let isMusicApp = (info["kMRMediaRemoteNowPlayingInfoIsMusicApp"] as? Int) == 1

            if !title.isEmpty {
                result = NowPlayingInfo(
                    appBundleID: appBundleID,
                    appName: appName.isEmpty ? "Unknown" : appName,
                    title: title,
                    artist: artist,
                    isMusicApp: isMusicApp
                )
            }
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 2.0)
        return result
    }

    // MARK: - MediaRemote Framework Loading

    private static var _mediaRemoteBundle: CFBundle?
    private static func loadMediaRemoteBundle() -> CFBundle? {
        if let existing = _mediaRemoteBundle { return existing }
        let bundle = CFBundleCreate(kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
        _mediaRemoteBundle = bundle
        return bundle
    }

    // MARK: - Open audio file detection (lsof)

    /// Find audio files currently opened by known music players.
    static func detectViaOpenFiles() -> (path: String, app: String)? {
        let players = ["Music", "Spotify", "VLC", "Swinsian", "Audirvana", "Amarra", "Vox", "Colibri", "foobar2000"]
        let audioExtensions = Set(["flac", "alac", "aiff", "aif", "wav", "m4a", "mp3", "ogg", "opus", "dsf", "dff", "ape", "wv", "caf"])

        for player in players {
            if let file = findOpenAudioFile(processName: player, extensions: audioExtensions) {
                return (path: file, app: player)
            }
        }
        return nil
    }

    private static func findOpenAudioFile(processName: String, extensions: Set<String>) -> String? {
        // Use pgrep to find PID first (fast, no side effects)
        let pgrepTask = Process()
        pgrepTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrepTask.arguments = ["-x", processName]
        let pgrepPipe = Pipe()
        pgrepTask.standardOutput = pgrepPipe
        pgrepTask.standardError = FileHandle.nullDevice

        do {
            try pgrepTask.run()
            pgrepTask.waitUntilExit()
        } catch { return nil }

        let pidData = pgrepPipe.fileHandleForReading.readDataToEndOfFile()
        guard let pidStr = String(data: pidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pidStr.isEmpty else { return nil }

        let pid = pidStr.components(separatedBy: "\n").first ?? pidStr

        // lsof for that PID
        let lsofTask = Process()
        lsofTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofTask.arguments = ["-p", pid, "-Fn"]
        let lsofPipe = Pipe()
        lsofTask.standardOutput = lsofPipe
        lsofTask.standardError = FileHandle.nullDevice

        do {
            try lsofTask.run()
            lsofTask.waitUntilExit()
        } catch { return nil }

        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        guard let lsofStr = String(data: lsofData, encoding: .utf8) else { return nil }

        for line in lsofStr.components(separatedBy: "\n") {
            guard line.hasPrefix("n/") else { continue }
            let path = String(line.dropFirst())
            let ext = (path as NSString).pathExtension.lowercased()
            if extensions.contains(ext) {
                return path
            }
        }

        return nil
    }
}
