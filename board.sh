#!/bin/bash
# Board check for AV1 operating point handling in MPP.
#
# Layout on the board (extract the tarballs into base/ and fix/):
#   /tmp/av1op/base/{lib,bin/mpi_dec_test}   MPP 20959ec3
#   /tmp/av1op/fix/{lib,bin/mpi_dec_test}    MPP 20959ec3 + the operating point idc fix
#   /tmp/av1op/in/*.ivf                      test streams
#   /tmp/av1op/ref/<stream>.md5,.info        libdav1d reference: one md5 per NV12 frame, "WxH frames"
#
# Usage: board.sh [stream ...]     (names without .ivf; default: every file in in/)
# Env:   ROOT=/tmp/av1op  BUILDS="base fix"  TMO=60  KEEP=1 (keep the raw output files)
#
# For each build and stream: runs mpi_dec_test -t AV1 -f 0 (NV12) -o, then reports
#   rc      0 ok, 124 timeout, 139 SIGSEGV, other = error exit
#   frames  "decode get frame" lines / frames written to the output file
#   err     frames MPP flagged with err/discard, plus mpp error lines
#   match   output frames whose md5 equals the libdav1d frame at the same index / reference frame count
#   dmesg   new kernel log lines that mention the decoder, mmu faults, timeouts or errors
set -u

ROOT=${ROOT:-/tmp/av1op}
BUILDS=${BUILDS:-"base fix"}
TMO=${TMO:-60}
OUT=$ROOT/out
mkdir -p "$OUT"

[ -e /dev/mpp_service ] || echo "NOTE /dev/mpp_service is missing, hardware decoding will fail"

if [ $# -gt 0 ]; then
	STREAMS=("$@")
else
	STREAMS=()
	for f in "$ROOT"/in/*.ivf; do
		STREAMS+=("$(basename "$f" .ivf)")
	done
fi

md5_frames() { # file framesize -> one md5 per frame
	local f=$1 fs=$2 n i
	n=$(( $(stat -c %s "$f") / fs ))
	for ((i = 0; i < n; i++)); do
		dd if="$f" bs="$fs" skip="$i" count=1 status=none | md5sum | cut -d' ' -f1
	done
}

printf '%-6s %-12s %-5s %-12s %-6s %-10s %s\n' build stream rc frames err match dmesg
for n in "${STREAMS[@]}"; do
	in=$ROOT/in/$n.ivf
	[ -f "$in" ] || { echo "missing $in"; continue; }
	ref=$ROOT/ref/$n.md5
	info=$ROOT/ref/$n.info
	rw=0; rh=0; rn=0
	[ -f "$info" ] && read -r wh rn < "$info" && rw=${wh%x*} && rh=${wh#*x}

	for b in $BUILDS; do
		bin=$ROOT/$b/bin/mpi_dec_test
		[ -x "$bin" ] || { echo "missing $bin"; continue; }
		raw=$OUT/$b-$n.nv12
		log=$OUT/$b-$n.log
		rm -f "$raw"

		dmesg > "$OUT/dmesg.before" 2>/dev/null
		LD_LIBRARY_PATH=$ROOT/$b/lib timeout -k 2 "$TMO" "$bin" -t 16777224 -f 0 -i "$in" -o "$raw" > "$log" 2>&1
		rc=$?
		dmesg > "$OUT/dmesg.after" 2>/dev/null
		kl=$(diff "$OUT/dmesg.before" "$OUT/dmesg.after" | sed -n 's/^> //p' |
			grep -iE 'rkvdec|mpp|av1|vdpu|iommu|fault|timeout|hung|error|oops|bug' | head -8)

		got=$(grep -c 'decode get frame' "$log")
		errfrm=$(grep -c 'decode get frame.* err ' "$log")
		errln=$(grep -ciE 'mpp_err|failed|error' "$log")
		wrote=0; match="-"
		if [ -s "$raw" ] && [ "$rw" -gt 0 ]; then
			fs=$(( rw * rh * 3 / 2 ))
			wrote=$(( $(stat -c %s "$raw") / fs ))
			if [ -f "$ref" ]; then
				mine=$OUT/$b-$n.md5
				md5_frames "$raw" "$fs" > "$mine"
				ok=$(paste -d' ' "$ref" "$mine" | awk 'NF == 2 && $1 == $2' | wc -l)
				match="$ok/$rn"
			fi
		fi
		[ "${KEEP:-0}" = 1 ] || rm -f "$raw"

		printf '%-6s %-12s %-5s %-12s %-6s %-10s %s\n' "$b" "$n" "$rc" "$got/$wrote" "$errfrm/$errln" "$match" \
			"$(echo "$kl" | head -1)"
		echo "$kl" | tail -n +2 | sed 's/^/                                                                  /'
	done
done
echo "frames = decode get frame lines / frames in the output file; err = flagged frames / error lines; per-run logs in $OUT"
