# Recovering a partial recording (no `moov` index)

When the writer dies mid-recording, the app keeps the partial `.mp4` in
`~/Movies/NoCornyTracer/`. Such a file is `ftyp` + `mdat` only: every frame and
audio packet is there, but there is no index, so no player opens it. This folder
holds the recipe that recovered a 5-minute take on 2026-10-09.

## 1. Build untrunc (one-off)

```bash
git clone --depth 1 https://github.com/anthwlock/untrunc.git
cd untrunc && docker build -t untrunc:local .
```

## 2. Get a reference file

untrunc copies the codec configuration (SPS/PPS, track layout) from a healthy file
made by the SAME app version on the SAME display resolution. Record a 15-second
clip with the app and keep the file (the app deletes the local copy after upload,
so download it back from the Dropbox shared link with `&dl=1`).

## 3. Rebuild the index

```bash
mkdir -p ~/Movies/NoCornyTracer-recovery && cd ~/Movies/NoCornyTracer-recovery
cp ~/Movies/NoCornyTracer/<partial>.mp4 broken.mp4
docker run --rm -v "$PWD:/data" untrunc:local /data/ref.mp4 /data/broken.mp4
# -> broken.mp4_fixed.mp4
```

untrunc gets two things wrong for this encoder: it writes no composition offsets
(the encoder uses B-frames, so frames would play in decode order) and it guesses
frame durations from the reference (drift of several seconds on a long take).

## 4. Rebuild timing and presentation order (lossless)

```bash
ffprobe -v error -select_streams v -show_entries frame=pkt_pos,pkt_dts_time,pict_type,key_frame \
  -of json broken.mp4_fixed.mp4 > frames_presentation_order.json
python3 -m venv .venv && .venv/bin/pip install av
.venv/bin/python retime_remux.py broken.mp4_fixed.mp4 frames_presentation_order.json recovered.mp4
```

The script uses the audio packets (fixed 1024 samples at 48 kHz) as the clock:
AVAssetWriter interleaves the file as alternating ~0.5 s chunks V A V A ..., so
each video chunk spans the time of the audio chunk written right after it. Frames
inside a chunk are spread evenly in the order the decoder outputs them. Verified
against the recording pill timer visible in the frames: within 1 s over 5 minutes.

## 5. Put it back into the library

Quit the app, copy `recovered.mp4` over the partial under its original name, and
append a row to the `savedRecordings` JSON array in `defaults com.nocorny.tracer`
with `uploadStatus: notUploaded` (id, fileURL, createdAt as seconds since 2001,
duration, fileSize). Relaunch: the row shows "Not uploaded yet", the red cloud
icon in the drawer runs the normal upload pipeline.
