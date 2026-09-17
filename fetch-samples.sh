#!/usr/bin/env bash
# Fetch the Salamander Grand Piano samples (CC-BY 3.0, Alexander Holm)
# and decode them to ./salamander/*.wav for midi-to-mp3.mjs.
# macOS uses built-in afconvert; Linux uses ffmpeg.
set -euo pipefail

mkdir -p salamander
for o in 2 3 4 5 6; do
  for n in C Ds Fs A; do
    out="salamander/${n}${o}.wav"
    if [ -f "$out" ]; then
      continue
    fi
    echo "fetching ${n}${o}..."
    curl -sL --max-time 120 \
      -o "salamander/${n}${o}.mp3" \
      "https://tonejs.github.io/audio/salamander/${n}${o}.mp3"
    if command -v afconvert >/dev/null 2>&1; then
      afconvert -f WAVE -d LEI16@44100 \
        "salamander/${n}${o}.mp3" "$out"
    elif command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -loglevel error \
        -i "salamander/${n}${o}.mp3" -ar 44100 -ac 2 -c:a pcm_s16le "$out"
    else
      echo "need afconvert (macOS) or ffmpeg (Linux) to decode samples" >&2
      exit 1
    fi
    rm "salamander/${n}${o}.mp3"
  done
done
echo "samples ready in ./salamander"
