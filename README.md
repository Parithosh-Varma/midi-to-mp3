# midi-to-mp3

Convert Standard MIDI files (`.mid`) to MP3 with a **real grand piano sound** — no FluidSynth, no ffmpeg, no uploads. Everything runs locally.

Two ways to use it:

- **Command line** — `midi-to-mp3.mjs` (Node 18+)
- **Browser** — `midi-converter.html` (drag & drop, fully offline after load)

## How it sounds like a grand

Most tiny converters synthesize piano tones from sine waves and sound like a toy piano. This one renders from actual **Salamander Grand Piano** recordings (the same samples used by Tone.js demos): nearest recording per note, resampled to exact pitch, velocity mapped to loudness + brightness, damper-style release, sustain-pedal aware, light room.

## Quick start

```bash
npm install
./fetch-samples.sh     # downloads ~20 piano samples into ./salamander/
node midi-to-mp3.mjs song.mid
# -> song.mp3
```

## CLI usage

```
node midi-to-mp3.mjs input.mid [output.mp3] [options]

  --bitrate N     MP3 bitrate in kbps (default 192)
  --keep-wav      keep the intermediate .wav next to the output
  --no-reverb     dry render, no room
  --tail SEC      extra ring-out after the last note (default 1.8)
  --transpose N   shift all notes by N semitones (e.g. -12 = one octave down)
  --engine E      samples (real grand, default) or synth (built-in fallback)
  --samples-dir   where the Salamander .wav files live (default ./salamander)
```

The parser handles MIDI format 0/1, tempo maps, and sustain pedal (CC64). All tracks render as piano.

## Browser version

Open `midi-converter.html` (or serve this folder with any static server). Drop `.mid` files, preview, download MP3/WAV. Samples stream from CDN at convert time; if offline it falls back to the built-in synth.

## Credits

- Piano samples: [Salamander Grand Piano](https://github.com/sfzinstruments/SalamanderGrandPiano) by Alexander Holm, [CC-BY 3.0](https://creativecommons.org/licenses/by/3.0/).
- MP3 encoding: [@breezystack/lamejs](https://github.com/shijinyu/lamejs) (pure JS, no native deps).

Code in this repo is MIT licensed (see `LICENSE`). The piano samples remain CC-BY 3.0 by their author.
