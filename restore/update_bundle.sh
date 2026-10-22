#!/usr/bin/env bash
# update_bundle.sh - refresh the small files of an already restored bundle (bin/, hpc/, docs/, restore/, LICENSES/,
# upstream/, example data, manifests, README) from the bootstrap repo on GitHub, WITHOUT touching the large payload
# (sif/, data_repo/, r-src/) or your runs. Needs bash, wget (or curl), sha256sum.
#   wget https://github.com/Tim-Yu/ampliconsuite-offline/raw/refs/heads/main/restore/update_bundle.sh
#   bash update_bundle.sh --dest /path/to/restored/bundle [--owner Tim-Yu] [--repo ampliconsuite-offline] [--branch main] [--dry-run]
set -euo pipefail
OWNER="Tim-Yu"; REPO="ampliconsuite-offline"; BRANCH="main"; DEST=""; DRY=0; BASE_URL=""; RETRIES="${RETRIES:-5}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;; --owner) OWNER="$2"; shift 2 ;; --repo) REPO="$2"; shift 2 ;; --branch) BRANCH="$2"; shift 2 ;;
    --base-url) BASE_URL="${2%/}"; shift 2 ;; --retries) RETRIES="$2"; shift 2 ;; --dry-run) DRY=1; shift ;; -h|--help) sed -n '2,7p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ -n "$DEST" && -d "$DEST" ]] || { echo "ERROR: --dest must point to the restored bundle directory (holds env_controlled.sh)" >&2; exit 1; }
[[ -f "$DEST/env_controlled.sh" ]] || echo "WARNING: $DEST/env_controlled.sh not found; is this the restore destination?"
DEST="$(cd "$DEST" && pwd)"; BASE="${BASE_URL:-https://github.com/${OWNER}/${REPO}/raw/refs/heads/${BRANCH}}"
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || { echo "need wget or curl" >&2; exit 1; }
# get URL DEST: up to $RETRIES attempts with back-off (GitHub's raw endpoint answers HTTP 429 when a shared egress address
# is busy); on failure the last HTTP status is reported so 404 (wrong path) and 429 (rate limit) can be told apart.
get() {
  local url="$1" dest="$2" try=1 code=""
  while (( try <= RETRIES )); do
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" && return 0
      code="$(wget -S --spider "$url" 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -1 | awk '{print $2}')"
    else
      code="$(curl -sL -o "$dest" -w '%{http_code}' "$url" || true)"; [[ "$code" == "200" ]] && return 0
    fi
    rm -f "$dest"; (( try < RETRIES )) && { echo "  attempt $try/$RETRIES failed for $(basename "$dest") (HTTP ${code:-none}); retrying in $((try * 15)) s" >&2; sleep $((try * 15)); }
    try=$((try + 1))
  done
  echo "  giving up on $url (last HTTP status: ${code:-none}; 429 = GitHub rate limit, wait and rerun; 404 = file not on GitHub)" >&2; return 1
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
get "$BASE/FILES.txt" "$TMP/FILES.txt" || { echo "ERROR: cannot fetch $BASE/FILES.txt (see the status above)" >&2; exit 1; }
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
