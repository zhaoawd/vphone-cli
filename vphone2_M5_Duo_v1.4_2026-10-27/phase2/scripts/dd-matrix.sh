#!/bin/zsh
# D0-D3 dual-display control matrix on duo-m5-dd (feedback-driven: separate port
# capacity from attached-display count, capture the first failure layer, don't
# assume the XPC service re-checks). Each row boots the SAME pr728-dd bundle with
# different VPHONE_DISPLAY_* env; on success it probes ioreg/screen then stops;
# on failure it keeps the deep error. Leaves no VM running.
set -uo pipefail
VM=duo-m5-dd
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=${MATRIX_OUT:-/Users/kolar/vphone-duo-m5/run/phase2/matrix}
mkdir -p $OUT
rpc() { print -r -- "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | nc -U -w 60 $S 2>/dev/null || true }

# row: tag PORTS COUNT LAYOUT SCALE expectation
rows=(
  "D0 1 1 ports 1 control: must boot"
  "D1 2 1 ports 1 2 ports / 1 display: predicted FAIL (service internal-content gate on port>=2)"
  "D2 2 2 ports 1 2 ports / 2 displays: predicted FAIL (same gate)"
  "D3 2 2 ports 4 2 ports / 2 displays, 2nd quarter-size: resource-size control"
  "Ddev 2 2 devices 1 two graphics devices: predicted reject at validate (Code=2)"
)

print "tag\tports\tcount\tlayout\tready_or_fail\tcode\tnote" > $OUT/results.tsv
only=($@)   # optional: run only these tags, e.g. dd-matrix.sh D0 Ddev
for r in $rows; do
  set -- ${(z)r}
  (( ${#only} )) && (( ! ${only[(Ie)$1]} )) && continue
  tag=$1; ports=$2; count=$3; layout=$4; scale=$5
  d=$OUT/$tag; mkdir -p $d
  print "\n===== $tag ports=$ports count=$count layout=$layout scale=$scale ====="
  t0=$(date +%s); ready=""
  VPHONE_DISPLAY_DIAG=1 VPHONE_DISPLAY_PORTS=$ports VPHONE_DISPLAY_COUNT=$count \
    VPHONE_DISPLAY_LAYOUT=$layout VPHONE_DISPLAY2_SCALE=$scale \
    nohup $B vm launch $VM -v > $d/boot.log 2>&1 &
  pid=$!
  while (( $(date +%s) - t0 < 240 )); do
    if ! kill -0 $pid 2>/dev/null; then break; fi
    if [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1; then ready=$(( $(date +%s) - t0 )); break; fi
    /bin/sleep 2
  done
  if [[ -n $ready ]]; then
    print "$tag ready=${ready}s"
    rpc device.ioreg > $d/ioreg.json 2>/dev/null
    rpc device.screen | jq -c '.result' > $d/screen.json 2>/dev/null
    grep -E 'diag:|Display:' $d/boot.log | head -20
    rpc system.shutdown > /dev/null 2>&1; sleep 6
    print "$tag\t$ports\t$count\t$layout\tREADY=${ready}s\t-\tbooted" >> $OUT/results.tsv
  else
    code=$(grep -oE 'Code=[0-9]+' $d/boot.log | head -1)
    print "$tag FAILED $code"
    grep -E 'diag:|Display:|Fatal:|Stopped with error|Domain=|underlying|Code=' $d/boot.log | head -30
    print "$tag\t$ports\t$count\t$layout\tFAIL\t${code:-none}\tsee $d/boot.log" >> $OUT/results.tsv
  fi
  # Always tear the whole VM down by machine name: killing the launch process
  # alone leaves vphone-vm running and the next row would contend for the socket.
  kill -INT $pid 2>/dev/null; sleep 2
  pkill -INT -f "machines/$VM/" 2>/dev/null; sleep 4
  pkill -f "machines/$VM/" 2>/dev/null; pkill -f "vm launch $VM" 2>/dev/null
  wait $pid 2>/dev/null
  while pgrep -f "machines/$VM/" > /dev/null 2>&1; do sleep 1; done
  sleep 2
done
print "\n===== matrix done ====="
cat $OUT/results.tsv
