#!/bin/zsh
# f5-analyze.sh <tag> : per-frame black ratio, luma and scene change of
# f5/<tag>/recording.mov; lists dark frames with the nearest preceding action.
set -euo pipefail
D=/Users/kolar/vphone-duo-m5/run/fold214/f5/${1:?tag}
F=$D/recording.mov
ffprobe -v error -show_entries stream=width,height,avg_frame_rate,nb_frames,duration -of compact $F
ffmpeg -v error -i $F -vf "scale=502:-2,blackframe=amount=0:threshold=24,signalstats,select='gte(scene,0)',metadata=print:file=$D/meta.txt" -f null -
ffmpeg -v error -i $F -vf "scale=502:-2,select='gte(scene,0)',metadata=print:key=lavfi.scene_score:file=$D/scene.txt" -f null -
awk '/^frame:/{f=$1; sub("frame:","",f); t=$3; sub("pts_time:","",t)}
     /pblack=/{split($0,a,"="); pb[f]=a[2]; ts[f]=t}
     /YAVG=/{split($0,a,"="); y[f]=a[2]}
     END{for(i in ts) printf "%d\t%.3f\t%d\t%.1f\n", i, ts[i], pb[i], y[i]}' $D/meta.txt | sort -n > $D/frames.tsv
awk '/^frame:/{f=$1; sub("frame:","",f)} /scene_score=/{split($0,a,"="); printf "%d\t%.4f\n", f, a[2]}' $D/scene.txt > $D/scene.tsv
print -r -- "frames: $(wc -l < $D/frames.tsv)"
print -r -- "black-pixel share histogram (% of frame, bucket: frames):"
awk '{b=int($3/10)*10; h[b]++} END{for(k in h) print "  " k ": " h[k]}' $D/frames.tsv | sort -t: -k1 -n
print -r -- "frames with >=10% black pixels, with the last action before them:"
awk -F'\t' 'NR==FNR{at[NR]=$1; al[NR]=$2; n=NR; next}
  $3>=10 {lab="(before first action)"; d=0; for(i=1;i<=n;i++) if(at[i]<=$2){lab=al[i]; d=$2-at[i]}
          printf "  frame %d t=%.3fs black=%d%% Y=%.1f  after %s +%.2fs\n", $1, $2, $3, $4, lab, d}' $D/actions.tsv $D/frames.tsv > $D/dark.txt
print -r -- "  $(wc -l < $D/dark.txt) frames"; head -80 $D/dark.txt
print -r -- "scene changes (score >= 0.08), to confirm the actions were captured:"
awk -F'\t' '$2>=0.08 {printf "  frame %d score %.3f t=%.2fs\n", $1, $2, $1/30}' $D/scene.tsv | head -80
