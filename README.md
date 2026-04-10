# Heimdall — Source Matching Audio Switcher

**Automatically matches your external DAC's sample rate to whatever you're playing, so macOS stops resampling your music.**

---

## The Problem

macOS sends all audio to your external DAC at a single fixed sample rate — whatever you last set in Audio MIDI Setup. It never changes this automatically.

macOS is perfectly capable of sending bit-perfect audio over USB or optical to an external DAC, which allows your DAC to work from the actual quality of the original music. But it only does this when the source format happens to match the rate that's already set. The rest of the time, macOS resamples: if your DAC is set to 96 kHz and you play a 44.1 kHz song, macOS upsamples it. If your DAC is at 44.1 kHz and you play a 96 kHz hi-res file, macOS downsamples it. Your DAC ends up converting a signal that's already been converted — and depending on your DAC, that may make a real difference in what you hear.

Apple's own fix ([support.apple.com/en-us/108326](https://support.apple.com/en-us/108326)) is to open Audio MIDI Setup and manually change the rate every time you switch between tracks at different resolutions. That's tedious.

Heimdall does it automatically.

## What It Does

Heimdall runs in the background, monitors what you're listening to, detects the native sample rate of the source, and switches your DAC to match — in real time, every time the source changes.

**44.1 kHz song? DAC switches to 44.1 kHz. 96 kHz hi-res track? DAC switches to 96 kHz. YouTube video at 48 kHz? DAC switches to 48 kHz.**

Your music arrives at the DAC exactly as it was recorded. No resampling. No manual intervention.

### Without Heimdall
```
Your Music (44.1 kHz) → macOS Resampler → DAC (locked at 96 kHz)
                              ↑
                    Unnecessary conversion
```

### With Heimdall
```
Your Music (44.1 kHz) → Heimdall switches DAC to 44.1 kHz → DAC (44.1 kHz)
                                                                   ↑
                                                          Original signal, untouched
```

## The Name

In Norse mythology, **Heimdall** is the guardian of the Bifrost bridge — the keenest listener among the gods, said to be able to hear grass growing and see for hundreds of miles. He stands eternal watch, ensuring that only what belongs crosses the bridge.

This app stands watch over your audio signal path, ensuring that only the original, unmodified signal reaches your DAC — guarding it from the unnecessary resampling that macOS applies by default.

