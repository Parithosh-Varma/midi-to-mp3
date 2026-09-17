#!/usr/bin/env node
// midi-to-mp3.mjs — convert any Standard MIDI File (.mid) to MP3.
//
//   node midi-to-mp3.mjs input.mid [output.mp3] [--bitrate 192] [--keep-wav] [--no-reverb]
//
// How it works (zero native dependencies):
//   1. Parses the SMF directly (format 0/1, tempo map, sustain pedal CC64).
//   2. Renders a piano-like tone in pure JS (harmonics + inharmonicity +
//      velocity + multi-tap ambience) to 44.1 kHz mono Float32.
//   3. Encodes MP3 with @breezystack/lamejs (pure JS, no ffmpeg needed).
//
// macOS note: the built-in `afconvert` on this machine cannot encode MP3
// (only AAC/M4A), which is why this script encodes MP3 itself.
//
// Grand-piano realism comes from the Salamander Grand Piano sample set
// (recorded by Alexander Holm, CC-BY 3.0) — the same 20 samples the
// piano web app plays (C/Ds/Fs/A of octaves 2-6, fetched from the
// Tone.js CDN into ./salamander/). Notes are rendered by resampling the
// nearest recording, so what you hear is a real grand, not synthesis.
// If the samples are missing, use --engine synth for the built-in
// harmonic fallback.

import fs from "node:fs";
import path from "node:path";

const SR = 44100;

// ---------------------------------------------------------------------------
// 1. Minimal SMF parser
// ---------------------------------------------------------------------------

function readVarLen(buf, off) {
  let v = 0;
  let i = 0;
  for (;;) {
    const c = buf[off + i];
    v = (v << 7) | (c & 0x7f);
    i++;
    if (!(c & 0x80)) break;
    if (i > 4) throw new Error("bad varlen");
  }
  return [v, i];
}

function sniffNonMidi(buf) {
  const head = buf.slice(0, 64).toString("utf8").trim();
  if (head.startsWith("<")) {
    if (head.includes("NoSuchKey") || head.includes("<Error>")) {
      return "This is not a MIDI file — it is a download-error page saved with a .mid name (the link was dead). Please download the file again.";
    }
    return "This is not a MIDI file — it looks like a web page saved with a .mid name. Please download the actual MIDI file.";
  }
  if (head.startsWith("RIFF")) {
    return "This is a RIFF (.rmi) MIDI file, not a Standard MIDI (.mid) file. Re-export it as .mid and try again.";
  }
  if (head.startsWith("ID3") || (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0)) {
    return "This is an MP3 file, not a MIDI file.";
  }
  if (buf.length < 14) {
    return `This file is too small to be a MIDI file (${buf.length} bytes). The download probably failed.`;
  }
  return "not a Standard MIDI File (missing MThd)";
}

