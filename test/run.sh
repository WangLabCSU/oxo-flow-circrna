#!/usr/bin/env bash
# Acceptance test: validate + lint + dry-run with synthetic fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
OXO=${OXO:-oxo-flow}

mkdir -p raw
cp test/fixtures/raw/*.fastq.gz raw/
trap 'rm -rf raw .oxo-flow' EXIT

echo "==> validate"
"$OXO" validate circrna.oxoflow

echo "==> lint (errors fail, warnings ok)"
"$OXO" lint circrna.oxoflow > /tmp/circrna-lint-$$.txt 2>&1 || true
grep -q "0 error(s)" /tmp/circrna-lint-$$.txt || { echo "lint found errors"; exit 1; }

echo "==> dry-run (samples from fixtures; missing external references are warnings, not errors)"
# Engine headline wording changed in oxo-flow 0.20.1 (Traitome/oxo-flow#432):
# the old "DAG: (dry-run) N rules would execute" became
# "Plan: would run: N | skip: M | completed: K". Accept either so CI passes
# with both the latest release and older pins.
"$OXO" dry-run circrna.oxoflow > /tmp/circrna-dryrun-$$.txt 2>&1
grep -qE "would (execute|run)" /tmp/circrna-dryrun-$$.txt

echo "==> debug: expanded commands contain no literal {wildcards}"
"$OXO" debug circrna.oxoflow 2>&1 | grep -q '{sample}' && { echo "unexpanded wildcards"; exit 1; } || true

echo "PASS"
