#!/usr/bin/env python3
"""What FFmpeg and neutraliser do with Dolby loudness metadata, on synthetic clips.

Evidence for docs/research/0002-streaming-loudness-and-dialogue/research.md. Runs the real CLI on generated
media in a scratch folder. No library, no NAS.

Usage: dolby_tests.py <repo root> <scratch dir>
Prints results and writes <scratch dir>/dolby_results.json.

"Decoder honouring dialnorm" below is simulated with FFmpeg's `-target_level -31`, which applies the gain
ATSC describes: the difference between -31 and the dialnorm value. No hardware decoder was tested.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dolby_bits  # noqa: E402

REPO, SCRATCH = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
SCRATCH.mkdir(parents=True, exist_ok=True)
RESULTS = {}


def run(*cmd, check=True, env=None):
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=env)
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(str(c) for c in cmd)}\n{proc.stderr[-1500:]}")
    return proc


def ffmpeg(*args):
    return run("ffmpeg", "-hide_banner", "-nostats", "-y", *args)


def loudness(path, decoder_args=()):
    """Integrated loudness, LRA and true peak as the given decoder settings hear the first audio stream."""
    err = run("ffmpeg", "-hide_banner", "-nostats", *decoder_args, "-i", path, "-map", "0:a:0",
              "-af", "ebur128=peak=true", "-f", "null", "-").stderr
    summary = err[err.rindex("Summary:"):]
    return {
        "I": float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1)),
        "LRA": float(re.search(r"LRA:\s+([\d.]+) LU", summary).group(1)),
        "TP": float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", summary).group(1)),
    }


def pcm_md5(path, decoder_args=()):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", *decoder_args, "-i", str(path), "-map", "0:a:0",
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return hashlib.md5(out).hexdigest()


def crc_clean(path):
    """True when FFmpeg's decoder, told to verify CRCs, reports nothing wrong."""
    proc = run("ffmpeg", "-hide_banner", "-nostats", "-err_detect", "crccheck+explode", "-i", path,
               "-f", "null", "-", check=False)
    return proc.returncode == 0 and "CRC" not in proc.stderr and "error" not in proc.stderr.lower()


def make_programme(path, seconds=60, quiet_db=-34, loud_db=-14, loud_every=20, loud_len=4):
    """Pink noise with loud passages: a stand-in for a mix with a loudness range. 48 kHz stereo WAV."""
    expr = f"if(lt(mod(t\\,{loud_every})\\,{loud_len})\\,{10 ** (loud_db / 20):.5f}\\,{10 ** (quiet_db / 20):.5f})"
    ffmpeg("-f", "lavfi", "-i", f"anoisesrc=color=pink:sample_rate=48000:seed=7:duration={seconds}",
           "-af", f"volume='{expr}':eval=frame,aformat=channel_layouts=stereo", "-c:a", "pcm_s16le", path)


def to_mkv(audio_path, out_path):
    """Wrap audio with a tiny video stream: neutraliser only takes video files."""
    seconds = float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", audio_path).stdout)
    ffmpeg("-f", "lavfi", "-i", f"color=c=black:s=64x64:r=5:d={seconds:.2f}", "-i", audio_path,
           "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy", "-shortest", out_path)


def extract(path, fmt, out):
    ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "copy", "-f", fmt, out)
    return Path(out).read_bytes()


def neutraliser(*args):
    env = dict(os.environ, LANG="en_US.UTF-8")
    env["PATH"] = f"{Path.home()}/.rbenv/shims:{env['PATH']}"
    env.pop("BUNDLE_GEMFILE", None)
    env["BUNDLE_GEMFILE"] = str(REPO / "Gemfile")
    return run("bundle", "exec", REPO / "bin/neutraliser", *args, check=False, env=env)


def tags(path):
    probe = json.loads(run("ffprobe", "-v", "error", "-show_entries", "stream_tags:format_tags", "-of", "json", path).stdout)
    merged = {}
    for stream in probe.get("streams", []):
        merged.update({k.upper(): v for k, v in stream.get("tags", {}).items() if k.upper().startswith("NEUTRALISER")})
    return merged


# ---------------------------------------------------------------------------------------------------------------------
DOLBY = ("-target_level", "-31")  # simulates a decoder that honours dialnorm, in line mode
NO_DRC = ("-drc_scale", "0")

