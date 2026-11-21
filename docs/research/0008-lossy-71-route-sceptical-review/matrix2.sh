#!/bin/bash
export PATH=/tmp/l71/bin:$PATH
R=/tmp/l71/run.sh
t() { echo; echo "=== $*"; }
t "G1 avi 7.1 eac3 aac"; FAKE_FROM=pcm_s16le FAKE_BITRATE=1024000 $R pcm71_avi --allow-codec-change --lossy71 aac
t "G2 avi 7.1 eac3 opus"; FAKE_FROM=pcm_s16le FAKE_BITRATE=1024000 $R pcm71_avi --allow-codec-change --lossy71 opus
t "G3 avi 7.1 eac3 no flag"; FAKE_FROM=pcm_s16le FAKE_BITRATE=1024000 $R pcm71_avi --allow-codec-change
t "H1 mov 7.1 eac3 aac"; FAKE_FROM=pcm_s16le FAKE_BITRATE=1024000 $R pcm71_mov --allow-codec-change --lossy71 aac
t "H2 mov 7.1 eac3 opus"; FAKE_FROM=pcm_s16le FAKE_BITRATE=1024000 $R pcm71_mov --allow-codec-change --lossy71 opus
t "I1 m4v 7.1 eac3 aac"; FAKE_BITRATE=1024000 $R lossy71_m4v --allow-codec-change --lossy71 aac
t "J1 mkv 7.1 dts(lossy HRA) aac"; FAKE_CODEC=dts FAKE_PROFILE='DTS-HD HRA' FAKE_BITRATE=1509000 $R flac71_mkv --allow-codec-change --lossy71 aac
t "J2 mkv 7.1 dts-hd ma (lossless) aac -> expect flac"; FAKE_CODEC=dts FAKE_PROFILE='DTS-HD MA' FAKE_BITRATE=4000000 $R flac71_mkv --allow-codec-change --lossy71 aac
t "J3 mp4 7.1 dts-hd ma (lossless) aac -> expect aac"; FAKE_CODEC=dts FAKE_PROFILE='DTS-HD MA' FAKE_BITRATE=4000000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "J4 mp4 7.1 truehd aac"; FAKE_CODEC=truehd FAKE_BITRATE=4000000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "J5 mkv 7.1 truehd aac -> flac"; FAKE_CODEC=truehd FAKE_BITRATE=4000000 $R flac71_mkv --allow-codec-change --lossy71 aac
t "K1 mp4 7.1 ac3 (fake) aac, low bitrate 448k"; FAKE_CODEC=ac3 FAKE_BITRATE=448000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "K2 mp4 7.1 eac3 high bitrate 6M"; FAKE_BITRATE=6000000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "K3 mp4 7.1 eac3 no bit_rate in probe"; FAKE_BITRATE= $R flac71_mp4 --allow-codec-change --lossy71 aac
t "L1 mp4 7.1 eac3 --fast aac"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac --fast
t "L2 mp4 7.1 eac3 --allow-dynamic opus"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 opus --allow-dynamic
t "L3 mp4 7.1 eac3 keep-original-audio aac"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac --keep-original-audio
t "L4 mp4 7.1 eac3 ladder aac"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac --ladder
t "L5 bad value"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 mp3
t "L6 dry-run aac"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac --dry-run
