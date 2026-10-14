#!/usr/bin/env bash
# run_ampsuite.sh - bash-only launcher for AmpliconSuite-pipeline inside the Singularity image.
#
# Mirrors upstream singularity/run_paa_singularity.py (same bind layout, same argument names) but needs
# only bash + singularity on the host, so it works where no host python is available. Works with the
# SIF built from the upstream Docker image (docker://jluebeck/ampliconsuite-pipeline:<tag>).
#
# Minimal examples:
#   run_ampsuite.sh -s SAMPLE -t 16 --bam /path/tumour.bam --ref GRCh38 --run_AA --run_AC -o /path/out
#   run_ampsuite.sh -s SAMPLE -t 16 --fastqs R1.fq.gz R2.fq.gz --ref GRCh38 --run_AA --run_AC -o /path/out
#   run_ampsuite.sh -s SET  -t 1  --completed_AA_runs /path/aa_outputs --ref GRCh38 --run_AC -o /path/out
#
# Any option not listed in --help is passed through verbatim to AmpliconSuite-pipeline.py
# (e.g. --cngain 4.5 --cnsize_min 50000 --downsample 10 --no_QC --AA_insert_sdevs 3.0 --purity 0.6 --ploidy 2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Container-side constants (layout of the upstream image)
C_PIPELINE="/home/programs/AmpliconSuite-pipeline-master/AmpliconSuite-pipeline.py"
C_AA_SRC="/home/programs/AmpliconArchitect-master/src"
C_AC_SRC="/home/programs/AmpliconClassifier-main"
C_CNVKIT="/home/programs/cnvkit.py"

