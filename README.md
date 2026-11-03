# Audio Router

A small macOS app that processes live system audio with a chain of Audio Unit effects.

- **Input**:
  - *System Audio* — everything that plays on the Mac, via a Core Audio process tap. The original
    audio is muted while it's tapped, and Audio Router's own output is excluded.
  - *Audio Router (virtual device)* — a virtual output device (see below) that apps can play into.
  - Any other input device (microphone, interface, BlackHole…).
- **Output**: System Default or any specific output device. Capture is clocked from the output
  device (private aggregate device with drift compensation), so input and output never drift apart.
- Effects can be added (any installed AU effect or music effect), reordered (drag, or the ▲/▼ buttons),
  bypassed (checkbox), removed, and edited (**Edit…** or double-click opens the plug-in's UI,
  or a generic parameter view if the plug-in has no UI).
- **Dry/Wet** slider blends the unprocessed signal with the processed one. The dry path is delayed by the
  plug-ins' reported latency so the two stay sample-aligned (no comb filtering).
- In/Out peak meters and an output gain control (−∞ … +6 dB).
- The chain and each plug-in's state are saved when you quit and restored on the next launch.
- Follows changes to the default output device and devices being plugged/unplugged.

## Virtual device

`Driver/AudioRouterDriver.c` is a small Core Audio HAL plug-in (AudioServerPlugIn) that adds an
**Audio Router** device: stereo output looped back to a stereo input, 44.1–192 kHz.

Install it from the app (**Virtual Device ▸ Install…**, asks for your admin password) or with

    sudo ./install-driver.sh              # remove with: sudo ./install-driver.sh --uninstall

Then choose **Audio Router** as the output of an app (or as the Mac's output in System Settings ▸ Sound),
choose **Audio Router (virtual device)** as the input in Audio Router, and pick your speakers/headphones
as Audio Router's output. Reading an input device requires Microphone permission.

Requires macOS 15+ (process taps need 14.2+; the lock-free ring buffer uses `Synchronization`).

## Build & run

    ./build.sh            # → build.nosync/Audio Router.app (+ AudioRouterDriver.driver)
    open "build.nosync/Audio Router.app"

On the first start macOS asks for permission to capture system audio
(System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ System Audio Recording Only).
The app is ad-hoc signed, so after a rebuild macOS may ask again.

## Signal flow

    all other apps ─► process tap ─► private aggregate device IOProc ─► ring buffer
        ├► wet source node ─► AU 1 ─► AU 2 ─► … ─► wet mixer ─┐
        └► dry source node (delayed by plug-in latency) ─► dry mixer ─┴► main mixer (gain) ─► output

Debug: `open "build.nosync/Audio Router.app" --args --autostart --log /path/levels.log` logs peak levels every 0.5 s.

## Design

The UI shares the look of MIDI Filter (`Sources/AudioRouter/Theme/Theme.swift`): frosted dark glass,
glowing rubber keys with a warm bulb backlight, violet accent. Font: JetBrains Mono (SIL OFL, `Resources/Fonts/OFL.txt`).
