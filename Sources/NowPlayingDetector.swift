import Foundation

/// Detects currently playing audio using multiple methods that don't require AppleScript permissions.
struct NowPlayingDetector {

    // MARK: - Method 1: MRMediaRemoteGetNowPlayingInfo (private framework)
    // We use the command-line `nowplaying-cli` approach via MediaRemote notifications

    /// Use MediaRemote private framework to get now playing info.
    static func detectViaNowPlaying() -> (app: String, title: String)? {
        return loadNowPlayingInfo()
    }

    private static func loadNowPlayingInfo() -> (app: String, title: String)? {
        // Load MediaRemote framework dynamically
        guard let bundle = CFBundleCreate(kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            return nil
        }

        // Get the function pointer for MRMediaRemoteGetNowPlayingInfo
        guard let funcPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
            return nil
        }

        typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let getNowPlayingInfo = unsafeBitCast(funcPtr, to: MRMediaRemoteGetNowPlayingInfoFunction.self)

        var result: (app: String, title: String)?
        let semaphore = DispatchSemaphore(value: 0)

        getNowPlayingInfo(DispatchQueue.global()) { info in
            if let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String {
                let app = info["kMRMediaRemoteNowPlayingInfoClientPropertiesDeviceName"] as? String ?? "Unknown"
                let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let fullTitle = artist.isEmpty ? title : "\(title) - \(artist)"
                result = (app: app, title: fullTitle)
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2.0)
        return result
    }

    // MARK: - Method 2: Find open audio files via lsof

    /// Find audio files currently opened by known music players.
    static func detectViaOpenFiles() -> (path: String, app: String)? {
        let players = ["Music", "Spotify", "VLC", "Swinsian", "Audirvana", "Amarra", "Vox", "Colibri", "foobar2000"]
        let audioExtensions = Set(["flac", "alac", "aiff", "aif", "wav", "m4a", "mp3", "ogg", "opus", "dsf", "dff", "ape", "wv", "caf"])

        // Use lsof to find open files by music player processes
        for player in players {
            if let file = findOpenAudioFile(processName: player, extensions: audioExtensions) {
                return (path: file, app: player)
            }
        }
        return nil
    }

    private static func findOpenAudioFile(processName: String, extensions: Set<String>) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-c", processName, "-Fn", "+D", "/"]
        // lsof can be slow with +D /, let's use a different approach

        // Better: use pgrep + lsof with pid
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

        // Get the first PID
        let pid = pidStr.components(separatedBy: "\n").first ?? pidStr

        // Now lsof for that PID
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

        // Parse lsof output — lines starting with "n" are file names
        for line in lsofStr.components(separatedBy: "\n") {
            guard line.hasPrefix("n/") else { continue }
            let path = String(line.dropFirst()) // Remove the "n" prefix
            let ext = (path as NSString).pathExtension.lowercased()
            if extensions.contains(ext) {
                return path
            }
        }

        return nil
    }

}
