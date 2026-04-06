# Heimdall — Lossless Audio Switcher

**Automatic bit-perfect sample rate switching for external DACs on macOS.**

*In Norse mythology, Heimdall is the guardian of the Bifrost bridge — the keenest listener among the gods. This app guards the signal path to your DAC, ensuring only the native audio format crosses the bridge to your headphones.*

---

## Why This Exists

macOS doesn't change your audio output device's sample rate when you switch between tracks of different resolutions. If your DAC is set to 96 kHz and you play a 44.1 kHz CD-quality track, macOS silently resamples the audio before it reaches your DAC. Your expensive hardware never sees the original signal.

This matters if you have a decent external DAC, a good amp, and good headphones. The DAC's job is digital-to-analog conversion — it should be doing that work, not your computer's built-in resampler. Whether the difference is audible is debatable, but if you've invested in the hardware, you should at least be feeding it the right signal.

Heimdall fixes this. It monitors what you're playing, reads the native format, and automatically switches your DAC to match. No resampling. No manual trips to Audio MIDI Setup. Just the original signal, straight to your DAC.

## What It Does

1. **Auto-detects** your external USB DAC — no configuration needed
2. **Detects** the native format of whatever audio is currently playing — sample rate and bit depth
3. **Switches** your DAC's output format to match, using the same CoreAudio APIs as Audio MIDI Setup
4. **Sets the physical stream format** to match the source bit depth

The result: your music files → CoreAudio → your DAC, at the source's native sample rate. No resampling by macOS.

Optionally, you can enable **Hog Mode** for exclusive device access, which bypasses macOS's audio mixer entirely for a true bit-perfect signal path.

## Features

- **Automatic sample rate switching** — Matches your DAC to the source: 44.1, 48, 88.2, 96, 176.4, or 192 kHz
- **Bit-perfect output** — Hog Mode + integer physical format bypasses CoreAudio's mixer and sample rate converter
- **Works with everything** — Spotify, Apple Music, YouTube Music, VLC, browser audio, and any other audio source
- **Live activity window** — Color-coded log shows every format switch as it happens
- **Menu bar controls** — Quick access to manual rate override and bit-perfect toggle
- **USB hot-plug support** — Detects when your DAC is connected/disconnected and activates automatically
- **Login item** — Starts automatically when you log in
- **Zero configuration** — Finds your DAC, starts monitoring, switches rates. That's it.

## Screenshots

When running, Heimdall shows a live log window:

```
[8:42:15 PM] Heimdall started
[8:42:15 PM] Connected — Schiit Bifrost Unison USB
[8:42:15 PM] ✓ Hog mode acquired — exclusive device access (bit-perfect)
[8:42:17 PM] ▶ Now playing: 16-bit / 44100 Hz [Spotify] — Shadows Understand Me - Hyperbolic Club
[8:42:17 PM]   ↻ Switching 96000 Hz → 44100 Hz...
[8:42:17 PM]   ✓ Now at 44100 Hz / 16-bit (bit-perfect)
[8:42:45 PM] ▶ Now playing: 24-bit / 96000 Hz [Music.app] — Moanin' - Art Blakey
[8:42:45 PM]   ↻ Switching 44100 Hz → 96000 Hz...
[8:42:46 PM]   ✓ Now at 96000 Hz / 24-bit (bit-perfect)
```

The status bar at the top shows your DAC connection, current format, and bit-perfect mode status. A ♪ menu bar icon provides quick access to manual controls.

## Supported DACs

Heimdall **auto-detects** any USB DAC connected to your Mac. It identifies external DACs by their USB transport type and filters out built-in speakers, Apple displays, and virtual audio devices.

Tested with:

- **Schiit Bifrost** (original, Unison USB)
- Should work with any Schiit DAC (Modi, Gungnir, Yggdrasil, etc.)
- Should work with any USB Audio Class 2 DAC (Topping, SMSL, RME, Chord, etc.)

If you have multiple external DACs or need to target a specific one:

```bash
Heimdall --cli --device "Topping D90"
```

## Supported Audio Sources

| Source | Detection Method | Format |
|--------|-----------------|--------|
| Apple Music (local files) | File metadata via lsof + AudioToolbox | Native (e.g. 24-bit/96kHz ALAC) |
| Apple Music (streaming) | AppleScript + file metadata | Native format of cached file |
| Spotify | AppleScript / MediaRemote | 44.1 kHz / 16-bit |
| YouTube Music (browser) | MediaRemote Now Playing | 48 kHz / 16-bit |
| YouTube (browser) | MediaRemote Now Playing | 48 kHz / 16-bit |
| VLC | AppleScript + file metadata | Native file format |
| Any browser audio | MediaRemote Now Playing | 48 kHz / 16-bit |
| Any other app | MediaRemote Now Playing | 44.1 kHz / 16-bit (default) |