function parseMidi(buf) {
  if (buf.length < 14 || buf.slice(0, 4).toString("ascii") !== "MThd") {
    throw new Error(sniffNonMidi(buf));
  }
  const format = buf.readUInt16BE(8);
  const ntracks = buf.readUInt16BE(10);
  const division = buf.readUInt16BE(12);
  if (format === 2) throw new Error("MIDI format 2 (multi-song) is not supported");
  if (division & 0x8000) throw new Error("SMPTE time division is not supported");
  const ticksPerQuarter = division || 480;

  const tempos = [{ abs: 0, mpn: 500000 }]; // default 120 BPM
  const rawEvents = []; // {abs, kind, ...}

  let pos = 14;
  for (let t = 0; t < ntracks; t++) {
    if (pos + 8 > buf.length) throw new Error("truncated track header");
    const magic = buf.slice(pos, pos + 4).toString("ascii");
    if (magic !== "MTrk") throw new Error(`track ${t}: missing MTrk`);
    const len = buf.readUInt32BE(pos + 4);
    let p = pos + 8;
    const end = p + len;
    if (end > buf.length) throw new Error("truncated track data");
    let abs = 0;
    let status = 0;
    while (p < end) {
      const [delta, n] = readVarLen(buf, p);
      p += n;
      abs += delta;
      const b = buf[p];
      if (b === 0xff) {
        const type = buf[p + 1];
        const [ml, mn] = readVarLen(buf, p + 2);
        const data = buf.subarray(p + 2 + mn, p + 2 + mn + ml);
        if (type === 0x51 && ml === 3) {
          tempos.push({ abs, mpn: (data[0] << 16) | (data[1] << 8) | data[2] });
        }
        p += 2 + mn + ml;
      } else if (b === 0xf0 || b === 0xf7) {
        const [ml, mn] = readVarLen(buf, p + 1);
        p += 1 + mn + ml;
      } else {
        if (b & 0x80) {
          status = b;
          p++;
        }
        const kind = status & 0xf0;
        const ch = status & 0x0f;
        if (kind === 0x90 || kind === 0x80) {
          const pitch = buf[p];
          const vel = buf[p + 1];
          p += 2;
          const on = kind === 0x90 && vel > 0;
          rawEvents.push({ abs, kind: on ? "on" : "off", ch, pitch, vel });
        } else if (kind === 0xa0) {
          p += 2; // poly aftertouch: ignore
        } else if (kind === 0xb0) {
          const cc = buf[p];
          const val = buf[p + 1];
          p += 2;
          if (cc === 64) rawEvents.push({ abs, kind: "pedal", ch, down: val >= 64 });
          else if (cc === 123 || cc === 120) rawEvents.push({ abs, kind: "allOff", ch });
        } else if (kind === 0xc0 || kind === 0xd0) {
          p += 1; // program change / channel pressure: piano for everything
        } else if (kind === 0xe0) {
          p += 2; // pitch bend: ignored (rendered as piano)
        } else {
          throw new Error("bad running status");
        }
      }
    }
    pos = end;
  }

  tempos.sort((a, b) => a.abs - b.abs);
  rawEvents.sort((a, b) => a.abs - b.abs);

  const ticksToSec = (tick) => {
    let sec = 0;
    let lastAbs = 0;
    let lastMpn = tempos[0].mpn;
    for (let i = 1; i < tempos.length; i++) {
      if (tempos[i].abs > tick) break;
      sec += ((tempos[i].abs - lastAbs) * lastMpn) / 1_000_000 / ticksPerQuarter;
      lastAbs = tempos[i].abs;
      lastMpn = tempos[i].mpn;
    }
    return sec + ((tick - lastAbs) * lastMpn) / 1_000_000 / ticksPerQuarter;
  };

  // Note assembly with per-channel sustain pedal.
  const notes = [];
  const sounding = new Map(); // key ch*256+pitch -> {start, vel}
  const pedal = new Array(16).fill(false);
  const heldByPedal = new Map(); // key -> {start, vel}

  const key = (ch, pitch) => ch * 256 + pitch;

  function noteOff(ch, pitch, abs) {
    const k = key(ch, pitch);
    const s = sounding.get(k);
    if (!s) return;
    sounding.delete(k);
    if (pedal[ch]) {
      heldByPedal.set(k, s); // keep ringing until pedal lifts
    } else {
      const start = ticksToSec(s.startAbs);
      const end = ticksToSec(abs);
      if (end > start) notes.push({ midi: pitch, start, end, vel: s.vel });
    }
  }

  for (const ev of rawEvents) {
    if (ev.kind === "on") {
      const k = key(ev.ch, ev.pitch);
      const prev = sounding.get(k);
      if (prev) {
        // retrigger: close the old one first
        const start = ticksToSec(prev.startAbs);
        const end = ticksToSec(ev.abs);
        if (end > start) notes.push({ midi: ev.pitch, start, end, vel: prev.vel });
      }
      const sus = heldByPedal.get(k);
      if (sus) {
        // retrigger while the pedal was holding the old note:
        // flush it instead of dropping it.
        heldByPedal.delete(k);
        const start = ticksToSec(sus.startAbs);
        const end = ticksToSec(ev.abs);
        if (end > start) notes.push({ midi: ev.pitch, start, end, vel: sus.vel });
      }
      sounding.set(k, { startAbs: ev.abs, vel: ev.vel });
    } else if (ev.kind === "off") {
      noteOff(ev.ch, ev.pitch, ev.abs);
    } else if (ev.kind === "pedal") {
      pedal[ev.ch] = ev.down;
      if (!ev.down) {
        // pedal lifted: release everything it was holding on this channel
        for (const [k, s] of [...heldByPedal]) {
          if ((k / 256 | 0) === ev.ch) {
            heldByPedal.delete(k);
            const start = ticksToSec(s.startAbs);
            const end = ticksToSec(ev.abs);
            if (end > start) notes.push({ midi: s.pitch ?? (k % 256), start, end, vel: s.vel });
          }
        }
      }
    } else if (ev.kind === "allOff") {
      for (const [k, s] of [...sounding]) {
        if ((k / 256 | 0) === ev.ch) {
          sounding.delete(k);
          const start = ticksToSec(s.startAbs);
          const end = ticksToSec(ev.abs);
          if (end > start) notes.push({ midi: k % 256, start, end, vel: s.vel });
        }
      }
      for (const [k, s] of [...heldByPedal]) {
        if ((k / 256 | 0) === ev.ch) {
          heldByPedal.delete(k);
          const start = ticksToSec(s.startAbs);
          const end = ticksToSec(ev.abs);
          if (end > start) notes.push({ midi: k % 256, start, end, vel: s.vel });
        }
      }
    }
  }

  // Hang any still-sounding notes at end of track (+1 beat of ring).
  const lastAbs = rawEvents.length ? rawEvents[rawEvents.length - 1].abs : 0;
  const endAbs = lastAbs + ticksPerQuarter;
  for (const [k, s] of sounding) {
    const start = ticksToSec(s.startAbs);
    notes.push({ midi: k % 256, start, end: ticksToSec(endAbs), vel: s.vel });
  }
  for (const [k, s] of heldByPedal) {
    const start = ticksToSec(s.startAbs);
    notes.push({ midi: k % 256, start, end: ticksToSec(endAbs), vel: s.vel });
  }

  // Clamp to piano range, drop inaudible.
  const clean = notes.filter((nn) => nn.midi >= 21 && nn.midi <= 108 && nn.end > nn.start);
  clean.sort((a, b) => a.start - b.start);
  const duration = clean.reduce((m, nn) => Math.max(m, nn.end), 0);
  return { notes: clean, duration, ticksPerQuarter };
}

