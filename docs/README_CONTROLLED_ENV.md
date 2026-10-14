# AmpliconSuite-pipeline 1.6.1, offline bundle

Detect ecDNA and other focal amplifications (ring/linear/BFB/complex) from short-read WGS with
[AmpliconSuite-pipeline](https://github.com/AmpliconSuite/AmpliconSuite-pipeline) (AmpliconArchitect 1.6.r1 +
AmpliconClassifier 2.0.0), packaged so that a controlled environment with GitHub-only access can install and run it
without any other network access. Everything runs inside one Singularity image; the host needs only bash, wget,
sha256sum, tar and Singularity/Apptainer (3.6+ / 1.0+; tested with 3.8.4 and targeted at 4.1.1).

## What you get after `download_and_restore.sh`
```
<dest>/
├── sif/ampliconsuite-pipeline_1.6.1.sif     container (bwa, samtools 1.21, bedtools, CNVkit 0.9.13, R+DNAcopy, AA, AC, BFBArchitect, solvers)
├── data_repo/GRCh38/                        AmpliconArchitect reference data repo (+ BWA index if restored with --with-indexed)
├── bin/run_ampsuite.sh                      launcher (bash only; same binds/arguments as the upstream python launcher)
├── bin/prepare_cram_cache.sh                CRAM support: build an offline htslib reference cache from a local FASTA
├── bin/purple_to_aa_bed.sh                  optional: PURPLE copy-number -> AA seed BED (skip CNVkit)
├── hpc/                                     LSF templates (single sample, job array, restore only)
├── upstream/AmpliconSuite-pipeline-v1.6.1/  vendored upstream source, docs and test outputs (pinned tag)
├── LICENSES/                                licences of all redistributed components
├── docs/VERSIONS.txt                        exact versions, digests and checksums of this bundle
└── env_controlled.sh                        exports AMPSUITE_SIF, AA_DATA_REPO, PATH
```

## Install (controlled environment)
```bash
mkdir -p /re_gecip/cancer_sarcoma/<project> && cd /re_gecip/cancer_sarcoma/<project>
wget https://github.com/Tim-Yu/ampliconsuite-offline/raw/refs/heads/main/restore/download_and_restore.sh
bash download_and_restore.sh --dest $PWD/ampliconsuite            # ~2.5 GB download, BAM/CRAM input
# bash download_and_restore.sh --dest $PWD/ampliconsuite --with-indexed   # +4.6 GB, only if you start from FASTQ
```
The script downloads 49 MiB parts from raw branch URLs, verifies every part and every reassembled file by SHA-256,
extracts, validates the image (if singularity is loadable) and writes `env_controlled.sh`. It is resumable.
On a login node without singularity add `--skip-sif-check`, or run it as a job: `hpc/restore_only.lsf`.

Smoke test (10 s, no BAM needed, classification of the upstream GBM39 example):
```bash
source ampliconsuite/env_controlled.sh
mkdir -p $AMPSUITE_ROOT/smoke_test && tar -xzf $AMPSUITE_ROOT/upstream/AmpliconSuite-pipeline-v1.6.1/test_outputs/GBM39_FF-8.tar.gz -C $AMPSUITE_ROOT/smoke_test
run_ampsuite.sh -s smoke -t 2 --ref GRCh38 --run_AC --completed_AA_runs $AMPSUITE_ROOT/smoke_test/GBM39_FF-8/GRCh38 -o $AMPSUITE_ROOT/smoke_test/out
cut -f2,4,7,8 $AMPSUITE_ROOT/smoke_test/out/smoke_classification/smoke_result_table.tsv   # expect 3 rows: Linear, ecDNA (EGFR), Linear
```

## Run
```bash
source /path/ampliconsuite/env_controlled.sh
run_ampsuite.sh -s SAMPLE -t 16 --bam /path/SAMPLE-T.redux.bam --normal_bam /path/SAMPLE-N.redux.bam \
   --ref GRCh38 --run_AA --run_AC -o /path/out/SAMPLE
```
- Input: coordinate-sorted, indexed BAM (or CRAM, see below) aligned to GRCh38 with `chr` names. GRCh38 builds with
  decoy/HLA/alt contigs (e.g. the hmftools/oncoanalyser reference) are accepted; AA matches on chr1-22 lengths and only
  warns about alt contigs.
