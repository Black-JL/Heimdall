import CoreAudio
import AudioToolbox
import Foundation

/// The format of audio currently flowing to the system output.
struct TapFormat {
    let sampleRate: Float64
    let bitsPerChannel: UInt32
    let channelsPerFrame: UInt32
}

/// Detects the actual sample rate of audio flowing through the system output
/// using Core Audio Process Taps. Works for ANY app — no app-specific logic needed.
/// Requires macOS 14.2+.
@available(macOS 14.2, *)
struct AudioTapDetector {

    /// Detect the actual audio format being sent to the system output.
    /// Creates a momentary process tap, reads the format, and destroys it.
    static func detectOutputFormat() -> TapFormat? {
        // Suppress the forced downcast warning
        @inline(never) func createTap(_ obj: AnyObject) -> (OSStatus, AudioObjectID) {
            var tapID: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(unsafeBitCast(obj, to: CATapDescription.self), &tapID)
            return (status, tapID)
        }
        guard let tapClass = NSClassFromString("CATapDescription") as? NSObject.Type else {
            return nil
        }

        // Create a stereo global tap (captures all audio going to output)
        let tapObj = tapClass.init()
        guard let tap = tapObj.perform(
            NSSelectorFromString("initStereoGlobalTapButExcludeProcesses:"),
            with: [] as NSArray
        )?.takeUnretainedValue() else {
            return nil
        }

        // Create the process tap
        let (status, tapID) = createTap(tap)
        guard status == noErr, tapID != 0 else { return nil }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        // Read the tap's format: kAudioTapPropertyFormat = 'tfmt' = 0x74666D74
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74666D74,  // kAudioTapPropertyFormat
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &formatSize, &format) == noErr else {
            return nil
        }

        // The tap reports 32-bit float (CoreAudio's internal format).
        // The sample rate is what matters — it reflects what apps are sending.
        guard format.mSampleRate > 0 else { return nil }

        return TapFormat(
            sampleRate: format.mSampleRate,
            bitsPerChannel: format.mBitsPerChannel,
            channelsPerFrame: format.mChannelsPerFrame
        )
    }

    /// Map a detected tap sample rate to the likely source bit depth.
    /// The tap always reports 32-bit float (CoreAudio's mixer format),
    /// so we infer bit depth from the sample rate family.
    static func inferBitDepth(sampleRate: Float64) -> UInt32 {
        // Hi-res rates (88.2k+) are almost always 24-bit sources
        // Standard rates (44.1k, 48k) could be 16 or 24-bit
        switch Int(sampleRate) {
        case 176400, 192000, 352800, 384000:
            return 24
        case 88200, 96000:
            return 24
        default:
            return 16
        }
    }
}