// ---------------------------------------------------------------------------
// 2. Piano-ish renderer (pure JS, mono Float32)
// ---------------------------------------------------------------------------

const PARTIALS = [
  { m: 1, a: 1.0, d: 1.0 },
  { m: 2, a: 0.3, d: 2.4 },
  { m: 3, a: 0.13, d: 3.8 },
  { m: 4, a: 0.06, d: 5.6 },
  { m: 5, a: 0.03, d: 7.6 },
  { m: 6, a: 0.015, d: 10.0 },
  { m: 7, a: 0.008, d: 13.0 },
];
const INHARM_B = 0.00018; // piano string inharmonicity (slightly tamed)
const ATTACK_S = 0.005;
const RELEASE_S = 0.16;
const DETUNE_CENTS = 2.2; // L/R micro-detune for stereo width
const BOARD_CUTOFF = 700; // soundboard warmth lowpass (Hz)
const BOARD_GAIN = 0.32;
const THUMP_MS = 0.045; // hammer felt-noise burst length
const THUMP_GAIN = 0.1;

function midiToFreq(m) {
  return 440 * Math.pow(2, (m - 69) / 12);
}

function renderPiano(notes, duration, { tail = 1.8, reverb = true, onProgress } = {}) {
  const totalSec = duration + tail;
  const total = Math.ceil(totalSec * SR);
  const left = new Float32Array(total);
  const right = new Float32Array(total);
  const detuneRatio = Math.pow(2, DETUNE_CENTS / 1200);
  let seed = 0x12345678;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1;

  for (let ni = 0; ni < notes.length; ni++) {
    const nn = notes[ni];
    const freq = midiToFreq(nn.midi);
    const velN = nn.vel / 127;
    // Bass rings longer, treble dies faster.
    const decayBase = 1.0 + ((nn.midi - 21) / 87) * 2.2;
    const velGain = Math.pow(velN, 1.3) * 0.42;
    // Soft playing is mellow, hard playing is bright (like real hammers).
    const bright = 0.25 + 0.75 * velN;
    const startIdx = Math.floor(nn.start * SR);
    const holdEnd = Math.floor(nn.end * SR);
    const renderEnd = Math.min(total, holdEnd + Math.floor(RELEASE_S * SR));
    if (startIdx >= total) continue;

    // Per-partial frequency (inharmonic) + extra damping for glassy highs:
    // anything shimmering above ~3.5 kHz dies in milliseconds, not seconds.
    const omegasL = [];
    const omegasR = [];
    const amps = [];
    const decays = [];
    for (const p of PARTIALS) {
      const f = p.m * freq * Math.sqrt(1 + INHARM_B * p.m * p.m);
      const glassDamp = Math.max(0, (f - 3500) / 1000) * 3;
      omegasL.push(((2 * Math.PI * f) / SR) / detuneRatio);
      omegasR.push(((2 * Math.PI * f) / SR) * detuneRatio);
      amps.push(p.a * Math.pow(bright, p.m - 1));
      decays.push(decayBase * p.d + glassDamp);
    }
    const phasesL = new Array(PARTIALS.length).fill(0);
    const phasesR = new Array(PARTIALS.length).fill(0);

    // Hammer felt-noise: short lowpassed burst, louder when struck hard.
    const thumpN = Math.min(renderEnd - startIdx, Math.floor(THUMP_MS * SR));
    let thumpLp = 0;
    const thumpAlpha = Math.min(1, (2 * Math.PI * 500) / SR);

    for (let i = startIdx; i < renderEnd; i++) {
      const t = (i - startIdx) / SR;
      // attack ramp
      let env = t < ATTACK_S ? 0.5 - 0.5 * Math.cos(Math.PI * (t / ATTACK_S)) : 1;
      // release fade after key lift
      if (i > holdEnd) {
        const rt = (i - holdEnd) / SR / RELEASE_S;
        env *= 0.5 + 0.5 * Math.cos(Math.PI * Math.min(1, rt));
      }
      let sL = 0;
      let sR = 0;
      for (let k = 0; k < PARTIALS.length; k++) {
        const amp = amps[k] * Math.exp(-decays[k] * t);
        if (amp < 0.0004) continue;
        phasesL[k] += omegasL[k];
        phasesR[k] += omegasR[k];
        sL += amp * Math.sin(phasesL[k]);
        sR += amp * Math.sin(phasesR[k]);
      }
      // felt thump under the attack
      const ti = i - startIdx;
      if (ti < thumpN) {
        thumpLp += thumpAlpha * (rand() - thumpLp);
        const tg = THUMP_GAIN * velN * Math.exp(-ti / SR / 0.012);
        sL += thumpLp * tg;
        sR += thumpLp * tg;
      }
      left[i] += sL * env * velGain;
      right[i] += sR * env * velGain;
    }
    if (onProgress && ni % 200 === 0) onProgress(ni / notes.length);
  }

  // Soundboard body: a warm lowpassed copy under the dry strings.
  {
    const alpha = Math.min(1, (2 * Math.PI * BOARD_CUTOFF) / SR);
    let lpL = 0;
    let lpR = 0;
    for (let i = 0; i < total; i++) {
      lpL += alpha * (left[i] - lpL);
      lpR += alpha * (right[i] - lpR);
      left[i] += lpL * BOARD_GAIN;
      right[i] += lpR * BOARD_GAIN;
    }
  }

  if (reverb) {
    // Cheap stereo room: different taps per side, fed from the dry mix.
    const dryL = Float32Array.from(left);
    const dryR = Float32Array.from(right);
    const tapsL = [
      [0.231, 0.17],
      [0.317, 0.11],
    ];
    const tapsR = [
      [0.257, 0.17],
      [0.463, 0.09],
    ];
    for (const [delayS, gain] of tapsL) {
      const d = Math.floor(delayS * SR);
      for (let i = d; i < total; i++) left[i] += dryL[i - d] * gain;
    }
    for (const [delayS, gain] of tapsR) {
      const d = Math.floor(delayS * SR);
      for (let i = d; i < total; i++) right[i] += dryR[i - d] * gain;
    }
  }

  // Joint-stereo normalize to 0.89 with a gentle tanh glue.
  let peak = 0;
  for (let i = 0; i < total; i++) {
    const a = Math.abs(left[i]);
    if (a > peak) peak = a;
    const b = Math.abs(right[i]);
    if (b > peak) peak = b;
  }
  if (peak > 0) {
    const g = 0.89 / peak;
    for (let i = 0; i < total; i++) {
      left[i] = Math.tanh(left[i] * g * 1.05) * 0.92;
      right[i] = Math.tanh(right[i] * g * 1.05) * 0.92;
    }
    let p2 = 0;
    for (let i = 0; i < total; i++) {
      const a = Math.abs(left[i]);
      if (a > p2) p2 = a;
      const b = Math.abs(right[i]);
      if (b > p2) p2 = b;
    }
    if (p2 > 0) {
      const g2 = 0.89 / p2;
      for (let i = 0; i < total; i++) {
        left[i] *= g2;
        right[i] *= g2;
      }
    }
  }
  return { left, right };
}