usage() {
  cat <<USAGE
Usage: run_ampsuite.sh -s NAME -t THREADS (--bam FILE | --fastqs R1 R2 | --completed_AA_runs PATH) [options]

Required
  -s, --sample_name NAME        sample name
  -t, --nthreads N              threads for bwa / CNVkit (default: 8)
  --bam FILE | --sorted_bam     coordinate-sorted BAM or CRAM (aligned to an AA-supported reference)
  --fastqs R1 R2                paired FASTQs (needs the *_indexed data repo; --ref required)
  --completed_AA_runs PATH      directory (or single file) of finished AA outputs, for classification only

Common options
  -o, --output_directory DIR    output directory (default: current directory)
  --ref NAME                    hg19|GRCh37|GRCh38|hg38|mm10|GRCm38|GRCh38_viral (required for fastqs / completed runs)
  --run_AA                      run AmpliconArchitect
  --run_AC                      run AmpliconClassifier (needs --run_AA or --completed_AA_runs)
  --normal_bam FILE             matched normal for CNVkit
  --cnv_bed FILE | --bed FILE   your own CNV calls (BED: chr start end name CN) or CNVkit .cns; skips CNVkit
  --sv_vcf FILE                 external SV VCF to augment AA breakpoints
  --AA_solver mosek|clarabel    default: mosek if a licence is found, otherwise clarabel
  --cstats                      read/write \$AA_DATA_REPO/coverage.stats (default: --no_cstats, data repo mounted read-only)

Environment / container options
  --sif FILE                    Singularity image (default: \$AMPSUITE_SIF or ${INSTALL_ROOT}/sif/*.sif)
  --data_repo DIR               AA data repo (default: \$AA_DATA_REPO)
  --mosek_dir DIR               directory holding mosek.lic (default: \$MOSEKLM_LICENSE_FILE or \$HOME/mosek)
  --gurobi_lic FILE             gurobi.lic (default: \$GRB_LICENSE_FILE or \$HOME/gurobi.lic)
  --ref_cache TEMPLATE          htslib REF_CACHE template for CRAM input (default: \$REF_CACHE or \$HOME/.cache/hts-ref/%2s/%2s/%s)
  --bind HOST[:CONT[:ro]]       extra singularity bind (repeatable)
  --dry_run                     print the singularity command and exit
  -h, --help

Everything else is passed through to AmpliconSuite-pipeline.py unchanged.
USAGE
}

SIF="${AMPSUITE_SIF:-}"
DATA_REPO="${AA_DATA_REPO:-}"
MOSEK_DIR="${MOSEKLM_LICENSE_FILE:-$HOME/mosek}"
GRB_LIC="${GRB_LICENSE_FILE:-$HOME/gurobi.lic}"
REF_CACHE_TPL="${REF_CACHE:-$HOME/.cache/hts-ref/%2s/%2s/%s}"
OUTDIR="$PWD"; SNAME=""; NTHREADS="8"
BAM=""; FQ1=""; FQ2=""; COMPLETED=""; REF=""; NORMAL=""; CNV_BED=""; SV_VCF=""
RUN_AA=0; RUN_AC=0; SOLVER=""; CSTATS=0; DRY=0
EXTRA=(); EXTRA_BINDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--sample_name) SNAME="$2"; shift 2 ;;
    -t|--nthreads) NTHREADS="$2"; shift 2 ;;
    -o|--output_directory) OUTDIR="$2"; shift 2 ;;
    --bam|--sorted_bam) BAM="$2"; shift 2 ;;
    --fastqs) FQ1="$2"; FQ2="$3"; shift 3 ;;
    --completed_AA_runs) COMPLETED="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --normal_bam) NORMAL="$2"; shift 2 ;;
    --cnv_bed|--bed) CNV_BED="$2"; shift 2 ;;
    --sv_vcf) SV_VCF="$2"; shift 2 ;;
    --run_AA) RUN_AA=1; shift ;;
    --run_AC) RUN_AC=1; shift ;;
    --AA_solver) SOLVER="$2"; shift 2 ;;
    --cstats) CSTATS=1; shift ;;
    --no_cstats) CSTATS=0; shift ;;
    --sif) SIF="$2"; shift 2 ;;
    --data_repo) DATA_REPO="$2"; shift 2 ;;
    --mosek_dir) MOSEK_DIR="$2"; shift 2 ;;
    --gurobi_lic) GRB_LIC="$2"; shift 2 ;;
    --ref_cache) REF_CACHE_TPL="$2"; shift 2 ;;
    --bind) EXTRA_BINDS+=("$2"); shift 2 ;;
    --dry_run|--dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- resolve image / data repo -------------------------------------------------------------
if [[ -z "$SIF" ]]; then
  SIF="$(ls -1 "$INSTALL_ROOT"/sif/*.sif 2>/dev/null | head -1 || true)"
fi
[[ -n "$SIF" && -f "$SIF" ]] || die "Singularity image not found. Use --sif FILE or set AMPSUITE_SIF."
SIF="$(realpath "$SIF")"
[[ -n "$DATA_REPO" ]] || die "AA data repo not set. Use --data_repo DIR or set AA_DATA_REPO."
[[ -d "$DATA_REPO" ]] || die "AA data repo directory not found: $DATA_REPO"
DATA_REPO="$(realpath "$DATA_REPO")"
command -v singularity >/dev/null 2>&1 || die "singularity not on PATH (on the HPC: module load singularity)"

# ---- validate inputs -----------------------------------------------------------------------
[[ -n "$SNAME" ]] || die "-s/--sample_name is required"
n_inputs=0; [[ -n "$BAM" ]] && n_inputs=$((n_inputs+1)); [[ -n "$FQ1" ]] && n_inputs=$((n_inputs+1)); [[ -n "$COMPLETED" ]] && n_inputs=$((n_inputs+1))
[[ $n_inputs -eq 1 ]] || die "exactly one of --bam, --fastqs, --completed_AA_runs is required"
case "$REF" in hg38) REF="GRCh38" ;; GRCm38) REF="mm10" ;; esac
if [[ -n "$FQ1" || -n "$COMPLETED" ]]; then [[ -n "$REF" ]] || die "--ref is required with --fastqs / --completed_AA_runs"; fi
if [[ -n "$REF" ]]; then
  [[ -d "$DATA_REPO/$REF" ]] || die "data repo has no '$REF' directory: $DATA_REPO/$REF"
  if [[ -n "$FQ1" ]]; then
    ls "$DATA_REPO/$REF"/*.fa.bwt >/dev/null 2>&1 || ls "$DATA_REPO/$REF"/*.bwt >/dev/null 2>&1 || \
      die "--fastqs needs the BWA index (the *_indexed data repo); none found in $DATA_REPO/$REF"
  fi
fi
[[ "$NTHREADS" =~ ^[0-9]+$ ]] || die "-t must be an integer"
[[ "$SNAME" == *" "* ]] && die "sample name must not contain spaces"

mkdir -p "$OUTDIR"; OUTDIR="$(realpath "$OUTDIR")"
[[ "$OUTDIR" != "/" ]] || die "output directory must not be /"

# ---- assemble argstring and binds -----------------------------------------------------------
ARGS=(-t "$NTHREADS" -s "$SNAME" -o /home/output)
[[ -n "$REF" ]] && ARGS+=(--ref "$REF")
BINDS=("$DATA_REPO:/home/data_repo$([[ $CSTATS -eq 1 ]] || echo ':ro')" "$OUTDIR:/home/output")
HAS_CRAM=0

C_PATH=""
bind_file() { # $1 host file, $2 container dir, $3 ro|rw -> appends to BINDS and sets C_PATH (no subshell!)
  local f d b; f="$(realpath "$1")"; [[ -f "$f" ]] || die "file not found: $1"
  d="$(dirname "$f")"; b="$(basename "$f")"
  BINDS+=("$d:$2:$3"); C_PATH="$2/$b"
}

if [[ -n "$BAM" ]]; then
  bind_file "$BAM" /home/bam_dir ro; ARGS+=(--bam "$C_PATH")
  [[ "${BAM,,}" == *.cram ]] && HAS_CRAM=1
  # index must sit beside the alignment file
  bam_real="$(realpath "$BAM")"
  if [[ "${BAM,,}" == *.cram ]]; then idx_ok=$( [[ -f "$bam_real.crai" || -f "${bam_real%.cram}.crai" ]] && echo 1 || echo 0 )
  else idx_ok=$( [[ -f "$bam_real.bai" || -f "${bam_real%.bam}.bai" ]] && echo 1 || echo 0 ); fi
  [[ $idx_ok -eq 1 ]] || echo "WARNING: no index found next to $BAM; the pipeline will try to create one in the (read-only) input dir and may fail." >&2
elif [[ -n "$FQ1" ]]; then
  f1="$(realpath "$FQ1")"; f2="$(realpath "$FQ2")"
  [[ -f "$f1" && -f "$f2" ]] || die "fastq not found"
  [[ "$(dirname "$f1")" == "$(dirname "$f2")" ]] || die "both FASTQs must be in the same directory"
  BINDS+=("$(dirname "$f1"):/home/bam_dir:ro"); ARGS+=(--fastqs "/home/bam_dir/$(basename "$f1")" "/home/bam_dir/$(basename "$f2")")
else
  c_real="$(realpath "$COMPLETED")"
  if [[ -f "$c_real" ]]; then bind_file "$c_real" /home/bam_dir ro; ARGS+=(--completed_AA_runs "$C_PATH")
  elif [[ -d "$c_real" ]]; then BINDS+=("$c_real:/home/bam_dir"); ARGS+=(--completed_AA_runs /home/bam_dir/)   # rw like upstream: the pipeline removes stale *_classification dirs there
  else die "--completed_AA_runs path not found: $COMPLETED"; fi
  ARGS+=(--completed_run_metadata None)
fi

if [[ -n "$NORMAL" ]]; then
  bind_file "$NORMAL" /home/norm_bam_dir ro; ARGS+=(--normal_bam "$C_PATH")
  [[ "${NORMAL,,}" == *.cram ]] && HAS_CRAM=1
fi
if [[ -n "$CNV_BED" ]]; then
  bind_file "$CNV_BED" /home/bed_dir ro; ARGS+=(--cnv_bed "$C_PATH")
elif [[ -z "$COMPLETED" ]]; then
  ARGS+=(--cnvkit_dir "$C_CNVKIT")
fi
if [[ -n "$SV_VCF" ]]; then
  bind_file "$SV_VCF" /home/vcf_dir ro; ARGS+=(--sv_vcf "$C_PATH")
fi

# ---- optional licences ---------------------------------------------------------------------
MOSEK_FOUND=0
if [[ -n "$MOSEK_DIR" && -f "$MOSEK_DIR/mosek.lic" ]]; then
  BINDS+=("$(realpath "$MOSEK_DIR"):/home/mosek:ro"); MOSEK_FOUND=1
fi
GRB_ENV=""
if [[ -n "$GRB_LIC" && -f "$GRB_LIC" ]]; then
  BINDS+=("$(realpath "$GRB_LIC"):/home/gurobi/gurobi.lic:ro"); GRB_ENV="GRB_LICENSE_FILE=/home/gurobi/gurobi.lic"
fi
if [[ -z "$SOLVER" ]]; then
  if [[ $MOSEK_FOUND -eq 1 ]]; then SOLVER="mosek"; else SOLVER="clarabel"; fi
fi
ARGS+=(--AA_solver "$SOLVER")
[[ $RUN_AA -eq 1 ]] && ARGS+=(--run_AA)
[[ $RUN_AC -eq 1 ]] && ARGS+=(--run_AC)
[[ $CSTATS -eq 1 ]] || ARGS+=(--no_cstats)
ARGS+=("${EXTRA[@]}")

# ---- CRAM: mount the checksum-addressed reference cache -------------------------------------
CRAM_ENV=()
if [[ $HAS_CRAM -eq 1 ]]; then
  tpl="${REF_CACHE_TPL/#\~/$HOME}"
  [[ "$tpl" == *%* ]] || die "--ref_cache must be an htslib template containing %s, e.g. /path/hts-ref/%2s/%2s/%s"
  cache_root="$(dirname "${tpl%%\%*}")"
  rel_tpl="${tpl#"$cache_root"/}"
  [[ -d "$cache_root" ]] || die "CRAM reference cache not found: $cache_root (build it with prepare_cram_cache.sh)"
  BINDS+=("$(realpath "$cache_root"):/home/cram_cache:ro")
  CRAM_ENV=("REF_CACHE=/home/cram_cache/$rel_tpl" "REF_PATH=/home/cram_cache/$rel_tpl")
fi

for b in "${EXTRA_BINDS[@]}"; do BINDS+=("$b"); done

# ---- env-file for the container -------------------------------------------------------------
MPL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ampsuite_mpl.XXXXXX")"
ENV_FILE="$OUTDIR/.ampsuite_env_${SNAME}.txt"
{
  echo "argstring=\"${ARGS[*]}\""
  echo "SAMPLE_NAME=$SNAME"
  echo "AA_DATA_REPO=/home/data_repo"
  echo "AA_SRC=$C_AA_SRC"
  echo "AC_SRC=$C_AC_SRC"
  echo "MOSEKLM_LICENSE_FILE=/home/mosek/"
  echo "AS_NO_REPO_CHECK=1"
  echo "MPLCONFIGDIR=$MPL_DIR"
  echo "NUMBA_CACHE_DIR=$MPL_DIR"
  echo "XDG_CACHE_HOME=$MPL_DIR"
  [[ -n "$GRB_ENV" ]] && echo "$GRB_ENV"
  for e in "${CRAM_ENV[@]}"; do echo "$e"; done
} > "$ENV_FILE"

SING=(singularity exec --no-home --cleanenv --env-file "$ENV_FILE")
for b in "${BINDS[@]}"; do SING+=(--bind "$b"); done
# argstring is word-split on purpose (same as the upstream internal_singularity_script.sh); the pipeline rejects paths with spaces anyway.
SING+=("$SIF" bash -c 'cd /home/output && echo "[run_ampsuite] python3 '"$C_PIPELINE"' $argstring" && python3 '"$C_PIPELINE"' ${argstring} 2>&1 | tee -a /home/output/AS-p_stdout.log; exit "${PIPESTATUS[0]}"')

echo "[run_ampsuite] image      : $SIF"
echo "[run_ampsuite] data repo  : $DATA_REPO ($([[ $CSTATS -eq 1 ]] && echo rw || echo ro))"
echo "[run_ampsuite] output     : $OUTDIR"
echo "[run_ampsuite] solver     : $SOLVER (mosek.lic found: $MOSEK_FOUND)"
echo "[run_ampsuite] args       : ${ARGS[*]}"
if [[ $DRY -eq 1 ]]; then
  printf '%q ' "${SING[@]}"; echo; cat "$ENV_FILE"; rm -rf "$MPL_DIR"; exit 0
fi
set +e
"${SING[@]}"
rc=$?
set -e
rm -rf "$MPL_DIR"
if [[ $rc -ne 0 ]]; then echo "[run_ampsuite] FAILED (exit $rc). See $OUTDIR/AS-p_stdout.log" >&2; exit $rc; fi
echo "[run_ampsuite] finished OK: $OUTDIR"
