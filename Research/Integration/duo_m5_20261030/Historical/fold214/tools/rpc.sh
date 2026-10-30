#!/bin/zsh
# rpc.sh <method> [json-params] : one RPC to duo-m5-fold214's vphoned through the VM socket.
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
print -r -- "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | nc -U -w 30 $S 2>/dev/null