// ---------------------------------------------------------------------------
// 2b. Sample engine — real Salamander grand recordings
// ---------------------------------------------------------------------------

function readWav16(file) {
  const b = fs.readFileSync(file);
  if (b.toString("ascii", 0, 4) !== "RIFF") throw new Error("bad wav: " + file);
  let off = 12;
  let audioFmt = 0;
  let ch = 0;
  let dataOff = 0;
  let dataLen = 0;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4);
    const len = b.readUInt32LE(off + 4);
    if (id === "fmt ") {
      audioFmt = b.readUInt16LE(off + 8);
      ch = b.readUInt16LE(off + 10);
      if (b.readUInt16LE(off + 22) !== 16) throw new Error("only 16-bit WAV: " + file);
    } else if (id === "data") {
      dataOff = off + 8;
      dataLen = len;
    }
    off += 8 + len + (len & 1);
  }
  if (audioFmt !== 1 || !dataOff) throw new Error("unreadable wav: " + file);
  const frames = Math.floor(dataLen / (ch * 2));
  const L = new Float32Array(frames);
  const R = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    L[i] = b.readInt16LE(dataOff + i * ch * 2) / 32768;
    R[i] = (ch > 1 ? b.readInt16LE(dataOff + i * ch * 2 + 2) : L[i]) / 32768;
  }
  return { L, R };
}

