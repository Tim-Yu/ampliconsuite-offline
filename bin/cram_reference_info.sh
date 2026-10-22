#!/usr/bin/env bash
# cram_reference_info.sh - show which reference a CRAM was written against (header @SQ UR/M5 tags, contig count) and,
# if a cache directory is given, how many of its sequences are already in the cache.
#   cram_reference_info.sh /path/sample.cram [/path/cram_ref_cache]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SIF="${AMPSUITE_SIF:-$(ls -1 "$SCRIPT_DIR"/../sif/*.sif 2>/dev/null | head -1)}"
[[ -f "${1:-}" ]] || { echo "usage: cram_reference_info.sh /path/sample.cram [/path/cram_ref_cache]" >&2; exit 1; }
CRAM="$(realpath "$1")"; CACHE="${2:-}"
singularity exec --cleanenv --no-home --bind "$(dirname "$CRAM"):/in:ro" "$SIF" samtools view -H "/in/$(basename "$CRAM")" > /tmp/cram_hdr.$$ 2>/dev/null
echo "contigs in header: $(grep -c '^@SQ' /tmp/cram_hdr.$$)"
echo "reference path recorded in the header (UR tag):"; { grep '^@SQ' /tmp/cram_hdr.$$ | grep -o 'UR:[^[:space:]]*' | sort -u | head -3 | sed 's/^/  /'; } || true
n_m5="$(grep '^@SQ' /tmp/cram_hdr.$$ | grep -c 'M5:' || true)"
echo "contigs with an M5 (sequence MD5) tag: $n_m5"
{ grep '^@SQ' /tmp/cram_hdr.$$ | head -3 | sed 's/\t/ /g' | grep -o 'SN:[^ ]* LN:[^ ]*\( .*M5:[0-9a-f]*\)\?' | sed 's/^/  /'; } || true
if [[ -n "$CACHE" ]]; then
  if [[ "$n_m5" -eq 0 ]]; then echo "no M5 tags: the cache is looked up by sequence MD5 at run time (htslib computes it from REF_PATH); build the cache from the FASTA named above and run the preflight (build_cram_cache.lsf ... /path/one.cram)"
  else have=0; total=0
    while read -r m; do total=$((total+1)); [[ -f "$CACHE/${m:0:2}/${m:2:2}/${m:4}" ]] && have=$((have+1)); done < <(grep '^@SQ' /tmp/cram_hdr.$$ | grep -o 'M5:[0-9a-f]*' | cut -c4- || true)
    echo "cache $CACHE holds $have of $total header sequences$([[ $have -eq $total ]] && echo ' -> complete' || echo ' -> INCOMPLETE: build the cache from the FASTA named above')"
  fi
fi
rm -f /tmp/cram_hdr.$$
