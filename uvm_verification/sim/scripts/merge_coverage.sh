#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause-Views
# merge_coverage.sh - merge per-run coverage into a single report.
# Implements : VERIFICATION_STRATEGY.md  §14.6, §16.3
# Introduced : Step 0
set -euo pipefail

TB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS="${TB_ROOT}/results"
OUT="${RESULTS}/coverage"
SIM="${MQNIC_SIM:-questa}"

mkdir -p "${OUT}"
mapfile -t DIRS < <(find "${RESULTS}" -type d -name cov | sort)

if [ "${#DIRS[@]}" -eq 0 ]; then
    echo "no coverage databases found under ${RESULTS}" >&2
    exit 1
fi
echo "merging ${#DIRS[@]} coverage database(s) with ${SIM}"

case "${SIM}" in
    vcs)
        urg -dir "${DIRS[@]}" -dbname "${OUT}/merged" -report "${OUT}/urgReport"
        ;;
    questa)
        vcover merge -out "${OUT}/merged.ucdb" "${DIRS[@]}"
        vcover report -html -htmldir "${OUT}/html" -details "${OUT}/merged.ucdb"
        ;;
    xcelium)
        imc -execcmd "merge ${DIRS[*]} -out ${OUT}/merged -overwrite; \
                      load -run ${OUT}/merged; report -html -out ${OUT}/html"
        ;;
    *)
        echo "unsupported MQNIC_SIM=${SIM}" >&2
        exit 2
        ;;
esac
echo "coverage report written to ${OUT}"