const SAMPLE_SEMI = { C: 0, Ds: 3, Fs: 6, A: 9 };

function loadSamples(dir) {
  const samples = [];
  for (let oct = 2; oct <= 6; oct++) {
    for (const name of ["C", "Ds", "Fs", "A"]) {
      const file = path.join(dir, `${name}${oct}.wav`);
      if (!fs.existsSync(file)) throw new Error(`missing ${file}`);
      const { L, R } = readWav16(file);
      samples.push({ midi: (oct + 1) * 12 + SAMPLE_SEMI[name], L, R });
    }
  }
  samples.sort((a, b) => a.midi - b.midi);
  return samples;
}

function renderSamples(notes, duration, samples, { tail = 1.8, reverb = true, onProgress } = {}) {
  const total = Math.ceil((duration + tail) * SR);
  const left = new Float32Array(total);
  const right = new Float32Array(total);
  const attN = Math.max(1, Math.floor(0.003 * SR));
  const relN = Math.max(1, Math.floor(0.12 * SR));

  for (let ni = 0; ni < notes.length; ni++) {
    const nn = notes[ni];
    let best = samples[0];
    let bd = Infinity;
    for (const s of samples) {
      const d = Math.abs(s.midi - nn.midi);
      if (d < bd) {
        bd = d;
        best = s;
      }
    }
    const ratio = Math.pow(2, (nn.midi - best.midi) / 12);
    const velN = nn.vel / 127;
    const gain = Math.pow(velN, 1.2) * 0.6;
    // Soft strikes sound darker, hard strikes brighter (damper + hammer).
    const alpha = Math.min(1, (2 * Math.PI * (1200 + velN * 11000)) / SR);
    const startIdx = Math.floor(nn.start * SR);
    const holdFrames = Math.max(0, Math.floor(nn.end * SR) - startIdx);
    if (startIdx >= total) continue;
    let lpL = 0;
    let lpR = 0;
    for (let i = 0; ; i++) {
      const pos = i * ratio;
      const i0 = Math.floor(pos);
      if (i0 + 1 >= best.L.length) break;
      const out = startIdx + i;
      if (out >= total) break;
      if (i > holdFrames + relN) break;
      const fr = pos - i0;
      const xL = best.L[i0] + (best.L[i0 + 1] - best.L[i0]) * fr;
      const xR = best.R[i0] + (best.R[i0 + 1] - best.R[i0]) * fr;
      lpL += alpha * (xL - lpL);
      lpR += alpha * (xR - lpR);
      let env = i < attN ? i / attN : 1;
      if (i > holdFrames) {
        const rt = Math.min(1, (i - holdFrames) / relN);
        env *= 0.5 + 0.5 * Math.cos(Math.PI * rt);
      }
      left[out] += lpL * env * gain;
      right[out] += lpR * env * gain;
    }
    if (onProgress && ni % 200 === 0) onProgress(ni / notes.length);
  }

  if (reverb) {
    // The recordings already carry the hall; just a breath of room.
    const dryL = Float32Array.from(left);
    const dryR = Float32Array.from(right);
    for (const [delayS, gain] of [[0.231, 0.1], [0.317, 0.07]]) {
      const d = Math.floor(delayS * SR);
      for (let i = d; i < total; i++) left[i] += dryL[i - d] * gain;
    }
    for (const [delayS, gain] of [[0.257, 0.1], [0.463, 0.06]]) {
      const d = Math.floor(delayS * SR);
      for (let i = d; i < total; i++) right[i] += dryR[i - d] * gain;
    }
  }

  // Joint-stereo normalize to 0.89 with a gentle tanh glue.
  let peak = 0;
  for (let i = 0; i < total; i++) {
    const a = Math.abs(left[i]);
    if (a > peak) peak = a;
    const b = Math.abs(right[i]);
    if (b > peak) peak = b;
  }
  if (peak > 0) {
    const g = 0.89 / peak;
    for (let i = 0; i < total; i++) {
      left[i] = Math.tanh(left[i] * g * 1.05) * 0.92;
      right[i] = Math.tanh(right[i] * g * 1.05) * 0.92;
    }
    let p2 = 0;
    for (let i = 0; i < total; i++) {
      const a = Math.abs(left[i]);
      if (a > p2) p2 = a;
      const b = Math.abs(right[i]);
      if (b > p2) p2 = b;
    }
    if (p2 > 0) {
      const g2 = 0.89 / p2;
      for (let i = 0; i < total; i++) {
        left[i] *= g2;
        right[i] *= g2;
      }
    }
  }
  return { left, right };
}

