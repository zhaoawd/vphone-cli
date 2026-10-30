#!/bin/zsh
# f5-align.sh <tag> : line up f5/<tag>'s dark-frame runs with the actions and
# the guest's FoldDisplay log (hold on/off, shown). Video time + 0.7 s is
# taken as host time since T0 (the recorder starts about that much later).
set -euo pipefail
D=/Users/kolar/vphone-duo-m5/run/fold214/f5/${1:?tag}
T0=$(cat $D/t0.txt)
/Users/kolar/vphone-duo-m5/run/fold214/tools/js.sh - > $D/folddisplay.log <<EOF
var lo = $T0 - 2, hi = $T0 + 140;
String(fs.read('/var/mobile/Library/Caches/vphone-folddisplay.log')).split('\n').forEach(function (l) { var t = parseFloat(l); if (t >= lo && t <= hi) print(l); });
EOF
awk -v t0=$T0 '{printf "%.3f\t%s\n", $1-t0, substr($0, index($0,"inner display:")+15)}' $D/folddisplay.log > $D/events.tsv
awk -F'\t' '$3>=10{print}' $D/frames.tsv | awk -F'\t' 'BEGIN{OFS="\t"} {if($1!=prev+1 && NR>1){print s,e,n,mx} if($1!=prev+1||NR==1){s=$2;n=0;mx=0} e=$2;n++; if($3>mx)mx=$3; prev=$1} END{if(NR) print s,e,n,mx}' > $D/runs.tsv
awk -F'\t' -v off=0.7 '
FILENAME==ARGV[1] {at[++n]=$1; al[n]=$2; next}
FILENAME==ARGV[2] {et[++m]=$1; ev[m]=$2; next}
{ s=$1+off; e=$2+off; best=0; bd=99; for(i=1;i<=n;i++){d=s-at[i]; if(d>-0.3 && d<bd){bd=d; best=i}}
  evs=""; for(j=1;j<=m;j++) if(et[j]>=at[best]-0.05 && et[j]<=at[best]+2.2 && ev[j] ~ /hold o|shown=/) {
    tag = ev[j] ~ /hold on/ ? "hold-on" : ev[j] ~ /hold off/ ? "hold-off" : substr(ev[j],1,7)
    evs = evs sprintf(" %s@+%d", tag, (et[j]-at[best])*1000) }
  printf "%-22s dark +%4d..+%4dms (%2d fr, max %3d%%) |%s\n", al[best], (s-at[best])*1000, (e-at[best])*1000+33, $3, $4, evs }' $D/actions.tsv $D/events.tsv $D/runs.tsv | tee $D/aligned.txt