- `--normal_bam` is optional and improves CNVkit segmentation; purity/ploidy can be passed with `--purity 0.6 --ploidy 2`.
- Defaults chosen by the launcher: `--AA_solver clarabel` (unless a Mosek licence is found), `--no_cstats` (data repo
  mounted read-only, safe for parallel jobs). Any other upstream option is passed through unchanged
  (`--cngain 4.5 --cnsize_min 50000 --downsample 10 --no_QC --AA_insert_sdevs 3.0 --pair_support_min 2 ...`).
- Outputs in `-o`: `SAMPLE_AA_results/` (graph/cycles/pdf per amplicon), `SAMPLE_classification/SAMPLE_result_table.tsv`
  (one row per amplicon with ecDNA / BFB / Linear / Complex-non-cyclic / unknown class, genes, copy number), CNVkit files,
  `SAMPLE_timing_log.txt`, `AS-p_stdout.log`.
- Expect roughly 1-3 h per 100x WGS tumour on 16 threads; runtime is dominated by reading the BAM (QC + CNVkit) and by
  the number of amplicons.

LSF: `hpc/submit_ampsuite_hpc.lsf` (one sample via `bsub -env`) and `hpc/submit_ampsuite_array.lsf` (job array over a
`samples.tsv`). Both `module load singularity/4.1.1`, source `env_controlled.sh` and call `run_ampsuite.sh`.

### Using PURPLE copy number as seeds (optional)
If oncoanalyser/PURPLE output exists, you can skip CNVkit and seed AA from PURPLE's purity-corrected copy number:
```bash
purple_to_aa_bed.sh /path/SAMPLE-T.purple.cnv.somatic.tsv /path/SAMPLE-T_AA_CNV.bed
run_ampsuite.sh -s SAMPLE -t 16 --bam /path/SAMPLE-T.redux.bam --cnv_bed /path/SAMPLE-T_AA_CNV.bed --ref GRCh38 --run_AA --run_AC -o /path/out
```
Note that PURPLE CN is purity-adjusted while CNVkit's is not, so low-purity samples seed more aggressively this way.

### CRAM input
See the add-on repository `ampliconsuite-offline-cram-addon`. In short: build the reference cache once from the local
FASTA the CRAMs were aligned to (`prepare_cram_cache.sh --fasta ... --cache $AMPSUITE_ROOT/cram_ref_cache`), export
`REF_CACHE="$AMPSUITE_ROOT/cram_ref_cache/%2s/%2s/%s"`, then pass the `.cram` to `--bam` as usual.

## Licences (research use)
See `LICENSES/README.md`. AmpliconSuite-pipeline, AmpliconClassifier (BSD-2) and BFBArchitect (BSD-3) are permissive.
AmpliconArchitect is under the University of California research licence (research, educational and non-profit use
permitted without fee; commercial use needs UCSD permission). No solver licence is required: AA uses the open-source
Clarabel solver and BFBArchitect uses CBC when no licence is present; upstream reports results nearly identical to Mosek.

### Optional: Mosek personal academic licence
Mosek licence checking is file-based and works offline: the licence is a small text file (`mosek.lic`, ~1 KB) carrying
an expiry date, no licence server and no internet call-back. If you want AA to use Mosek:
1. Request a *Personal Academic License* at https://www.mosek.com/products/academic-licenses/ with your university
   e-mail (individual, research/education only, valid 365 days, renewable). The file is e-mailed to you.
2. Put it at `$HOME/mosek/mosek.lic` on the machine running the jobs (or any directory, then
   `export MOSEKLM_LICENSE_FILE=/that/dir` in `env_controlled.sh`). Copy-paste the file content into the controlled
   environment through its approved route; never commit it to GitHub.
3. `run_ampsuite.sh` detects the file, mounts it read-only at `/home/mosek/` and switches the default solver to `mosek`
   (override with `--AA_solver clarabel`). If the licence is older than 365 days AA warns and falls back to Clarabel.
Gurobi (optional BFBArchitect accelerator for 50+ sample cohorts) is host-locked and impractical here; CBC is used.

## Network behaviour
The pipeline makes no network connection when run through this bundle: the data-repo freshness check is disabled
(`AS_NO_REPO_CHECK=1`), the data repo is pre-installed, `--upload` is never set, and CRAM references come from the local
cache. This was verified by running the BAM and CRAM paths inside a network-less namespace.

## Reproducibility
`docs/VERSIONS.txt` records the upstream tag and commit, the Docker image tag and digest the SIF was converted from,
SHA-256 of the SIF, and the md5 of the data repo tarballs (identical to the upstream `*_md5sum.txt`).