// ---------------------------------------------------------------------------
// 3. WAV writer + MP3 encoder
// ---------------------------------------------------------------------------

function floatTo16(buf) {
  const out = new Int16Array(buf.length);
  for (let i = 0; i < buf.length; i++) {
    const s = Math.max(-1, Math.min(1, buf[i]));
    out[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
  }
  return out;
}

function writeWavStereo(pcmL, pcmR, file) {
  const n = pcmL.length;
  const data = Buffer.alloc(n * 4);
  for (let i = 0; i < n; i++) {
    data.writeInt16LE(pcmL[i], i * 4);
    data.writeInt16LE(pcmR[i], i * 4 + 2);
  }
  const h = Buffer.alloc(44);
  h.write("RIFF", 0);
  h.writeUInt32LE(36 + n * 4, 4);
  h.write("WAVE", 8);
  h.write("fmt ", 12);
  h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); // PCM
  h.writeUInt16LE(2, 22); // stereo
  h.writeUInt32LE(SR, 24);
  h.writeUInt32LE(SR * 4, 28);
  h.writeUInt16LE(4, 32);
  h.writeUInt16LE(16, 34);
  h.write("data", 36);
  h.writeUInt32LE(n * 4, 40);
  fs.writeFileSync(file, Buffer.concat([h, data]));
}

