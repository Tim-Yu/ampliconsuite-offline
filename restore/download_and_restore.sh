#!/usr/bin/env bash
# download_and_restore.sh - restore the offline AmpliconSuite-pipeline bundle from GitHub raw-branch files.
#
# Needs only: bash, wget (or curl), sha256sum, tar, awk, sort. No git, no python, no release assets.
# Every payload file is < 50 MiB and is fetched from
#   https://github.com/<owner>/<repo>/raw/refs/heads/<branch>/<package-path>/<file>
# Resumable: already-downloaded, checksum-verified parts are skipped on re-run.
#
# Usage (controlled environment):
#   wget https://github.com/Tim-Yu/ampliconsuite-offline/raw/refs/heads/main/restore/download_and_restore.sh
#   bash download_and_restore.sh --dest /re_gecip/cancer_sarcoma/<project>/ampliconsuite [--with-indexed]
#
# Result layout under --dest:
#   sif/ampliconsuite-pipeline_1.6.1.sif   data_repo/GRCh38/   bin/   hpc/   upstream/   LICENSES/   docs/
#   env_controlled.sh  (source it, then: run_ampsuite.sh ...)
set -euo pipefail

OWNER="Tim-Yu"
REPO="ampliconsuite-offline-parts"
BRANCH="payload-v1.6.1"
PACKAGE_PATH="packages/ampliconsuite/v1.6.1"
INDEXED_PATH="packages/ampliconsuite/v1.6.1-indexed"
DEST_DIR="./ampliconsuite"
WORK_DIR=""
WITH_INDEXED=0
KEEP_PARTS=0
SKIP_SIF_CHECK=0
RETRIES=5
BASE_URL=""
CALLER_PWD="$(pwd)"

