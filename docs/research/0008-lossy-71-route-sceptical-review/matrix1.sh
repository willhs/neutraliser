#!/bin/bash
export PATH=/tmp/l71/bin:$PATH
R=/tmp/l71/run.sh
t() { echo; echo "=== $*"; }
t "A1 mkv 7.1 eac3 default (--allow-codec-change)"; FAKE_BITRATE=1024000 $R flac71_mkv --allow-codec-change
t "A2 mkv 7.1 eac3 aac"; FAKE_BITRATE=1024000 $R flac71_mkv --allow-codec-change --lossy71 aac
t "A3 mkv 7.1 eac3 opus"; FAKE_BITRATE=1024000 $R flac71_mkv --allow-codec-change --lossy71 opus
t "B1 mkv 7.1(wide) eac3 opus"; FAKE_BITRATE=1024000 $R flac71wide_mkv --allow-codec-change --lossy71 opus
t "B2 mkv 7.1(wide) eac3 aac"; FAKE_BITRATE=1024000 $R flac71wide_mkv --allow-codec-change --lossy71 aac
t "C1 mp4 7.1 eac3 no flags"; FAKE_BITRATE=1024000 $R flac71_mp4
t "C2 mp4 7.1 eac3 --allow-codec-change only"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change
t "C3 mp4 7.1 eac3 --lossy71 aac only (no consent)"; FAKE_BITRATE=1024000 $R flac71_mp4 --lossy71 aac
t "C4 mp4 7.1 eac3 aac+consent"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "C5 mp4 7.1 eac3 opus+consent"; FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 opus
t "D1 mp4 7.1(wide) eac3 no flag"; FAKE_LAYOUT='7.1(wide)' FAKE_BITRATE=1024000 $R flac71_mp4
t "D2 mp4 7.1(wide) eac3 opus"; FAKE_LAYOUT='7.1(wide)' FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 opus
t "D3 mp4 7.1(wide) eac3 aac"; FAKE_LAYOUT='7.1(wide)' FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "E1 mp4 unnamed 8ch eac3 no flag"; FAKE_LAYOUT=none FAKE_BITRATE=1024000 $R flac71_mp4
t "E2 mp4 unnamed 8ch eac3 opus"; FAKE_LAYOUT=none FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 opus
t "E3 mp4 unnamed 8ch eac3 aac"; FAKE_LAYOUT=none FAKE_BITRATE=1024000 $R flac71_mp4 --allow-codec-change --lossy71 aac
t "F1 mp4 6.1 (7ch) eac3 no flag"; FAKE_BITRATE=640000 $R flac61_mp4
t "F2 mp4 6.1 (7ch) eac3 opus"; FAKE_BITRATE=640000 $R flac61_mp4 --allow-codec-change --lossy71 opus
t "F3 mp4 6.1 (7ch) eac3 aac"; FAKE_BITRATE=640000 $R flac61_mp4 --allow-codec-change --lossy71 aac
