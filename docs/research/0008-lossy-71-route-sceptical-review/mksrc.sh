#!/bin/bash
# mksrc.sh NAME "LAYOUT" NCH EXT CODEC [extra ffmpeg args]  -> /tmp/l71/src/NAME.EXT
n=$1; lay=$2; nch=$3; ext=$4; codec=$5; shift 5
map=""; for ((i=0;i<nch;i++)); do map="$map|c$i=0.${i}1*c0"; done
if [ "$lay" = "unnamed" ]; then
  filt="pan=${nch}c$map"
else
  filt="pan=$lay$map"
fi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:size=64x64:duration=6:rate=10" \
  -f lavfi -i "anoisesrc=color=pink:duration=6:sample_rate=48000:amplitude=0.05:seed=7,aformat=channel_layouts=mono,$filt" \
  -c:v libx264 -preset ultrafast -c:a $codec "$@" /tmp/l71/src/$n.$ext