The Norse mythology naming — Heimdall, Bifrost — is a purposeful nod to my preference for and current use of [Schiit Audio](https://www.schiit.com/) products. This project is not affiliated with, endorsed by, or associated with Schiit Audio in any way. To my knowledge, they've never heard of me except as a customer. If Schiit Audio would prefer I not reference their product names, I will change the naming immediately — I have no interest in appearing to represent or speak for their brand.

## How It Detects the Source Format

Heimdall uses multiple detection methods, prioritized for accuracy:

| Source | How Heimdall Detects It | What It Sends to the DAC |
|--------|------------------------|--------------------------|
| **Apple Music (local files)** | Reads the actual file's metadata — sample rate, bit depth, codec | The file's native format (e.g. 24-bit/96 kHz ALAC) |
| **Apple Music (streaming)** | Reads the cached file's metadata | The stream's native format |
| **Spotify** | Identifies Spotify as the source via system APIs | 44.1 kHz / 16-bit (Spotify's fixed output) |
| **YouTube / YouTube Music** | Identifies Chrome/Safari via system APIs | 48 kHz / 16-bit (YouTube's fixed output) |
| **VLC** | Reads the playing file's metadata | The file's native format |
| **Any browser audio** | Identifies the browser via system APIs | 48 kHz / 16-bit (Web Audio API default) |
| **Any other app** | CoreAudio process tap reads the actual system audio format | Whatever format is flowing to the output |

For local files, Heimdall reads the actual audio metadata using Apple's AudioToolbox APIs — `AudioFileOpenURL` and `AudioFileGetProperty` on the `AudioStreamBasicDescription`. This gives the exact native sample rate and bit depth of the recording.

For streaming services and browsers, the output format is fixed regardless of the stream quality (Spotify always outputs 44.1 kHz; YouTube always outputs 48 kHz), so Heimdall applies the correct rate directly.

## Supported DACs

Heimdall **auto-detects** any USB DAC connected to your Mac. It identifies external audio devices by their USB transport type and automatically filters out:

- Built-in speakers and microphones
- Apple displays (Studio Display, Pro Display XDR)
- Virtual audio devices (Teams, Zoom, BlackHole, etc.)
- Bluetooth audio devices

**Tested with:**
- Schiit Bifrost (original, Unison USB) — 44.1k, 48k, 88.2k, 96k, 176.4k, 192k Hz
- Should work with any USB Audio Class 2 DAC: Schiit, Topping, SMSL, RME, Chord, iFi, Cambridge, Dragonfly, etc.

When you plug in your DAC, Heimdall finds it automatically. When you unplug it, Heimdall waits quietly until it comes back.

## Features

- **Automatic sample rate switching** — Matches your DAC to the source: 44.1, 48, 88.2, 96, 176.4, or 192 kHz
- **Source format detection** — Reads actual file metadata for local files; uses known formats for streaming services
- **Auto-detect any USB DAC** — No configuration needed. Plug in your DAC and Heimdall finds it.
- **Live activity window** — Shows what's playing, the source format, and every switch as it happens
- **Menu bar controls** (♪) — Manual rate override if you need it
- **USB hot-plug support** — Detects DAC connect/disconnect events in real time
- **Login item** — Can start automatically when you log in
- **About dialog** — Explains what the app does and why it's named Heimdall
- **Lightweight** — 250 KB binary. Polls every 2 seconds. Negligible CPU usage.
- **Open source** — MIT license. Read the code, modify it, contribute to it.

## Installation

### DMG Installer (easiest)

Download `Heimdall-1.0.dmg` from [Releases](https://github.com/Black-JL/Heimdall/releases), open it, and drag Heimdall to your Applications folder.

### From source

```bash
git clone https://github.com/Black-JL/Heimdall.git
cd Heimdall
./install.sh
```

This builds a release binary, copies it to `/Applications`, and adds it as a login item.

### Manual build

```bash
swift build -c release
```

Binary is at `.build/release/Heimdall`.

### Uninstall

```bash
./uninstall.sh
```

Or: quit the app, delete it from `/Applications`, remove from System Settings > General > Login Items.

## Usage

### As an app (recommended)

Open Heimdall from Spotlight (**Cmd+Space → "Heimdall"**) or your Applications folder.

You'll see:
- A **live log window** showing what's playing and when the DAC switches
- A **menu bar icon** (♪) with your DAC's current rate and manual controls
- The **Heimdall banner** with a description of what the app does

Leave it running. It handles everything automatically.

### Command line

```bash
# Terminal output mode
Heimdall --cli

# Target a specific DAC by name
Heimdall --cli --device "Modi"

# Faster polling
Heimdall --cli --interval 1.0

# Enable exclusive/hog mode (takes sole control of the DAC)
Heimdall --cli --hog
```

## Architecture

```
Sources/
├── main.swift                 # Entry point — CLI and GUI modes
├── AudioDeviceManager.swift   # CoreAudio: find DACs, query rates, switch formats
├── AudioMatcher.swift         # Core engine: poll, detect, switch, debounce
├── AudioSourceDetector.swift  # Multi-method source format detection
├── AudioTapDetector.swift     # CoreAudio process tap (macOS 14.2+)
├── NowPlayingDetector.swift   # MediaRemote API + lsof detection
├── MenuBarApp.swift           # Menu bar UI
└── LogWindow.swift            # Live activity window with banner
```

### Key CoreAudio APIs Used

| API | What It Does |
|-----|-------------|
| `kAudioDevicePropertyNominalSampleRate` | Gets/sets the device's sample rate |
| `kAudioStreamPropertyPhysicalFormat` | Gets/sets the stream's bit depth and format |
| `kAudioStreamPropertyAvailablePhysicalFormats` | Queries what formats the DAC supports |
| `kAudioDevicePropertyTransportType` | Identifies USB vs built-in vs virtual devices |
| `kAudioHardwarePropertyDevices` | Lists all audio devices; listener detects plug/unplug |
| `AudioHardwareCreateProcessTap` | Taps system audio to detect the output format (macOS 14.2+) |
| `AudioFileOpenURL` + `kAudioFilePropertyDataFormat` | Reads native format from audio files |

## Known Limitations

- **macOS only** — CoreAudio APIs are macOS-specific
- **Detection has a ~2 second delay** — Heimdall polls every 2 seconds, so there's a brief moment of wrong-rate audio when switching tracks
- **Streaming services have fixed formats** — Spotify is always 44.1 kHz, YouTube is always 48 kHz, regardless of your subscription tier
- **First launch may request permissions** — Automation access for Music.app/Spotify, and System Audio Recording for the process tap

## Background

This project started because of a simple annoyance: playing music through a Schiit Bifrost DAC on a Mac, and realizing that macOS was resampling everything to whatever rate happened to be set in Audio MIDI Setup. Switching between a 44.1 kHz Spotify playlist and 96 kHz hi-res FLAC files meant the DAC was almost never receiving the original signal.

Apple's solution — manually opening Audio MIDI Setup and changing the rate for every track — isn't realistic. The existing alternatives are either dead (BitPerfect), Apple Music-only (LosslessSwitcher), or $120+ full-blown music players (Audirvana, Roon) that replace your entire audio workflow.

Heimdall is the lightweight, single-purpose fix: it just matches the rate, for everything, automatically.

## Maintenance

I use Heimdall myself every day, so I'll keep it up to date whenever I have a reason to — if a macOS update breaks something, I'll fix it on my own machine and push the update here. That said, I make no promise, express or implied, to keep this project maintained for anyone else. It's a side project from a college professor, not a commercial product with a support team.

This currently works on macOS only (Apple Silicon and Intel). The code is Swift and relies on Apple's CoreAudio APIs, which don't exist on other platforms. If you're on Linux or Windows and want to adapt this, you're welcome to — the core logic in `AudioMatcher.swift` is platform-agnostic, and `AudioDeviceManager.swift` is where all the macOS-specific calls live.

## Contributing

- **New audio sources**: Add to the `knownAppFormats` or `streamingServiceFormats` dictionaries in `AudioSourceDetector.swift`
- **New platforms**: Replace `AudioDeviceManager.swift` with ALSA (Linux) or WASAPI (Windows) implementations
- **New DACs**: Should work automatically. If yours isn't detected, [open an issue](https://github.com/Black-JL/Heimdall/issues) and include the output of `system_profiler SPAudioDataType` so I can see how your DAC identifies itself.

Pull requests welcome.

## License

MIT — see [LICENSE](LICENSE) for the full text. In short: do whatever you want with this code, but it comes with no warranty. If it breaks your audio setup, that's on you.

## Credits

Built by a college professor who got tired of opening Audio MIDI Setup.

Named after the Norse god who stands eternal watch — because your DAC deserves a proper guardian.
