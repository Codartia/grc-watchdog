#!/usr/bin/env bash
# Harness minimo de teste. Sem dependencia externa de proposito: precisa rodar
# tanto no runner Ubuntu quanto no Git Bash do Windows, onde bats/jq nao existem.

TESTES_OK=0
TESTES_FALHA=0

assert_eq() {
  local esperado="$1" obtido="$2" msg="${3:-}"
  if [ "$esperado" = "$obtido" ]; then
    TESTES_OK=$((TESTES_OK + 1))
    echo "  ok   ${msg}"
  else
    TESTES_FALHA=$((TESTES_FALHA + 1))
    echo "  FALHA ${msg}"
    echo "         esperado: [${esperado}]"
    echo "         obtido:   [${obtido}]"
  fi
}

assert_saida() {
  assert_eq "$1" "$2" "$3 (codigo de saida)"
}

resumo() {
  echo
  echo "${TESTES_OK} ok, ${TESTES_FALHA} falha(s)"
  [ "$TESTES_FALHA" -eq 0 ]
}
