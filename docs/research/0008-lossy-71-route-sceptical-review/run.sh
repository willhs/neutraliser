#!/bin/bash
# run.sh SRCNAME [neutraliser process args...]  (env FAKE_* passes to the ffprobe shim if PATH has /tmp/l71/bin first)
export PATH="$HOME/.rbenv/shims:$PATH" LANG=en_US.UTF-8
src=$1; shift
d=/tmp/l71/out/$(date +%s%N); mkdir -p $d; f=$(ls /tmp/l71/src/$src.*); cp $f $d/
file=$d/$(basename $f)
cd $NEUTRALISER_CHECKOUT
bundle exec bin/neutraliser process "$file" --replace "$@" 2>&1 | grep -v "^Ignoring racc" | cut -c1-330
echo "-- result: $(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,channel_layout,bit_rate:stream_tags=NEUTRALISER_MODE,NEUTRALISER_CODEC_CHANGE -of csv=p=0 $file | tr '\n' ' ')"
echo "$file" > /tmp/l71/last
