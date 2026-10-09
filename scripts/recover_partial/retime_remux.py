#!/usr/bin/env python3
"""Lossless remux of an untrunc-recovered Tracer recording with rebuilt video timing.

Inputs:  fixed.mp4 (untrunc output), frames_presentation_order.json (ffprobe -show_frames, video)
Output:  recovered.mp4 (same bytes, new timestamps, moov at front)

Timing model (measured on this file): AVAssetWriter wrote the mdat as alternating
chunks  V A V A ... V  of ~0.5 s each. Audio packets are a fixed clock (1024 samples
@ 48 kHz), so video chunk j spans [audio_before_j, audio_before_j + len(A_j)) seconds.
Frames inside a chunk are spread evenly in PRESENTATION order (decoder output order).
"""
import sys, json, subprocess, bisect
from fractions import Fraction
import av

fixed, frames_json, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
AUD = 1024 / 48000.0
TB = Fraction(1, 60000)

def packets(sel):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", sel,
                          "-show_entries", "packet=pts_time,dts_time,pos,size",
                          "-of", "json", fixed], capture_output=True, text=True).stdout
    return json.loads(out)["packets"]

v = packets("v"); a = packets("a")
vpos = [int(p["pos"]) for p in v]
apos = sorted(int(p["pos"]) for p in a)

# --- chunk runs in file order
order = sorted([(pos, 'V') for pos in vpos] + [(pos, 'A') for pos in apos])
runs = []
for pos, k in order:
    if runs and runs[-1][0] == k:
        runs[-1][1].append(pos)
    else:
        runs.append([k, [pos]])

# --- window per video chunk
chunk_of = {}        # video pkt pos -> chunk index
windows = []         # (start, end) per video chunk
audio_before = 0
for i, (k, poss) in enumerate(runs):
    if k == 'A':
        audio_before += len(poss)
        continue
    start = audio_before * AUD
    nxt = runs[i + 1] if i + 1 < len(runs) else None
    if nxt and nxt[0] == 'A':
        end = start + len(nxt[1]) * AUD
    else:
        end = start + len(poss) / 30.0
    j = len(windows)
    windows.append((start, end))
    for pos in poss:
        chunk_of[pos] = j

# --- presentation order from the decoder
frames = json.load(open(frames_json))["frames"]
pres_pos = [int(f["pkt_pos"]) for f in frames]
assert sorted(pres_pos) == sorted(vpos), "frame/packet mismatch"

per_chunk = {}
for n, pos in enumerate(pres_pos):
    per_chunk.setdefault(chunk_of[pos], []).append(pos)

raw_time = {}
for j, poss in per_chunk.items():
    s, e = windows[j]
    cnt = len(poss)
    for i, pos in enumerate(poss):
        raw_time[pos] = s + (e - s) * i / cnt

# monotonic presentation times: sorted multiset re-assigned in presentation order
times_sorted = sorted(raw_time.values())
P = []
last = -1
for t in times_sorted:
    tick = int(round(t / TB))
    if tick <= last:
        tick = last + 1
    P.append(tick); last = tick
pts_of = {pos: P[n] for n, pos in enumerate(pres_pos)}
pres_index = {pos: n for n, pos in enumerate(pres_pos)}

# decode order dts
D = max(k - pres_index[pos] for k, pos in enumerate(vpos))
dur0 = P[1] - P[0] if len(P) > 1 else int(round((1 / 30) / TB))
dts_of = {}
for k, pos in enumerate(vpos):
    if k >= D:
        d = P[k - D]
    else:
        d = P[0] - (D - k) * dur0
    dts_of[pos] = d
    assert d <= pts_of[pos], (k, d, pts_of[pos])

print(f"video chunks={len(windows)} frames={len(vpos)} reorder_depth={D} "
      f"video span {P[0]*TB:.3f}..{P[-1]*TB:.3f}s audio {len(a)*AUD:.3f}s")

# --- remux
inp = av.open(fixed)
in_v = inp.streams.video[0]; in_a = inp.streams.audio[0]
out = av.open(out_path, "w", options={"movflags": "faststart"})
out_v = out.add_stream_from_template(in_v)
out_a = out.add_stream_from_template(in_a)
out_v.time_base = TB
out_a.time_base = in_a.time_base
n_v = n_a = 0
for pkt in inp.demux((in_v, in_a)):
    if pkt.dts is None and pkt.pts is None:
        continue  # flush packet
    if pkt.stream.type == "video":
        pos = pkt.pos
        pkt.pts = pts_of[pos]; pkt.dts = dts_of[pos]
        pkt.time_base = TB
        pkt.stream = out_v; n_v += 1
    else:
        pkt.stream = out_a; n_a += 1
    out.mux(pkt)
out.close(); inp.close()
print(f"muxed video={n_v} audio={n_a} -> {out_path}")
