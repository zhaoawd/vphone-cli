#!/bin/zsh
# js.sh <file.js|-> : run JavaScript in duo-m5-fold214's vphoned script session, print output and result.
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
src=$(cat ${1:--})
jq -nc --arg s "$src" '{t:"rpc",method:"script.eval",params:{source:$s,timeout:60}}' | nc -U -w 70 $S | jq -r '.result.output // empty, (.result.result // empty | tostring), (.error // .result.error // empty | tostring)'
