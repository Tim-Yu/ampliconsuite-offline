#!/usr/bin/env bash
# update_bundle.sh - refresh the small files of an already restored bundle (bin/, hpc/, docs/, restore/, LICENSES/,
# upstream/, example data, manifests, README) from the bootstrap repo on GitHub, WITHOUT touching the large payload
# (sif/, data_repo/, r-src/) or your runs. Needs bash, wget (or curl), sha256sum.
#   wget https://github.com/Tim-Yu/ampliconsuite-offline/raw/refs/heads/main/restore/update_bundle.sh
#   bash update_bundle.sh --dest /path/to/restored/bundle [--owner Tim-Yu] [--repo ampliconsuite-offline] [--branch main] [--dry-run]
set -euo pipefail
OWNER="Tim-Yu"; REPO="ampliconsuite-offline"; BRANCH="main"; DEST=""; DRY=0; BASE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;; --owner) OWNER="$2"; shift 2 ;; --repo) REPO="$2"; shift 2 ;; --branch) BRANCH="$2"; shift 2 ;;
    --base-url) BASE_URL="${2%/}"; shift 2 ;; --dry-run) DRY=1; shift ;; -h|--help) sed -n '2,7p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ -n "$DEST" && -d "$DEST" ]] || { echo "ERROR: --dest must point to the restored bundle directory (holds env_controlled.sh)" >&2; exit 1; }
[[ -f "$DEST/env_controlled.sh" ]] || echo "WARNING: $DEST/env_controlled.sh not found; is this the restore destination?"
DEST="$(cd "$DEST" && pwd)"; BASE="${BASE_URL:-https://github.com/${OWNER}/${REPO}/raw/refs/heads/${BRANCH}}"
if command -v wget >/dev/null 2>&1; then get() { wget -q -O "$2" "$1"; }; elif command -v curl >/dev/null 2>&1; then get() { curl -fsSL -o "$2" "$1"; }; else echo "need wget or curl" >&2; exit 1; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
get "$BASE/FILES.txt" "$TMP/FILES.txt" || { echo "ERROR: cannot fetch $BASE/FILES.txt" >&2; exit 1; }
echo "update $DEST from $BASE ($(grep -c . "$TMP/FILES.txt") files listed)"
added=0; updated=0; same=0; failed=0
while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  case "$rel" in sif/*|data_repo/*|r-src/*|runs/*) continue ;; esac
  mkdir -p "$TMP/$(dirname "$rel")"
  if ! get "$BASE/$rel" "$TMP/$rel"; then echo "  FAILED  $rel"; failed=$((failed+1)); continue; fi
  if [[ -f "$DEST/$rel" ]] && [[ "$(sha256sum "$TMP/$rel" | cut -d' ' -f1)" == "$(sha256sum "$DEST/$rel" | cut -d' ' -f1)" ]]; then same=$((same+1)); continue; fi
  if [[ -f "$DEST/$rel" ]]; then echo "  updated $rel"; updated=$((updated+1)); else echo "  added   $rel"; added=$((added+1)); fi
  if [[ $DRY -eq 0 ]]; then mkdir -p "$DEST/$(dirname "$rel")"; cp -f "$TMP/$rel" "$DEST/$rel"; fi
done < "$TMP/FILES.txt"
[[ $DRY -eq 0 ]] && chmod +x "$DEST"/bin/*.sh "$DEST"/bin/*.R "$DEST"/hpc/*.lsf "$DEST"/hpc/*.sh "$DEST"/restore/*.sh 2>/dev/null || true
echo "done: $added added, $updated updated, $same unchanged, $failed failed$([[ $DRY -eq 1 ]] && echo ' (dry run, nothing written)')"
[[ -f "$DEST/docs/VERSIONS.txt" ]] && echo "bundle version: $(head -1 "$DEST/docs/VERSIONS.txt")"
[[ $failed -eq 0 ]]
