#!/usr/bin/env bash
# Le no historico do proprio workflow como terminou o job de sonda nos ciclos
# anteriores. E assim que o vigia lembra do passado sem guardar estado em lugar
# nenhum - sem arquivo, sem commit, sem cache (decisao D-7 da spec).
#
# Uso:   estado-anterior.sh <quantos>
# Saida: <quantos> linhas, do ciclo mais recente para o mais antigo: ok | falha
#
# Codigos de saida:
#   0 - historico lido (mesmo que vazio: repo recem-criado e um caso legitimo,
#       e ai as amostras ausentes valem "ok" - um vigia que acabou de nascer nao
#       inventa uma queda)
#   3 - MEMORIA INDISPONIVEL: o `gh run list` falhou, entao nao da para saber
#       nada sobre os ciclos anteriores. Neste caso NADA e impresso no stdout e
#       o motivo vai para o stderr. Nao devolver "ok" aqui e o ponto: "ok" seria
#       indistinguivel de historico saudavel e faria o vigia ficar em silencio
#       para sempre, sem que nada acusasse. Quem chama precisa tratar o 3
#       explicitamente (ver o passo `decidir` do vigia.yml).
#
# O historico e lido POR BRANCH: o E2E roda numa branch separada enquanto o cron
# segue ativo na main, e sem esse filtro as duas memorias se misturariam - as
# falhas forjadas do teste fariam o ciclo seguinte da main anunciar uma
# recuperacao que nunca aconteceu, no grupo real.
#
# Seam de teste: GH_CMD substitui o binario gh.
set -uo pipefail

QUANTOS="${1:-2}"
GH="${GH_CMD:-gh}"
REPO="${GITHUB_REPOSITORY:-Codartia/grc-watchdog}"
WORKFLOW="${VIGIA_WORKFLOW:-vigia.yml}"
JOB="${VIGIA_JOB:-sonda}"
# Fora do Actions (execucao local, teste a mao) GITHUB_REF_NAME nao existe.
BRANCH="${GITHUB_REF_NAME:-main}"

# --status completed exclui a execucao corrente, que ainda esta in_progress.
# O status do gh e capturado a parte de proposito: sem isso, "gh falhou" e
# "gh devolveu vazio" viram o mesmo caso.
if ! ids="$("$GH" run list --repo "$REPO" --workflow "$WORKFLOW" \
        --branch "$BRANCH" \
        --status completed --limit "$QUANTOS" \
        --json databaseId --jq '.[].databaseId' 2>/dev/null)"; then
  echo "estado-anterior: nao consegui ler o historico de execucoes (gh run list falhou)." >&2
  echo "estado-anterior: a memoria do vigia esta indisponivel; saindo com 3." >&2
  exit 3
fi

vistos=0
while read -r id; do
  [ -n "$id" ] || continue
  # O --limit do gh ja deveria bastar, mas quem imprime as linhas e este laco:
  # o limite de verdade e aplicado aqui.
  [ "$vistos" -lt "$QUANTOS" ] || break
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
