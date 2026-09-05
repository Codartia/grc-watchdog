#!/usr/bin/env bash
# Roda a suite inteira num shell so, para os contadores acumularem.
# Uso: bash tests/run.sh
set -uo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/harness.sh
. tests/harness.sh

for arquivo in tests/test-*.sh; do
  echo
  echo "== ${arquivo}"
  # shellcheck source=/dev/null
  . "$arquivo"
done

resumo
