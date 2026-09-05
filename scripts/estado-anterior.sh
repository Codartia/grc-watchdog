#!/usr/bin/env bash
# Le no historico do proprio workflow como terminou o job de sonda nos ciclos
# anteriores. E assim que o vigia lembra do passado sem guardar estado em lugar
# nenhum - sem arquivo, sem commit, sem cache (decisao D-7 da spec).
#
# Uso:   estado-anterior.sh <quantos>
# Saida: <quantos> linhas, do ciclo mais recente para o mais antigo: ok | falha
#
# Seam de teste: GH_CMD substitui o binario gh.
set -uo pipefail

QUANTOS="${1:-2}"
GH="${GH_CMD:-gh}"
REPO="${GITHUB_REPOSITORY:-Codartia/grc-watchdog}"
WORKFLOW="${VIGIA_WORKFLOW:-vigia.yml}"
JOB="${VIGIA_JOB:-sonda}"

# --status completed exclui a execucao corrente, que ainda esta in_progress.
ids="$("$GH" run list --repo "$REPO" --workflow "$WORKFLOW" \
        --status completed --limit "$QUANTOS" \
        --json databaseId --jq '.[].databaseId' 2>/dev/null || true)"

vistos=0
while read -r id; do
  [ -n "$id" ] || continue
  conclusao="$("$GH" api "repos/${REPO}/actions/runs/${id}/jobs" \
                --jq ".jobs[] | select(.name==\"${JOB}\") | .conclusion" 2>/dev/null || true)"
  case "$conclusao" in
    success) echo "ok" ;;
    failure) echo "falha" ;;
    # Cancelado, pulado ou desconhecido nao e evidencia de queda do Graces.
    # Na duvida, o vigia se cala: falso positivo custa mais que deteccao tardia.
    *)       echo "ok" ;;
  esac
  vistos=$((vistos + 1))
done <<< "$ids"

while [ "$vistos" -lt "$QUANTOS" ]; do
  echo "ok"
  vistos=$((vistos + 1))
done