base_wav = SCRATCH / "programme.wav"
make_programme(base_wav)

# T1: does FFmpeg's default decode honour dialnorm?
t1 = {}
for codec, ext in (("ac3", "ac3"), ("eac3", "eac3")):
    path = SCRATCH / f"t1_dn24.{ext}"
    ffmpeg("-i", base_wav, "-c:a", codec, "-b:a", "192k", "-dialnorm", "-24", path)
    data = path.read_bytes()
    t1[codec] = {
        "dialnorm_in_stream": sorted(dolby_bits.dialnorm_values(data)),
        "default_decode_I": loudness(path)["I"],
        "target_level_decode_I": loudness(path, DOLBY)["I"],
    }
RESULTS["T1 FFmpeg default decode ignores dialnorm"] = t1

# T2: can dialnorm be rewritten in place without touching the audio?
t2 = {}
for codec, ext in (("ac3", "ac3"), ("eac3", "eac3")):
    src = SCRATCH / f"t1_dn24.{ext}"
    patched = SCRATCH / f"t2_dn27.{ext}"
    patched.write_bytes(dolby_bits.set_dialnorm(src.read_bytes(), -27))
    t2[codec] = {
        "dialnorm_after": sorted(dolby_bits.dialnorm_values(patched.read_bytes())),
        "pcm_identical_default_decode": pcm_md5(src) == pcm_md5(patched),
        "crc_clean_before": crc_clean(src),
        "crc_clean_after": crc_clean(patched),
        "level_shift_under_dialnorm_decode_LU": round(loudness(patched, DOLBY)["I"] - loudness(src, DOLBY)["I"], 2),
    }
RESULTS["T2 in-place dialnorm rewrite is lossless"] = t2

# T3: what does a real neutraliser run do to dialnorm, and what does that do to a pair of files?
t3 = {}
for codec, ext, fmt in (("ac3", "ac3", "ac3"), ("eac3", "eac3", "eac3")):
    workdir = SCRATCH / f"t3_{codec}"
    shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir()
    pair = {}
    for name, gain in (("near_target", 0.0), ("quiet", None)):
        wav = SCRATCH / f"t3_{name}.wav"
        if gain is None:
            ffmpeg("-i", base_wav, "-af", "volume=-6dB", "-c:a", "pcm_s16le", wav)
        else:
            shutil.copy(base_wav, wav)
        enc = SCRATCH / f"t3_{name}.{ext}"
        ffmpeg("-i", wav, "-c:a", codec, "-b:a", "192k", "-dialnorm", "-24", enc)
        mkv = workdir / f"{name}.mkv"
        to_mkv(enc, mkv)
        pair[name] = {"before": {"raw": loudness(mkv), "dolby": loudness(mkv, DOLBY)}}
    target = round(pair["near_target"]["before"]["raw"]["I"], 1)
    # The target is the louder file's own level: it is within tolerance and left alone, the quiet one gets +6 dB.
    cli = neutraliser("process", workdir, "--replace", "--no-cache", "--target-level", target, "--tolerance", "1.0")
    for name in pair:
        mkv = workdir / f"{name}.mkv"
        stream = extract(mkv, fmt, SCRATCH / f"t3_{name}_out.{ext}")
        pair[name]["after"] = {"raw": loudness(mkv), "dolby": loudness(mkv, DOLBY),
                               "dialnorm": sorted(dolby_bits.dialnorm_values(stream)),
                               "stamp_mode": tags(mkv).get("NEUTRALISER_MODE")}
    t3[codec] = {"target": target, "cli_exit": cli.returncode, "files": pair,
                 "gap_before_dolby_LU": round(pair["near_target"]["before"]["dolby"]["I"] - pair["quiet"]["before"]["dolby"]["I"], 2),
                 "gap_after_dolby_LU": round(pair["near_target"]["after"]["dolby"]["I"] - pair["quiet"]["after"]["dolby"]["I"], 2),
                 "gap_before_raw_LU": round(pair["near_target"]["before"]["raw"]["I"] - pair["quiet"]["before"]["raw"]["I"], 2),
                 "gap_after_raw_LU": round(pair["near_target"]["after"]["raw"]["I"] - pair["quiet"]["after"]["raw"]["I"], 2)}
