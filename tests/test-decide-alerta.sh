#!/usr/bin/env bash
# Esta e a funcao que decide se alguem vai ser acordado. Cobre a tabela inteira
# do refinamento da D-6, inclusive os casos que existem para NAO alertar.

decidir() { bash scripts/decide-alerta.sh "$@"; }

assert_eq "queda"       "$(decidir ok falha falha)"    "1a falha sustentada vira alerta de queda"
assert_eq "silencio"    "$(decidir falha falha falha)" "queda ja anunciada nao repete a cada ciclo"
assert_eq "recuperacao" "$(decidir falha falha ok)"    "volta depois de queda anunciada avisa"
assert_eq "silencio"    "$(decidir ok falha ok)"       "blip que nunca alertou nao anuncia recuperacao"
assert_eq "silencio"    "$(decidir ok ok falha)"       "1a falha so arma, nao alerta"
assert_eq "silencio"    "$(decidir falha ok falha)"    "falha isolada depois de recuperacao so arma"
assert_eq "silencio"    "$(decidir ok ok ok)"          "tudo saudavel fica quieto"
assert_eq "silencio"    "$(decidir falha ok ok)"       "segundo ciclo saudavel fica quieto"

# Argumento invalido precisa gritar, nao adivinhar.
decidir ok ok talvez >/dev/null 2>&1
assert_saida "2" "$?" "argumento invalido e rejeitado"

decidir ok ok >/dev/null 2>&1
assert_saida "2" "$?" "argumento faltando e rejeitado"
