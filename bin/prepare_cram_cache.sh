#!/usr/bin/env bash
# prepare_cram_cache.sh - build an htslib checksum-addressed reference cache (REF_CACHE) from a LOCAL reference
# FASTA so CRAM files can be decoded fully offline (no ENA lookups), then optionally preflight CRAM files.
#
# Why: AmpliconSuite's launchers fetch missing CRAM reference sequences from ENA; the controlled environment
# cannot reach ENA. The FASTA that the CRAMs were aligned to is available locally there, so we populate the
# cache from it with samtools' seq_cache_populate.pl (shipped inside the image), one-off, ~3 GB for GRCh38.
#
# Usage:
#   prepare_cram_cache.sh --fasta /path/GRCh38.fasta [--cache DIR] [--sif FILE] [--cram FILE ...]
#   then: export REF_CACHE="DIR/%2s/%2s/%s"   (run_ampsuite.sh picks it up, or pass --ref_cache)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; INSTALL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIF="${AMPSUITE_SIF:-}"; FASTA=""; CACHE="$INSTALL_ROOT/cram_ref_cache"; CRAMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fasta) FASTA="$2"; shift 2 ;;
    --cache) CACHE="$2"; shift 2 ;;
    --sif) SIF="$2"; shift 2 ;;
    --cram) CRAMS+=("$2"); shift 2 ;;
    -h|--help) awk 'NR>1 { if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
die() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$SIF" ]] || SIF="$(ls -1 "$INSTALL_ROOT"/sif/*.sif 2>/dev/null | head -1 || true)"
[[ -f "$SIF" ]] || die "image not found; use --sif"
[[ -n "$FASTA" && -f "$FASTA" ]] || die "--fasta FILE is required (the reference the CRAMs were aligned to)"
FASTA="$(realpath "$FASTA")"; mkdir -p "$CACHE"; CACHE="$(realpath "$CACHE")"
echo "[prepare_cram_cache] fasta : $FASTA"
echo "[prepare_cram_cache] cache : $CACHE  (template: $CACHE/%2s/%2s/%s)"
# seq_cache_populate.pl writes <root>/<md5[0:2]>/<md5[2:4]>/<md5[4:]> for every sequence; existing entries are reused.
singularity exec --cleanenv --no-home --bind "$(dirname "$FASTA"):/ref:ro" --bind "$CACHE:/cache" "$SIF" \
  bash -c 'seq_cache_populate.pl -root /cache -subdirs 2 "/ref/'"$(basename "$FASTA")"'" | tail -n 3'
n="$(find "$CACHE" -type f | wc -l)"; sz="$(du -sh "$CACHE" | cut -f1)"
echo "[prepare_cram_cache] cache now holds $n sequences ($sz)"
# Optional preflight: verify each CRAM's header checksums resolve in the cache and one record decodes.
for c in "${CRAMS[@]}"; do
  c="$(realpath "$c")"; [[ -f "$c" ]] || die "CRAM not found: $c"
  echo "[prepare_cram_cache] preflight $c"
  singularity exec --cleanenv --no-home --bind "$CACHE:/cache:ro" --bind "$(dirname "$c"):/in:ro" \
    --env "REF_CACHE=/cache/%2s/%2s/%s" --env "REF_PATH=/cache/%2s/%2s/%s" \
    --pwd /home/programs/AmpliconSuite-pipeline-master "$SIF" \
    python3 -m paalib.cram_compat --use_ref_path "/in/$(basename "$c")"
done
echo "[prepare_cram_cache] done. Use:  export REF_CACHE=\"$CACHE/%2s/%2s/%s\""
