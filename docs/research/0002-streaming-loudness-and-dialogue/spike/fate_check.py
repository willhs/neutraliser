#!/usr/bin/env python3
"""Do real Dolby streams carry dialnorm and DRC words that FFmpeg's default decode acts on?

Evidence for docs/research/0002-streaming-loudness-and-dialogue/research.md. Uses FFmpeg's public FATE test samples:
real commercial encodes, short clips, nothing from any personal library. A handful of clips can show the
mechanism applies to real streams. It cannot say how common it is.

Usage: fate_check.py <download dir> <out.json>
"""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dolby_bits  # noqa: E402

DOWNLOADS, OUT = Path(sys.argv[1]), Path(sys.argv[2])
DOWNLOADS.mkdir(parents=True, exist_ok=True)
SAMPLES = ["ac3/monsters_inc_5.1_448_small.ac3", "ac3/monsters_inc_2.0_192_small.ac3", "ac3/millers_crossing_4.0.ac3",
           "eac3/serenity_english_5.1_1536_small.eac3", "eac3/csi_miami_5.1_256_spx_small.eac3",
           "eac3/csi_miami_stereo_128_spx.eac3", "eac3/matrix2_commentary1_stereo_192_small.eac3",
           "eac3/the_great_wall_7.1.eac3"]


def measure(path, *decoder):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", *decoder, "-i", str(path), "-af", "ebur128=peak=true",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    if "Summary:" not in err:
        return None
    summary = err[err.rindex("Summary:"):]
    return {"I": float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1)),
            "LRA": float(re.search(r"LRA:\s+([\d.]+) LU", summary).group(1)),
            "TP": float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", summary).group(1))}


def pcm_md5(path, *decoder):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", *decoder, "-i", str(path), "-f", "f32le", "-"],
                         capture_output=True).stdout
    return hashlib.md5(out).hexdigest(), len(out)


results = {}
for sample in SAMPLES:
    local = DOWNLOADS / sample.replace("/", "_")
    if not local.exists() or local.stat().st_size == 0:
        fetched = subprocess.run(["curl", "-sSfL", "--max-time", "90", "-A", "Mozilla/5.0", "-o", str(local),
                                  f"https://fate-suite.ffmpeg.org/{sample}"], capture_output=True, text=True)
        if fetched.returncode != 0:
            results[sample] = {"download_error": fetched.stderr.strip()}
            continue
    data = local.read_bytes()
    row: dict = {"bytes": len(data)}
    try:
        parsed = list(dolby_bits.frames(data))
        row["frames"] = len(parsed)
        row["dialnorm"] = sorted(dolby_bits.dialnorm_values(data))
        ac3_frames = [bytearray(data[o:o + s]) for o, s in parsed if not dolby_bits.is_eac3(data[o:o + 6])]
        if ac3_frames:
            row["frames_with_dynrng_word_block0"] = round(sum(dolby_bits.has_dynrng(f) for f in ac3_frames) / len(ac3_frames), 3)
    except (ValueError, IndexError) as error:
        row["parse_error"] = str(error)
    default_md5, size = pcm_md5(local)
    no_drc_md5, _ = pcm_md5(local, "-drc_scale", "0")
    row["seconds_decoded_approx"] = None if not size else round(size / 4 / 48000 / 2, 1)
    row["default_decode_differs_from_drc_off"] = default_md5 != no_drc_md5
    row["default"], row["drc_off"], row["dialnorm_honoured_drc_off"] = (
        measure(local), measure(local, "-drc_scale", "0"), measure(local, "-drc_scale", "0", "-target_level", "-31"))
    results[sample] = row

OUT.write_text(json.dumps(results, indent=1))
print(json.dumps(results, indent=1))
