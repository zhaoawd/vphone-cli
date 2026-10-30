#!/bin/zsh
# f5-analyze.zsh <f5-output-directory>: per-frame black share and luma of
# recording.mov, dark runs (>= 10% black pixels) aligned with the nearest
# preceding action and the guest FoldDisplay events after it.
# Ported from the v1.6 run/fold214/f5-analyze.sh and f5-align.sh.
set -euo pipefail
dir="${1:?usage: f5-analyze.zsh <f5-output-directory>}"
movie="$dir/recording.mov"
[[ -f "$movie" && -f "$dir/actions.tsv" && -f "$dir/t0.txt" ]] || exit 2
t0=$(<"$dir/t0.txt")

ffprobe -v error -show_entries stream=width,height,avg_frame_rate,nb_frames,duration -of compact "$movie" > "$dir/probe.txt"
ffmpeg -v error -i "$movie" -vf "scale=502:-2,blackframe=amount=0:threshold=24,signalstats,metadata=print:file=$dir/meta.txt" -f null -
awk '/^frame:/{f=$1; sub("frame:","",f); t=$3; sub("pts_time:","",t)}
     /pblack=/{split($0,a,"="); pb[f]=a[2]; ts[f]=t}
     /YAVG=/{split($0,a,"="); y[f]=a[2]}
     END{for(i in ts) printf "%d\t%.3f\t%d\t%.1f\n", i, ts[i], pb[i], y[i]}' "$dir/meta.txt" | sort -n > "$dir/frames.tsv"

# Guest FoldDisplay lines start with an epoch timestamp.
awk -v t0="$t0" '$1+0 >= t0-2 {i=index($0,"inner display:"); if(i) printf "%.3f\t%s\n", $1-t0, substr($0,i+15)}' \
    "$dir/folddisplay.log" > "$dir/events.tsv" 2>/dev/null || : > "$dir/events.tsv"

awk -F'\t' '$3>=10' "$dir/frames.tsv" | awk -F'\t' 'BEGIN{OFS="\t"}
    {if($1!=prev+1 && NR>1){print s,e,n,mx} if($1!=prev+1||NR==1){s=$2;n=0;mx=0} e=$2;n++; if($3>mx)mx=$3; prev=$1}
    END{if(NR) print s,e,n,mx}' > "$dir/runs.tsv"

# The recorder's first frame lags the menu press by about 0.7 s (v1.6).
# F5_OFFSET overrides it; the value used is written to the output.
offset="${F5_OFFSET:-0.7}"
print -r -- "$offset" > "$dir/offset.txt"
awk -F'\t' -v off="$offset" '
FILENAME==ARGV[1] {at[++n]=$1; al[n]=$2; next}
FILENAME==ARGV[2] {et[++m]=$1; ev[m]=$2; next}
{ s=$1+off; e=$2+off; best=0; bd=99
  for(i=1;i<=n;i++){d=s-at[i]; if(d>-0.3 && d<bd){bd=d; best=i}}
  label = best ? al[best] : "(before first action)"; base = best ? at[best] : 0
  evs=""
  for(j=1;j<=m;j++) if(best && et[j]>=base-0.05 && et[j]<=base+2.2 && ev[j] ~ /hold o|shown=/) {
      tag = ev[j] ~ /hold on/ ? "hold-on" : ev[j] ~ /hold off/ ? "hold-off" : substr(ev[j],1,7)
      evs = evs sprintf(" %s@+%d", tag, (et[j]-base)*1000) }
  printf "%-24s dark +%5d..+%5dms (%3d fr, max %3d%%) |%s\n", label, (s-base)*1000, (e-base)*1000+33, $3, $4, evs }' \
    "$dir/actions.tsv" "$dir/events.tsv" "$dir/runs.tsv" > "$dir/aligned.txt"

{
    cat "$dir/probe.txt"
    print -r -- "frames: $(wc -l < "$dir/frames.tsv")"
    print -r -- "frames with >=10% black: $(awk -F'\t' '$3>=10' "$dir/frames.tsv" | wc -l | tr -d ' ')"
    print -r -- "dark runs: $(wc -l < "$dir/runs.tsv" | tr -d ' ')"
    print -r -- "failed actions: $(awk -F'\t' '$3 !~ /"ok":true/' "$dir/actions.tsv" | cut -f2 | paste -sd, -)"
} > "$dir/summary.txt"
cat "$dir/summary.txt" "$dir/aligned.txt"