usage() {
  cat <<USAGE
Usage: bash download_and_restore.sh [options]
  --dest DIR            restore destination (default: $DEST_DIR)
  --with-indexed        also fetch the BWA-indexed GRCh38 data repo (+4.6 GB; only needed for FASTQ input)
  --owner NAME          GitHub owner (default: $OWNER)
  --repo NAME           parts repository (default: $REPO)
  --branch NAME         payload branch (default: $BRANCH)
  --package-path PATH   base payload path (default: $PACKAGE_PATH)
  --indexed-path PATH   indexed payload path (default: $INDEXED_PATH)
  --work-dir DIR        download/work directory (default: DEST/restore_work)
  --keep-parts          keep downloaded parts and reassembled archives after a successful restore
  --skip-sif-check      do not try to run the image for validation (e.g. no singularity on the login node)
  --retries N           download retries per file (default: $RETRIES)
  --base-url URL        override the raw base (default https://github.com/OWNER/REPO/raw/refs/heads/BRANCH); package paths are appended
  -h, --help
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST_DIR="$2"; shift 2 ;;
    --with-indexed) WITH_INDEXED=1; shift ;;
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --package-path) PACKAGE_PATH="$2"; shift 2 ;;
    --indexed-path) INDEXED_PATH="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --keep-parts) KEEP_PARTS=1; shift ;;
    --skip-sif-check) SKIP_SIF_CHECK=1; shift ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --base-url) BASE_URL="${2%/}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$DEST_DIR" == /* ]] || DEST_DIR="$CALLER_PWD/$DEST_DIR"
mkdir -p "$DEST_DIR"; DEST_DIR="$(cd "$DEST_DIR" && pwd)"
[[ -n "$WORK_DIR" ]] || WORK_DIR="$DEST_DIR/restore_work"
[[ "$WORK_DIR" == /* ]] || WORK_DIR="$CALLER_PWD/$WORK_DIR"
mkdir -p "$WORK_DIR"; WORK_DIR="$(cd "$WORK_DIR" && pwd)"
LOG="$WORK_DIR/restore.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

for cmd in sha256sum tar awk sort cat; do command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"; done
if command -v wget >/dev/null 2>&1; then DL="wget"; elif command -v curl >/dev/null 2>&1; then DL="curl"; else die "need wget or curl"; fi

fetch() { # url dest
  local url="$1" dest="$2" try=1
  while (( try <= RETRIES )); do
    if [[ "$DL" == wget ]]; then
      wget -q -c -O "$dest.part" "$url" && mv -f "$dest.part" "$dest" && return 0
    else
      curl -fsSL --retry 3 -C - -o "$dest.part" "$url" && mv -f "$dest.part" "$dest" && return 0
    fi
    log "  retry $try/$RETRIES for $(basename "$dest")"; sleep $((try * 3)); try=$((try + 1))
  done
  return 1
}
sha_ok() { [[ "$(sha256sum "$1" | awk '{print $1}')" == "$2" ]]; }

restore_package() { # package_path  skip_types(regex or empty)
  local pkg="$1" skip_re="${2:-}"
  local base="${BASE_URL:-https://github.com/${OWNER}/${REPO}/raw/refs/heads/${BRANCH}}/${pkg}"
  local pdir="$WORK_DIR/$(basename "$pkg")"; mkdir -p "$pdir"; cd "$pdir"
  log "== package $pkg"
  log "   raw base: $base"

  log "[1/4] metadata"
  for m in MANIFEST.tsv ARCHIVES.tsv REQUIRED_FILES.txt VERSIONS.txt; do
    fetch "$base/$m" "$m" || { [[ "$m" == "REQUIRED_FILES.txt" || "$m" == "VERSIONS.txt" ]] && continue; die "cannot download $m from $base"; }
  done

  log "[2/4] parts (resumable, sha256-verified)"
  local total skipped=0 fetched=0
  total="$(awk -F'\t' 'NR>1 && $1!=""' MANIFEST.tsv | wc -l)"
  while IFS=$'\t' read -r fname ftype fbytes fsha; do
    [[ -z "$fname" || "$fname" == "file" ]] && continue
    if [[ -n "$skip_re" && "$ftype" =~ $skip_re ]]; then continue; fi
    if [[ -f "$fname" && "$(stat -c %s "$fname")" == "$fbytes" && -f ".ok.$fname" ]]; then skipped=$((skipped+1)); continue; fi
    if [[ -f "$fname" && "$(stat -c %s "$fname")" == "$fbytes" ]] && sha_ok "$fname" "$fsha"; then touch ".ok.$fname"; skipped=$((skipped+1)); continue; fi
    rm -f "$fname" ".ok.$fname"
    fetch "$base/$fname" "$fname" || die "download failed: $fname"
    sha_ok "$fname" "$fsha" || { rm -f "$fname"; fetch "$base/$fname" "$fname" && sha_ok "$fname" "$fsha" || die "checksum mismatch after re-download: $fname"; }
    touch ".ok.$fname"; fetched=$((fetched+1))
    printf '\r   %d/%d files done' "$((skipped+fetched))" "$total"
  done < MANIFEST.tsv
  echo; log "   parts verified: $((skipped+fetched)) ($fetched downloaded, $skipped already present)"

  log "[3/4] reassemble + extract"
  # ARCHIVES.tsv: archive  type  bytes  sha256  nparts  part_prefix  extract_to
  while IFS=$'\t' read -r aname atype abytes asha anparts aprefix aextract; do
    [[ -z "$aname" || "$aname" == "archive" ]] && continue
    if [[ -n "$skip_re" && "$atype" =~ $skip_re ]]; then log "   skipping $aname ($atype)"; continue; fi
    log "   $aname <- $anparts parts"
    cat $(ls -1 "${aprefix}"* | LC_ALL=C sort) > "$aname"
    [[ "$(stat -c %s "$aname")" == "$abytes" ]] || die "reassembled size mismatch: $aname"
    sha_ok "$aname" "$asha" || die "reassembled checksum mismatch: $aname"
    case "$atype" in
      sif)
        mkdir -p "$DEST_DIR/sif"; cp -f "$aname" "$DEST_DIR/sif/$aname"; chmod a+rx "$DEST_DIR/sif/$aname"
        log "   installed $DEST_DIR/sif/$aname" ;;
      code)
        tar -xzf "$aname" -C "$DEST_DIR"; log "   extracted code payload into $DEST_DIR" ;;
      data_repo|data_repo_indexed)
        mkdir -p "$DEST_DIR/data_repo"; tar -xzf "$aname" -C "$DEST_DIR/data_repo"
        # md5 file (as published upstream) lets the pipeline report the data-repo version
        for md5f in *_md5sum.txt; do [[ -f "$md5f" ]] && cp -f "$md5f" "$DEST_DIR/data_repo/"; done
        touch "$DEST_DIR/data_repo/coverage.stats"; chmod a+rw "$DEST_DIR/data_repo/coverage.stats" || true
        log "   extracted data repo into $DEST_DIR/data_repo" ;;
      *) die "unknown archive type '$atype' for $aname" ;;
    esac
    [[ $KEEP_PARTS -eq 1 ]] || rm -f "$aname"
  done < ARCHIVES.tsv

  log "[4/4] required files"
  if [[ -f REQUIRED_FILES.txt ]]; then
    local missing=0
    while read -r rel; do
      [[ -z "$rel" || "$rel" == \#* ]] && continue
      if [[ -n "$skip_re" && "$rel" == data_repo/* && "$skip_re" == *data_repo* ]]; then continue; fi   # provided by the indexed package
      [[ -e "$DEST_DIR/$rel" ]] || { log "   MISSING: $DEST_DIR/$rel"; missing=1; }
    done < REQUIRED_FILES.txt
    [[ $missing -eq 0 ]] || die "restore incomplete for $pkg"
  fi
  [[ -f VERSIONS.txt ]] && { mkdir -p "$DEST_DIR/docs"; cp -f VERSIONS.txt "$DEST_DIR/docs/VERSIONS_$(basename "$pkg").txt"; }
  cd "$CALLER_PWD"
}

log "Restore AmpliconSuite offline bundle"
log "  dest: $DEST_DIR"
log "  work: $WORK_DIR"
if [[ $WITH_INDEXED -eq 1 ]]; then
  restore_package "$PACKAGE_PATH" '^data_repo$'      # indexed repo is a superset: skip the plain one
  restore_package "$INDEXED_PATH" ''
else
  restore_package "$PACKAGE_PATH" ''
fi

# ---- environment helper --------------------------------------------------------------------------
SIF_PATH="$(ls -1 "$DEST_DIR"/sif/*.sif 2>/dev/null | head -1 || true)"
cat > "$DEST_DIR/env_controlled.sh" <<ENV
#!/usr/bin/env bash
# source this file before running AmpliconSuite in the controlled environment
export AMPSUITE_ROOT="$DEST_DIR"
export AMPSUITE_SIF="$SIF_PATH"
export AA_DATA_REPO="$DEST_DIR/data_repo"
export AS_NO_REPO_CHECK=1
export PATH="$DEST_DIR/bin:\$PATH"
# optional Mosek licence directory (contains mosek.lic); leave commented to use Clarabel
# export MOSEKLM_LICENSE_FILE="\$HOME/mosek"
# optional CRAM reference cache built with prepare_cram_cache.sh
# export REF_CACHE="$DEST_DIR/cram_ref_cache/%2s/%2s/%s"
ENV
chmod +x "$DEST_DIR"/bin/*.sh "$DEST_DIR/env_controlled.sh" 2>/dev/null || true

# ---- validation ----------------------------------------------------------------------------------
if [[ $SKIP_SIF_CHECK -eq 0 ]]; then
  if ! command -v singularity >/dev/null 2>&1; then
    if type module >/dev/null 2>&1 || [[ -f /etc/profile.d/modules.sh ]]; then
      [[ -f /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh || true
      module load singularity/4.1.1 >/dev/null 2>&1 || module load singularity >/dev/null 2>&1 || true
    fi
  fi
  if command -v singularity >/dev/null 2>&1 && [[ -n "$SIF_PATH" ]]; then
    log "validating image: $(singularity --version)"
    singularity exec --cleanenv --no-home --bind "$DEST_DIR/data_repo:/home/data_repo:ro" "$SIF_PATH" bash -c \
      'echo "  samtools: $(samtools --version | head -1)"; echo "  AA: $(python3 /home/programs/AmpliconArchitect-master/src/AmpliconArchitect.py -v 2>&1 | tail -1)"; echo "  AC: $(python3 /home/programs/AmpliconClassifier-main/amplicon_classifier.py -v 2>&1 | tail -1)"; echo "  data repo: $(ls /home/data_repo)"' | tee -a "$LOG" \
      || die "image validation failed"
  else
    log "singularity not available in this shell; skipped image validation (run on a compute node: module load singularity/4.1.1)"
  fi
fi

if [[ $KEEP_PARTS -eq 0 ]]; then
  find "$WORK_DIR" -maxdepth 2 -type f \( -name '*.part-*' -o -name '.ok.*' \) -delete
  log "downloaded parts removed (use --keep-parts to keep them)"
fi

log "Restore complete: $DEST_DIR"
cat <<NEXT

Next steps
  source $DEST_DIR/env_controlled.sh
  # smoke test (classification only, ~10 s, no BAM needed; expect 3 rows: Linear, ecDNA (EGFR), Linear):
  mkdir -p $DEST_DIR/smoke_test && tar -xzf $DEST_DIR/upstream/AmpliconSuite-pipeline-v1.6.1/test_outputs/GBM39_FF-8.tar.gz -C $DEST_DIR/smoke_test
  run_ampsuite.sh -s smoke -t 2 --ref GRCh38 --run_AC --completed_AA_runs $DEST_DIR/smoke_test/GBM39_FF-8/GRCh38 -o $DEST_DIR/smoke_test/out
  cut -f2,4,7,8 $DEST_DIR/smoke_test/out/smoke_classification/smoke_result_table.tsv
  # real sample:
  run_ampsuite.sh -s SAMPLE -t 16 --bam /path/tumour.bam [--normal_bam /path/normal.bam] --ref GRCh38 --run_AA --run_AC -o /path/out
  # LSF templates: $DEST_DIR/hpc/
NEXT
