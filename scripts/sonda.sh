#!/usr/bin/env bash
# Sonda cada alvo do arquivo de configuracao e diz se o Graces responde de fora.
#
# Uso:   sonda.sh [caminho-do-alvos.conf]
# Saida: uma linha por alvo, "OK|FALHA <url> <obtido> <esperado>"
# Codigo de saida: 0 se todos passaram, 1 se algum falhou.
#
# Seam de teste: SONDA_FETCH_CMD substitui o curl. O comando recebe a URL e deve
# imprimir o codigo HTTP, ou "000" para erro de rede - igual ao que o curl faz
# com -o /dev/null -w '%{http_code}'. Opcionalmente, um segundo campo com o tempo
# em segundos (o '%{time_total}' do curl).
#
# SONDA_RESULTADOS (opcional): arquivo onde cada alvo vira uma linha
# "<OK|FALHA>	<url>	<obtido>	<esperado>	<ms>" (TAB entre campos; ms vazio quando nao medido).
# E a entrada da pagina de status (status.py). A saida padrao NAO muda: ela e o
# relatorio do alerta e o formato dela e contrato com o workflow.
set -uo pipefail

ALVOS="${1:-$(dirname "$0")/../alvos.conf}"
TIMEOUT="${SONDA_TIMEOUT:-10}"
TENTATIVAS="${SONDA_TENTATIVAS:-2}"

RESULTADOS="${SONDA_RESULTADOS:-}"
[ -z "$RESULTADOS" ] || : > "$RESULTADOS"

# Imprime "<codigo> [segundos]".
buscar() {
  local url="$1" codigo
  if [ -n "${SONDA_FETCH_CMD:-}" ]; then
    "$SONDA_FETCH_CMD" "$url"
    return
  fi
  # O curl imprime 000 e sai diferente de zero quando nem conecta; normalizamos
  # para nunca devolver string vazia, que confundiria a comparacao la embaixo.
  codigo="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" "$url" 2>/dev/null)" || true
  [ -n "${codigo// /}" ] || codigo="000"
  echo "$codigo"
}

# "0.523190" -> "523". Sem bc/awk de proposito (mesmo motivo do harness).
para_ms() {
  local s="$1" inteiro frac
  case "$s" in ''|*[!0-9.]*) echo ""; return ;; esac
  inteiro="${s%%.*}"; frac="${s#*.}"
  [ "$frac" != "$s" ] || frac=""
  frac="${frac}000"; frac="${frac:0:3}"
  echo $(( 10#${inteiro:-0} * 1000 + 10#$frac ))
}

houve_falha=0

# O `|| [ -n "$url" ]` recupera a ultima linha quando o arquivo nao termina em
# newline. O README manda humanos editarem o alvos.conf a mao; sem isso, um
# editor que nao poe a quebra final faria o ultimo alvo deixar de ser sondado -
# em silencio, que e o pior modo de falha possivel aqui.
while read -r url esperado _resto || [ -n "$url" ]; do
  case "$url" in ''|\#*) continue ;; esac
  [ -n "${esperado:-}" ] || continue

  obtido=""
  segundos=""
  tentativa=1
  while [ "$tentativa" -le "$TENTATIVAS" ]; do
    read -r obtido segundos _x <<< "$(buscar "$url")"
    [ -n "$obtido" ] || obtido="000"
    [ "$obtido" = "$esperado" ] && break
    tentativa=$((tentativa + 1))
  done

  if [ "$obtido" = "$esperado" ]; then
    estado="OK"
  else
    estado="FALHA"
    houve_falha=1
  fi
  echo "$estado $url $obtido $esperado"
  [ -z "$RESULTADOS" ] || printf '%s\t%s\t%s\t%s\t%s\n' \
    "$estado" "$url" "$obtido" "$esperado" "$(para_ms "${segundos:-}")" >> "$RESULTADOS"
done < "$ALVOS"

exit "$houve_falha"
