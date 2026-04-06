import Foundation

/// Detects currently playing audio using macOS MediaRemote framework and lsof.
struct NowPlayingDetector {

    /// Info from the system's Now Playing center.
    struct NowPlayingInfo {
        let appBundleID: String
        let appName: String
        let title: String
        let artist: String
        let isMusicApp: Bool
    }

    // MARK: - MediaRemote Now Playing (universal)

    static func detectViaNowPlaying() -> (app: String, title: String)? {
        guard let info = getFullNowPlayingInfo() else { return nil }
        let fullTitle = info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"
        return (app: info.appName, title: fullTitle)
    }

    /// Get detailed now playing info including bundle ID.
    /// Uses MediaRemote private framework with safe memory management.
    static func getFullNowPlayingInfo() -> NowPlayingInfo? {
        guard let bundle = loadMediaRemoteBundle() else { return nil }

        // Get the now playing client (app name + bundle ID)
        var appBundleID = ""
        var appName = ""

        if let clientPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) {
            typealias GetClientFunc = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
            let getClient = unsafeBitCast(clientPtr, to: GetClientFunc.self)
            let sem = DispatchSemaphore(value: 0)

            getClient(DispatchQueue.global()) { client in
                defer { sem.signal() }
                guard let client = client as? NSObject else { return }

                // Safe property access via value(forKey:) instead of perform(Selector)
                if let bid = client.value(forKey: "bundleIdentifier") as? String {
                    appBundleID = bid
                }
                if let dn = client.value(forKey: "displayName") as? String {
                    appName = dn
                }
            }
            _ = sem.wait(timeout: .now() + 2.0)
        }

        // Get the now playing info (track details)
        guard let infoPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
            return nil
        }

        typealias GetInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let getInfo = unsafeBitCast(infoPtr, to: GetInfoFunc.self)

        var result: NowPlayingInfo?
        let sem = DispatchSemaphore(value: 0)

        getInfo(DispatchQueue.global()) { info in
            defer { sem.signal() }
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