async function encodeMp3(pcmL, pcmR, bitrate) {
  let lame;
  try {
    lame = await import("@breezystack/lamejs");
  } catch {
    throw new Error(
      "MP3 encoder not installed. Run: npm install @breezystack/lamejs"
    );
  }
  const enc = new lame.Mp3Encoder(2, SR, bitrate);
  const CHUNK = 11520;
  const parts = [];
  for (let i = 0; i < pcmL.length; i += CHUNK) {
    const d = enc.encodeBuffer(pcmL.subarray(i, i + CHUNK), pcmR.subarray(i, i + CHUNK));
    if (d.length) parts.push(Buffer.from(d));
  }
  const end = enc.flush();
  if (end.length) parts.push(Buffer.from(end));
  return Buffer.concat(parts);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function usage() {
  console.log(`Usage: node midi-to-mp3.mjs input.mid [output.mp3] [options]

Options:
  --bitrate N   MP3 bitrate in kbps (default 192)
  --keep-wav    keep the intermediate .wav next to the output
  --no-reverb   dry render, no room
  --tail SEC    extra ring-out after the last note (default 1.8)
  --transpose N shift all notes by N semitones (e.g. -12 = one octave down)
  --engine E    samples (real grand, default) or synth (built-in fallback)
  --samples-dir DIR  where the Salamander .wav files live (default ./salamander)

Examples:
  node midi-to-mp3.mjs song.mid
  node midi-to-mp3.mjs song.mid song.mp3 --bitrate 256 --keep-wav`);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("-h") || args.includes("--help") || args.length === 0) {
    usage();
    process.exit(args.length === 0 ? 1 : 0);
  }
  let input = null;
  let output = null;
  let bitrate = 192;
  let keepWav = false;
  let reverb = true;
  let tail = 1.8;
  let transpose = 0;
  let engine = "samples";
  let samplesDir = path.join(path.dirname(new URL(import.meta.url).pathname), "salamander");
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--bitrate") bitrate = parseInt(args[++i], 10);
    else if (a === "--keep-wav") keepWav = true;
    else if (a === "--no-reverb") reverb = false;
    else if (a === "--tail") tail = parseFloat(args[++i]);
    else if (a === "--transpose") transpose = parseInt(args[++i], 10);
    else if (a === "--engine") engine = args[++i];
    else if (a === "--samples-dir") samplesDir = args[++i];
    else if (a.startsWith("--")) throw new Error("unknown option " + a);
    else if (!input) input = a;
    else if (!output) output = a;
    else throw new Error("too many positional args");
  }
  if (!input) throw new Error("no input file");
  if (!fs.existsSync(input)) throw new Error("input not found: " + input);
  if (!output) {
    const base = input.replace(/\.(mid|midi)$/i, "");
    output = (base === input ? input : base) + ".mp3";
  }
  if (!Number.isFinite(bitrate) || bitrate < 64 || bitrate > 320) {
    throw new Error("--bitrate must be 64..320");
  }

  console.log(`Reading ${input} ...`);
  const parsed = parseMidi(fs.readFileSync(input));
  let notes = parsed.notes;
  if (transpose) {
    notes = notes
      .map((n) => ({ ...n, midi: n.midi + transpose }))
      .filter((n) => n.midi >= 21 && n.midi <= 108);
    console.log(`  transposed ${transpose > 0 ? "+" : ""}${transpose} semitones`);
  }
  const duration = notes.reduce((m, n) => Math.max(m, n.end), 0);
  if (!notes.length) throw new Error("no playable notes found in MIDI");
  console.log(
    `  ${notes.length} notes, ${duration.toFixed(1)}s of music, ` +
      `range MIDI ${Math.min(...notes.map((n) => n.midi))}..${Math.max(...notes.map((n) => n.midi))}`
  );

  console.log("Rendering piano (stereo) ...");
  const t0 = Date.now();
  const renderOpts = {
    tail,
    reverb,
    onProgress: (f) => process.stdout.write(`\r  ${(f * 100).toFixed(0)}%`),
  };
  let left;
  let right;
  if (engine === "samples") {
    try {
      const samples = loadSamples(samplesDir);
      console.log(`  Salamander grand: ${samples.length} recordings`);
      ({ left, right } = renderSamples(notes, duration, samples, renderOpts));
    } catch (err) {
      console.log(`  samples unavailable (${err.message}), falling back to synth`);
      ({ left, right } = renderPiano(notes, duration, renderOpts));
    }
  } else if (engine === "synth") {
    ({ left, right } = renderPiano(notes, duration, renderOpts));
  } else {
    throw new Error('--engine must be "samples" or "synth"');
  }
  process.stdout.write("\r  100%\n");
  console.log(`  rendered ${(left.length / SR).toFixed(1)}s stereo in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

  const pcmL = floatTo16(left);
  const pcmR = floatTo16(right);
  const wavPath = output.replace(/\.mp3$/i, "") + ".wav";
  const wantWavOnly = /\.wav$/i.test(output);
  writeWavStereo(pcmL, pcmR, wantWavOnly ? output : wavPath);
  console.log(`Wrote ${wantWavOnly ? output : wavPath}`);
  if (wantWavOnly) return;

  console.log(`Encoding MP3 stereo (${bitrate} kbps) ...`);
  const mp3 = await encodeMp3(pcmL, pcmR, bitrate);
  fs.writeFileSync(output, mp3);
  console.log(`Wrote ${output} (${(mp3.length / 1024).toFixed(0)} KB)`);
  if (!keepWav) fs.rmSync(wavPath);
  else console.log("(kept intermediate wav)");
}

main().catch((err) => {
  console.error("Error: " + err.message);
  process.exit(1);
});
