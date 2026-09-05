#!/usr/bin/env bash
# Sonda cada alvo do arquivo de configuracao e diz se o Graces responde de fora.
#
# Uso:   sonda.sh [caminho-do-alvos.conf]
# Saida: uma linha por alvo, "OK|FALHA <url> <obtido> <esperado>"
# Codigo de saida: 0 se todos passaram, 1 se algum falhou.
#
# Seam de teste: SONDA_FETCH_CMD substitui o curl. O comando recebe a URL e deve
# imprimir o codigo HTTP, ou "000" para erro de rede - igual ao que o curl faz
# com -o /dev/null -w '%{http_code}'.
set -uo pipefail

ALVOS="${1:-$(dirname "$0")/../alvos.conf}"
TIMEOUT="${SONDA_TIMEOUT:-10}"
TENTATIVAS="${SONDA_TENTATIVAS:-2}"

buscar() {
  local url="$1" codigo
  if [ -n "${SONDA_FETCH_CMD:-}" ]; then
    "$SONDA_FETCH_CMD" "$url"
    return
  fi
  # O curl imprime 000 e sai diferente de zero quando nem conecta; normalizamos
  # para nunca devolver string vazia, que confundiria a comparacao la embaixo.
  codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null)" || true
  [ -n "$codigo" ] || codigo="000"
  echo "$codigo"
}

houve_falha=0

while read -r url esperado _resto; do
  case "$url" in ''|\#*) continue ;; esac
  [ -n "${esperado:-}" ] || continue

  obtido=""
  tentativa=1
  while [ "$tentativa" -le "$TENTATIVAS" ]; do
    obtido="$(buscar "$url")"
    [ "$obtido" = "$esperado" ] && break
    tentativa=$((tentativa + 1))
  done

  if [ "$obtido" = "$esperado" ]; then
    echo "OK $url $obtido $esperado"
  else
    echo "FALHA $url $obtido $esperado"
    houve_falha=1
  fi
done < "$ALVOS"

exit "$houve_falha"
