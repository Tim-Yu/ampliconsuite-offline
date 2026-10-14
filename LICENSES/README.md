# Licences of the redistributed components

| Component | Version | Licence | File |
|---|---|---|---|
| AmpliconSuite-pipeline | 1.6.1 | BSD-2-Clause | LICENSE-AmpliconSuite-pipeline.txt |
| AmpliconArchitect | 1.6.r1 | University of California research licence (educational, research and non-profit use permitted without fee; commercial use requires permission from UCSD Office of Innovation and Commercialization) | LICENSE-AmpliconArchitect.txt |
| AmpliconClassifier | 2.0.0 | BSD-2-Clause | LICENSE-AmpliconClassifier.txt |
| BFBArchitect | 1.0.1 | BSD-3-Clause | LICENSE-BFBArchitect.txt |

The Singularity image (`ampliconsuite-pipeline_1.6.1.sif`) is converted unchanged from the upstream Docker image
`jluebeck/ampliconsuite-pipeline:1.6.1` and additionally contains open-source tools (bwa GPL-3, samtools/bedtools MIT,
CNVkit Apache-2, R + DNAcopy GPL, Clarabel Apache-2, CBC EPL) and the Mosek and Gurobi Python bindings. Mosek and Gurobi
are proprietary solvers; their bindings are redistributable but only run with a licence file. No licence file is
distributed here. Without one, AmpliconArchitect uses Clarabel and BFBArchitect uses CBC automatically.

This distribution is for research use only.
