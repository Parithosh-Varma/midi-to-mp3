# MidiToMp3 — native Mac app

SwiftUI app: drop `.mid` files, get back grand-piano audio rendered from the
Salamander samples. No Xcode required to build.

## Quick start (app)

```bash
./make-app.sh        # builds MidiToMp3.app (Swift toolchain only)
open MidiToMp3.app
```

First launch offers a one-time piano download (~50 MB into Application
Support); afterwards conversions are fully offline.

## Develop

```bash
swift build          # compile (Swift 6, macOS 13+)
swift test           # needs full Xcode (CLT alone lacks the test runtime)
```

`MidiToMp3Core` (MIDI parser, sample renderer, WAV/AAC export) has no UI
dependencies and is covered by `Tests/MidiToMp3CoreTests`.

## Notes

- **Export is AAC (.m4a) + WAV, not MP3.** Apple platforms expose no public
  MP3 encoder, so AAC it is — same quality, plays everywhere Apple does.
- Not sandboxed (ad-hoc signed). On first run macOS may ask you to confirm
  opening an app from an unidentified developer: right-click → Open.