RESULTS["T3 neutraliser and dialnorm"] = t3

# T4: does FFmpeg's default decode, and so a neutraliser constant-gain run, bake in the stream's DRC?
ac3 = SCRATCH / "t4_plain.ac3"
ffmpeg("-i", base_wav, "-c:a", "ac3", "-b:a", "192k", ac3)
plain = ac3.read_bytes()
FRAME_SECONDS = 1536 / 48000
LOUD_EVERY, LOUD_LEN = 20, 4
# 0xD3: X = -2, Y = 0b10011: 2^-2 * (1 + 19/32) = 0.398, about -8 dB (A/52 dynrng format)
code = lambda i: 0xD3 if (i * FRAME_SECONDS) % LOUD_EVERY < LOUD_LEN else 0x00  # noqa: E731
with_drc = SCRATCH / "t4_drc.ac3"
with_drc.write_bytes(dolby_bits.add_dynrng(plain, code))
no_word = SCRATCH / "t4_nodrc.ac3"
no_word.write_bytes(dolby_bits.add_dynrng(plain, lambda i: None))
workdir = SCRATCH / "t4_run"
shutil.rmtree(workdir, ignore_errors=True)
workdir.mkdir()
mkv = workdir / "with_drc.mkv"
to_mkv(with_drc, mkv)
before_no_drc, before_default = loudness(mkv, NO_DRC), loudness(mkv)
ctrl = workdir / "ctrl.mkv"
to_mkv(no_word, ctrl)
ctrl_before = loudness(ctrl, NO_DRC)
cli = neutraliser("process", workdir, "--replace", "--no-cache", "--target-level", round(before_default["I"] + 3, 1),
                  "--tolerance", "0.5")
RESULTS["T4 DRC words and the constant-gain path"] = {
    "edit_is_clean": {"pcm_identical_at_drc0_with_vs_without_word": pcm_md5(with_drc, NO_DRC) == pcm_md5(no_word, NO_DRC),
                      "crc_clean": crc_clean(with_drc)},
    "source_drc_off": before_no_drc,
    "source_default_decode": before_default,
    "after_run_default_decode": loudness(mkv),
    "after_run_drc_off": loudness(mkv, NO_DRC),
    "output_has_dynrng_words": any(dolby_bits.has_dynrng(bytearray(s[o:o + n]))
                                   for s in [extract(mkv, "ac3", SCRATCH / "t4_out.ac3")]
                                   for o, n in dolby_bits.frames(s)),
    "stamp": {k: v for k, v in tags(mkv).items() if k in ("NEUTRALISER_MODE", "NEUTRALISER_GAIN_DB", "NEUTRALISER_MEASURED_LRA", "NEUTRALISER_MEASURED_I")},
    "control_no_drc_words_before": ctrl_before,
    "control_no_drc_words_after_default": loudness(ctrl),
    "control_stamp": {k: v for k, v in tags(ctrl).items() if k in ("NEUTRALISER_MODE", "NEUTRALISER_GAIN_DB", "NEUTRALISER_MEASURED_LRA")},
    "cli_exit": cli.returncode,
}

# T5: Opus output gain: the one metadata gain FFmpeg applies by default.
opus_src = SCRATCH / "t5.mkv"
ffmpeg("-f", "lavfi", "-i", "color=c=black:s=64x64:r=5:d=60", "-i", base_wav, "-map", "0:v", "-map", "1:a",
       "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "libopus", "-b:a", "128k", "-shortest", opus_src)
opus_out = SCRATCH / "t5_gain.mkv"
bsf = run("ffmpeg", "-hide_banner", "-y", "-i", opus_src, "-map", "0", "-c", "copy", "-bsf:a", "opus_metadata=gain=-1536",
          opus_out, check=False)
RESULTS["T5 Opus output gain"] = {
    "bsf_exit": bsf.returncode,
    "bsf_error": bsf.stderr[-300:] if bsf.returncode else None,
    "before_I": loudness(opus_src)["I"],
    "after_I": loudness(opus_out)["I"] if bsf.returncode == 0 else None,
}

out_path = SCRATCH / "dolby_results.json"
out_path.write_text(json.dumps(RESULTS, indent=2))
print(json.dumps(RESULTS, indent=2))
