#!/usr/bin/env bash
# O harness precisa contar acerto e erro corretamente - se ele mentir, todo o
# resto da suite mente junto.

_ok_antes="$TESTES_OK"
assert_eq "abc" "abc" "assert_eq aceita valores iguais"
[ "$TESTES_OK" -eq $((_ok_antes + 1)) ] \
  || { echo "  FALHA harness nao incrementou TESTES_OK"; TESTES_FALHA=$((TESTES_FALHA + 1)); }

# Um assert que falha precisa incrementar TESTES_FALHA. Contamos e desfazemos,
# para que a falha proposital nao derrube a suite inteira.
_falha_antes="$TESTES_FALHA"
assert_eq "abc" "xyz" "(falha proposital - ignorar a linha acima)" >/dev/null
if [ "$TESTES_FALHA" -eq $((_falha_antes + 1)) ]; then
  TESTES_FALHA="$_falha_antes"
  TESTES_OK=$((TESTES_OK + 1))
  echo "  ok   assert_eq registra divergencia"
else
  echo "  FALHA harness nao incrementou TESTES_FALHA"
fi
