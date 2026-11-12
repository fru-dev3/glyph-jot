#!/bin/zsh
# A made-up two-person conversation for testing speaker labels: macOS `say` with two voices,
# turns joined with short pauses. Writes <out>.m4a and <out>.truth.txt (speaker start end, seconds).
# Usage: RecordTests/make-two-voices.sh /path/to/out   (no extension)
set -euo pipefail
out=${1:?usage: make-two-voices.sh /path/to/out}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

lines=(
  "Samantha|Good morning. Thanks for making time today. I wanted to go over the plan for the garden project before the weekend."
  "Daniel|Of course. I looked at the drawings last night, and I think the raised beds should go along the south fence where they get the most sun."
  "Samantha|That makes sense. How many beds were you thinking, and do we have enough cedar for all of them?"
  "Daniel|Four beds, each about eight feet long. We have enough cedar for three, so I will order the rest on Monday."
  "Samantha|Great. Then I will handle the soil and the compost, and we can plant the tomatoes the week after."
  "Daniel|Sounds good. Let us meet again on Thursday to check the progress and decide on the irrigation."
)

: > $out.truth.txt
list=$tmp/list.txt
: > $list
t=0
i=0
for entry in $lines; do
  voice=${entry%%|*}; text=${entry#*|}
  i=$((i + 1))
  say -v $voice -o $tmp/$i.aiff "$text"
  ffmpeg -loglevel error -y -i $tmp/$i.aiff -ar 16000 -ac 1 $tmp/$i.wav
  ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 0.6 $tmp/gap$i.wav
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $tmp/$i.wav)
  printf '%s %.2f %.2f\n' $voice $t $((t + d)) >> $out.truth.txt
  t=$((t + d + 0.6))
  print "file '$tmp/$i.wav'\nfile '$tmp/gap$i.wav'" >> $list
done
ffmpeg -loglevel error -y -f concat -safe 0 -i $list -c:a aac -b:a 96k $out.m4a
cat $out.truth.txt
