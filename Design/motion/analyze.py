# usage: python3 analyze.py <music.wav> <sfx.wav> — the effects against the music around each cue (dB RMS, 0.35 s)
import struct, sys, math, json, subprocess
def read(path):
    b = open(path, 'rb').read()
    ch = struct.unpack_from('<H', b, 22)[0]; sr = struct.unpack_from('<I', b, 24)[0]
    n = (len(b) - 44) // 4
    data = struct.unpack_from(f'<{n}f', b, 44)
    return [data[i::ch] for i in range(ch)], sr
def rms(chs, sr, t0, t1):
    a, b = int(t0 * sr), int(t1 * sr)
    s = sum(x * x for c in chs for x in c[a:b]); n = max(1, (b - a) * len(chs))
    return 10 * math.log10(s / n + 1e-12)
m, sr = read(sys.argv[1]); f, _ = read(sys.argv[2])
cues = json.loads(sys.argv[3])
for name, t in cues:
    mm, ff = rms(m, sr, t, t + 0.35), rms(f, sr, t, t + 0.35)
    print(f"{name:12s} {t:6.2f}s  sfx {ff:6.1f}  music {mm:6.1f}  diff {ff - mm:+5.1f}")
