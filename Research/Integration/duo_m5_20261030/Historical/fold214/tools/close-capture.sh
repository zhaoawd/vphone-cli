#!/bin/zsh
# close-capture.sh <tag> : with the fold already open, capture 6 s of the app's and
# SpringBoard's syslog around closing it, into run/fold214/kb/<tag>-{app,sb}.tsv
# (date, subsystem, category, message).
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
O=/Users/kolar/vphone-duo-m5/run/fold214/kb
mkdir -p $O
( $T/rpc.sh logs.syslog '{"seconds":6,"process":"FoodAIVerification","max_lines":3000}' > $O/$1-app.json ) &
( $T/rpc.sh logs.syslog '{"seconds":6,"process":"SpringBoard","max_lines":6000}' > $O/$1-sb.json ) &
/bin/sleep 1.5
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null
wait
for side in app sb; do
  jq -r '.result | (.lines // .entries // .) | .[]? | [.date, .subsystem, .category, (.message | gsub("\n"; " "))] | @tsv' \
    $O/$1-$side.json > $O/$1-$side.tsv
done
print -r -- "$1: app $(wc -l < $O/$1-app.tsv) lines, sb $(wc -l < $O/$1-sb.tsv) lines"
