#!/usr/bin/env bash
# sheet_lib.sh - parse the cohort sample sheet used in the GEL project:
#   header line with columns PatientID, TumourID, Tumour_BAM, Normal_BAM (any order; Normal_BAM optional;
#   optional extra column PurpleID when the PURPLE sample name differs from TumourID), tab- or comma-separated,
#   Windows line endings tolerated, '#' lines and blank lines ignored.
# sheet_rows FILE   -> one normalised TSV row per sample: TumourID  Tumour_BAM  Normal_BAM  PatientID  PurpleID
# sheet_row FILE N  -> the N-th sample row (1-based)
# sheet_count FILE  -> number of sample rows
# sheet_field ROW N -> N-th field of a row (empty fields preserved; do not use `read` with IFS=tab for that)
sheet_rows() {
  awk 'BEGIN { OFS="\t" }
    NR==1 {
      gsub(/\r/, ""); sep = ($0 ~ /\t/) ? "\t" : ","; n = split($0, h, sep)
      for (i = 1; i <= n; i++) { gsub(/^[ "]+|[ "]+$/, "", h[i]); idx[h[i]] = i }
      if (!("TumourID" in idx) || !("Tumour_BAM" in idx)) { print "ERROR: sheet header must contain TumourID and Tumour_BAM (found: " $0 ")" > "/dev/stderr"; exit 2 }
      next }
    { gsub(/\r/, ""); if ($0 ~ /^[ \t]*(#|$)/) next
      n = split($0, f, sep); for (i = 1; i <= n; i++) gsub(/^[ "]+|[ "]+$/, "", f[i])
      t = f[idx["TumourID"]]; if (t == "") next
      print t, f[idx["Tumour_BAM"]], ("Normal_BAM" in idx ? f[idx["Normal_BAM"]] : ""), ("PatientID" in idx ? f[idx["PatientID"]] : ""), ("PurpleID" in idx ? f[idx["PurpleID"]] : "") }' "$1"
}
sheet_row() { sheet_rows "$1" | sed -n "${2}p"; }
sheet_count() { sheet_rows "$1" | wc -l; }
sheet_field() { printf '%s\n' "$1" | cut -f"$2"; }
# lsf_env VAR... -> "all,VAR=value,..." for every named variable that is set and non-empty (LSF rejects empty
#                   assignments such as "EXTRA_ARGS=" with "invalid syntax for option -env"); values must not contain commas
lsf_env() { local s="all" v; for v in "$@"; do [[ -n "${!v:-}" ]] && s+=",$v=${!v}"; done; printf '%s' "$s"; }
# lsf_submit QUEUE WALLTIME ENVSTRING FILE [extra bsub args...] -> submits FILE (or prints the command when DRY_RUN=1)
lsf_submit() { local q="$1" w="$2" env="$3" file="$4"; shift 4
  echo "bsub -q $q -W $w $* -env \"$env\" < $file"
  [[ "${DRY_RUN:-0}" == "1" ]] && { echo "(DRY_RUN=1: not submitted)"; return 0; }
  bsub -q "$q" -W "$w" "$@" -env "$env" < "$file"; }
