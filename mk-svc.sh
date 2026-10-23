#!/bin/bash
# Builds scalable AV1 test streams with libaom's svc_encoder_rtc (+ a plain aomenc control).
set -e
cd "$(dirname "$0")"
E=./aom-build/examples/svc_encoder_rtc
SRC=src/testsrc.y4m
mkdir -p in raw
enc() { # name sl tl mode total bitrates
	$E -w 320 -h 240 -t 1/30 -b $5 -bl $6 -sl $2 -tl $3 -lm $4 -k 9999 --test-decode=0 $SRC -o raw/$1.ivf > raw/$1.log 2>&1
}
enc l1t1 1 1 0 300 300
enc l1t2 1 2 1 300 200,300
enc l1t3 1 3 2 300 150,220,300
enc l2t1 2 1 5 400 100,300
enc l2t3 2 3 7 400 60,80,100,200,250,300
enc l3t1 3 1 6 500 50,150,300
ls -l raw/*.ivf