For local files, Heimdall reads the actual audio format metadata (sample rate, bit depth, codec) using Apple's AudioToolbox APIs. For streaming services, it uses known output formats since the audio is decoded to a fixed PCM format regardless of the stream quality.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel Mac
- A USB DAC

## Installation

### Quick install

```bash
git clone https://github.com/YOUR_USERNAME/Heimdall.git
cd Heimdall
./install.sh
```

This builds the app, copies it to `/Applications`, and adds it as a login item so it starts automatically.

### Manual build

```bash
swift build -c release
```

The binary is at `.build/release/Heimdall`. Run it directly or copy it wherever you like.

### Uninstall

```bash
./uninstall.sh
```

Or: quit the app, delete `/Applications/Heimdall.app`, and remove it from System Settings > General > Login Items.

## Usage

### As an app (recommended)

Open **Heimdall** from Spotlight (Cmd+Space → "Heimdall") or your Applications folder. You'll see:

- A **log window** with live, color-coded activity
- A **menu bar icon** (♪) with manual rate controls and a bit-perfect toggle
- A **dock icon** so you can tell it's running

Just leave it running. It handles everything automatically.

### Command line

```bash
# Run with terminal output
Heimdall --cli

# Target a specific DAC (default: auto-detect)
Heimdall --cli --device "Modi"

# Enable exclusive/hog mode for true bit-perfect output
# (Note: this takes exclusive control — other apps can't use the DAC)
Heimdall --cli --hog

# Faster polling (default is 2 seconds)
Heimdall --cli --interval 1.0
```

## How It Works

### The macOS Audio Problem

```
Your Music (44.1kHz) ──→ CoreAudio Mixer ──→ Resampler ──→ DAC (locked at 96kHz)
                              ↑                    ↑
                          Float conversion    Sample rate conversion
                          (loses precision)   (degrades signal)
```

### With Heimdall

```
Your Music (44.1kHz) ──→ Heimdall sets DAC to 44.1kHz ──→ DAC (44.1kHz, integer)
                              ↑                                    ↑
                          Hog Mode                          No conversion needed
                          (bypasses mixer)                  (bit-perfect signal)
```

### Detection Pipeline

1. **MediaRemote API** — Queries macOS's system-wide Now Playing info. Works for Spotify, browsers (YouTube Music, etc.), and most apps without needing special permissions.
2. **AppleScript** — For Music.app, Spotify, and VLC: verifies the player is actively playing (not just open) and gets track info. Has a timeout to prevent hangs.
3. **lsof + AudioToolbox** — Finds audio files currently opened by music player processes, then reads native sample rate and bit depth from the file metadata. This is the most accurate method for local files.

### Architecture

```
Sources/
├── main.swift                 # Entry point — CLI and GUI modes
├── AudioDeviceManager.swift   # CoreAudio device control (find, query, switch, hog mode)
├── AudioMatcher.swift         # Core engine — polling, detection, switching logic (HeimdallEngine)
├── AudioSourceDetector.swift  # Multi-method audio source format detection
├── NowPlayingDetector.swift   # MediaRemote API + lsof-based detection
├── MenuBarApp.swift           # Menu bar UI with controls
└── LogWindow.swift            # Live activity log window
```

## Known Limitations

- **macOS only** — CoreAudio APIs are macOS-specific. Linux (ALSA/PipeWire) and Windows (WASAPI exclusive mode) would need platform-specific implementations.
- **Hog mode is opt-in and exclusive** — When enabled via `--hog` or the menu bar toggle, only one app can use the DAC. System sounds and notifications won't play through it. This is off by default.
- **Detection delay** — Heimdall polls every 2 seconds, so there can be a brief moment of wrong-rate audio when switching tracks. This is a deliberate tradeoff — faster polling increases CPU usage for minimal benefit.
- **Streaming services have fixed formats** — Spotify is always 44.1 kHz, YouTube is always 48 kHz. This is their limitation, not Heimdall's.
- **AppleScript permissions** — First launch may prompt you to allow Automation access for Music.app and Spotify. Grant it for best detection.

## Contributing

The architecture is designed to be extensible:

- **New audio sources**: Add detection logic to `AudioSourceDetector.swift` or update the `streamingFormats` dictionary
- **New platforms**: Replace `AudioDeviceManager.swift` with platform-specific audio APIs (ALSA, WASAPI, PipeWire)
- **New DACs**: Should work out of the box — just use `--device "YourDACName"`

Pull requests welcome.

## License

MIT

## Credits

Built for the audiophile who's tired of opening Audio MIDI Setup every time a song changes.

Named after the Norse god who guards the Bifrost bridge — because your DAC deserves a proper watchman.
