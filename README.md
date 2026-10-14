# ampliconsuite-offline

Bootstrap repository for running **AmpliconSuite-pipeline 1.6.1** (AmpliconArchitect + AmpliconClassifier, ecDNA /
focal-amplification detection from short-read WGS) in a controlled environment whose only outbound access is GitHub.

Large payloads (Singularity image, GRCh38 data repo) live as < 50 MiB split parts in
[`ampliconsuite-offline-parts`](https://github.com/Tim-Yu/ampliconsuite-offline-parts) (branch `payload-v1.6.1`) and
are fetched with plain `wget` from raw branch URLs. CRAM support is in
[`ampliconsuite-offline-cram-addon`](https://github.com/Tim-Yu/ampliconsuite-offline-cram-addon).

## Quick start
```bash
wget https://github.com/Tim-Yu/ampliconsuite-offline/raw/refs/heads/main/restore/download_and_restore.sh
bash download_and_restore.sh --dest $PWD/ampliconsuite        # add --with-indexed for FASTQ input (+4.6 GB)
source ampliconsuite/env_controlled.sh
run_ampsuite.sh -s SAMPLE -t 16 --bam tumour.bam --ref GRCh38 --run_AA --run_AC -o out/SAMPLE
```
Full documentation: [`docs/README_CONTROLLED_ENV.md`](docs/README_CONTROLLED_ENV.md).

## Contents
| Path | Purpose |
|---|---|
| `restore/download_and_restore.sh` | bash-only downloader/verifier/extractor (resumable) |
| `bin/` | `run_ampsuite.sh` launcher, `prepare_cram_cache.sh`, `purple_to_aa_bed.sh` |
| `hpc/` | LSF templates (`submit_ampsuite_hpc.lsf`, `submit_ampsuite_array.lsf`, `restore_only.lsf`) |
| `manifests/<version>/` | MANIFEST.tsv, CHECKSUMS.sha256, ARCHIVES.tsv, ARCHIVES.sha256, REQUIRED_FILES.txt, VERSIONS.txt of each payload |
| `upstream/AmpliconSuite-pipeline-v1.6.1/` | vendored upstream source at the pinned tag (BSD-2), incl. `test_outputs/` for a smoke test |
| `LICENSES/` | licences of all redistributed components |
| `docs/` | controlled-environment guide and `VERSIONS.txt` |

## Payload (branch `payload-v1.6.1` of `ampliconsuite-offline-parts`)
| Path | Content | Size |
|---|---|---|
| `packages/ampliconsuite/v1.6.1/` | `code_payload.tar.gz`, `ampliconsuite-pipeline_1.6.1.sif`, `GRCh38.tar.gz` as `*.part-NNN` + manifests | ~1.9 GB |
| `packages/ampliconsuite/v1.6.1-indexed/` | `GRCh38_indexed.tar.gz` parts (BWA index, FASTQ input only) | ~4.6 GB |

## Licences
Research use. AmpliconSuite-pipeline and AmpliconClassifier are BSD-2-Clause, BFBArchitect BSD-3-Clause,
AmpliconArchitect is distributed under the University of California research licence (see `LICENSES/`). No solver
licence is required (Clarabel / CBC are used unless a Mosek licence file is supplied by the user).
