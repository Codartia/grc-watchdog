#!/usr/bin/env bash
# Decide o que fazer comparando os tres ultimos ciclos (refinamento da regra D-6
# da spec). Sao TRES amostras, e nao duas, porque "alertar so na primeira
# transicao" exige saber se o ciclo anterior ja estava em falha - com duas
# colunas o terceiro ciclo consecutivo alertaria de novo, a cada 5 minutos.
#
# Uso:   decide-alerta.sh <penultimo> <anterior> <atual>   # cada um: ok | falha
# Saida: silencio | queda | recuperacao
set -uo pipefail

penultimo="${1:-}"
anterior="${2:-}"
atual="${3:-}"

for valor in "$penultimo" "$anterior" "$atual"; do
  case "$valor" in
    ok|falha) ;;
    *) echo "esperado 'ok' ou 'falha', recebido: '${valor}'" >&2; exit 2 ;;
  esac
done

if [ "$atual" = "falha" ] && [ "$anterior" = "falha" ] && [ "$penultimo" = "ok" ]; then
  # Segunda falha consecutiva: nao e mais blip.
  echo "queda"
elif [ "$atual" = "ok" ] && [ "$anterior" = "falha" ] && [ "$penultimo" = "falha" ]; then
  # So anuncia a volta de uma queda que chegou a ser anunciada.
  echo "recuperacao"
else
  echo "silencio"
fi
