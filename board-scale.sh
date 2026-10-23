#!/bin/bash
# Board check for AV1 frame size changes in MPP (RK3576, VDPU383).
#
# Layout on the board (extract each MPP tarball into its own directory):
#   $ROOT/base/{lib,bin/mpi_dec_test}    MPP 20959ec3
#   $ROOT/fix/{lib,bin/mpi_dec_test}     20959ec3 + fix[hal_av1d] (cdf/colmv buffers sized from the sequence max)
#   $ROOT/stack/{lib,bin/mpi_dec_test}   20959ec3 + fix[av1d] operating point idc + fix[hal_av1d]
#   $ROOT/opidc/{lib,bin/mpi_dec_test}   20959ec3 + fix[av1d] operating point idc (optional)
#   $ROOT/in/*.ivf                       test streams
#   $ROOT/ref/<stream>.frames            libdav1d reference: one "W H md5" line per output frame
#
# Usage: board-scale.sh [stream ...]     (names without .ivf; default: every file in in/)
# Env:   ROOT=/tmp/av1scale  BUILDS="base fix stack"  TMO=60  KEEP=1 (keep the raw output files)
#
# For each build and stream: runs mpi_dec_test -t AV1 -f 0 (NV12) -o, then reports
#   rc      0 ok, 124 timeout, 139 SIGSEGV, other = error exit
#   frames  "decode get frame" lines / frames written to the output file (sizes taken from the reference)
#   err     "decode get frame" lines with err/discard set, plus mpp error lines
#   match   output frames whose md5 equals the libdav1d frame at the same index / reference frame count
#   first   index of the first output frame that does not match (- if all match)
#   dmesg   new kernel log lines that mention the decoder, mmu faults, timeouts or errors
# mpi_dec_test does not write frames that carry err_info, so after such a frame the indexes no longer line up.
set -u

ROOT=${ROOT:-/tmp/av1scale}
BUILDS=${BUILDS:-"base fix stack"}
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

# compare <raw> <ref.frames> <md5 out> -> prints "written matched first"
compare() {
	local raw=$1 ref=$2 mine=$3 total off=0 n=0 ok=0 first=- w h want len got
	total=$(stat -c %s "$raw")
	: > "$mine"
	while read -r w h want; do
		len=$(( w * h + (h / 2) * w ))
		[ $(( off + len )) -le "$total" ] || break
		got=$(dd if="$raw" iflag=skip_bytes,count_bytes skip="$off" count="$len" status=none | md5sum | cut -d' ' -f1)
		echo "$w $h $got" >> "$mine"
		if [ "$got" = "$want" ]; then
			ok=$((ok + 1))
		elif [ "$first" = - ]; then
			first=$n
		fi
		off=$(( off + len ))
		n=$((n + 1))
	done < "$ref"
	echo "$n $ok $first"
}

printf '%-6s %-12s %-5s %-9s %-6s %-7s %-6s %s\n' build stream rc frames err match first dmesg
for s in "${STREAMS[@]}"; do
	in=$ROOT/in/$s.ivf
	ref=$ROOT/ref/$s.frames
	[ -f "$in" ] || { echo "missing $in"; continue; }
	[ -f "$ref" ] || { echo "missing $ref"; continue; }
	rn=$(wc -l < "$ref")

	for b in $BUILDS; do
		bin=$ROOT/$b/bin/mpi_dec_test
		[ -x "$bin" ] || { echo "missing $bin"; continue; }
		raw=$OUT/$b-$s.nv12
		log=$OUT/$b-$s.log
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
		wrote=0; match="-"; first="-"
		if [ -s "$raw" ]; then
			read -r wrote ok first < <(compare "$raw" "$ref" "$OUT/$b-$s.md5")
			match="$ok/$rn"
		fi
		[ "${KEEP:-0}" = 1 ] || rm -f "$raw"

		printf '%-6s %-12s %-5s %-9s %-6s %-7s %-6s %s\n' "$b" "$s" "$rc" "$got/$wrote" "$errfrm/$errln" "$match" \
			"$first" "$(echo "$kl" | head -1)"
		echo "$kl" | tail -n +2 | sed 's/^/                                                          /'
	done
done
echo "frames = decode get frame lines / frames in the output file; err = flagged frames / error lines; logs and md5 lists in $OUT"
