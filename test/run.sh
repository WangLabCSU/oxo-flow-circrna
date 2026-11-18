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
LINT_RC=0
"$OXO" lint circrna.oxoflow > /tmp/circrna-lint-$$.txt 2>&1 || LINT_RC=$?
echo "DEBUG oxo-flow lint exit code: ${LINT_RC}"
echo "DEBUG oxo-flow lint raw output begin"
cat "/tmp/circrna-lint-$$.txt"
echo "DEBUG oxo-flow lint raw output end"
LINT_RC=0
"$OXO" lint circrna.oxoflow > /tmp/circrna-lint-$$.txt 2>&1 || LINT_RC=$?
cat "/tmp/circrna-lint-$$.txt"
if [ "$LINT_RC" -ne 0 ]; then
  echo "lint: oxo-flow lint reported errors (engine exit code $LINT_RC) - failing"
  exit 1
fi
# Engine summary wording changed after 0.20.1: "N error(s)" became
# "Summary: N errors, ..." (seen under 0.30.1). Parse the count from either
# form instead of matching a literal phrase; fail closed when no
# machine-readable count is present at all.
LINT_ERRCOUNT=$(grep -m1 -oE "[0-9]+ error\(s\)|[0-9]+ errors?" "/tmp/circrna-lint-$$.txt" | head -1 | grep -oE "[0-9]+" || true)
if [ -z "$LINT_ERRCOUNT" ]; then
  echo "lint: engine exit 0 but no parseable error count in summary - failing closed"
  exit 1
fi
if [ "$LINT_ERRCOUNT" -ne 0 ]; then
  echo "lint: $LINT_ERRCOUNT error(s) reported - failing"
  exit 1
fi
echo "lint: ok (engine exit $LINT_RC, summary error count $LINT_ERRCOUNT)"

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
