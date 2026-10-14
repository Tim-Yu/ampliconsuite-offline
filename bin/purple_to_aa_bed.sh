#!/usr/bin/env bash
# Convert a PURPLE copy-number file (<sample>.purple.cnv.somatic.tsv, from oncoanalyser / hmftools) into the
# 5-column BED that AmpliconSuite-pipeline accepts via --cnv_bed:  chr  start  end  name  copy_number
#
# Note: PURPLE copy numbers are purity/ploidy-adjusted absolute tumour CN, whereas the default CNVkit seeds
# are not purity-corrected. With low-purity samples PURPLE-based seeding therefore finds amplicons that
# CNVkit-based seeding would miss; the AA seed threshold (--cngain, default 4.5) is applied to this column.
set -euo pipefail
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: purple_to_aa_bed.sh <sample>.purple.cnv.somatic.tsv [out.bed]" >&2; exit 1; }
in="$1"; out="${2:-${1%.tsv}_AA_CNV.bed}"
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next}
  { s=$h["start"]-1; if(s<0)s=0; e=$h["end"]; cn=$h["copyNumber"];
    printf "%s\t%d\t%d\tsize=%d\t%.4f\n", $h["chromosome"], s, e, e-s, cn }' "$in" > "$out"
echo "$out ($(wc -l < "$out") segments)"
