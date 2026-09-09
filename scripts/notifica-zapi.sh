#!/usr/bin/env bash
# Envia uma mensagem de texto pelo Z-API.
#
# Contrato conferido no notificador de deploy que ja roda em producao:
#   POST https://api.z-api.io/instances/{ID}/token/{TOKEN}/send-text
#   headers: Content-Type: application/json + Client-Token: {CLIENT_TOKEN}
#   body:    {"phone": "<destino>", "message": "<texto>"}
#
# Uso:  notifica-zapi.sh [--dry-run] [<mensagem>]
#       Sem argumento de mensagem, le do stdin.
#
# Seam de teste: ZAPI_CURL_CMD substitui o curl.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

if [ "$#" -ge 1 ]; then
  mensagem="$1"
else
  mensagem="$(cat)"
fi

for nome in ZAPI_INSTANCE_ID ZAPI_INSTANCE_TOKEN ZAPI_CLIENT_TOKEN ZAPI_DESTINO; do
  eval "valor=\${${nome}:-}"
  if [ -z "$valor" ]; then
    echo "variavel obrigatoria ausente: ${nome}" >&2
    exit 2
  fi
done

if [ -z "$mensagem" ]; then
  echo "mensagem vazia" >&2
  exit 2
fi

# Escapa o suficiente para o JSON que NOS geramos (aspas, barra, quebras, tab).
# Nao e um encoder JSON completo de proposito: nao ha dependencia externa
# disponivel e o conteudo e sempre produzido por este repo.
escapar_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

payload="{\"phone\":\"$(escapar_json "$ZAPI_DESTINO")\",\"message\":\"$(escapar_json "$mensagem")\"}"
url="https://api.z-api.io/instances/${ZAPI_INSTANCE_ID}/token/${ZAPI_INSTANCE_TOKEN}/send-text"

if [ "$DRY" -eq 1 ]; then
  # A url carrega dois segredos no caminho, entao ela nunca e impressa.
  echo "DRY-RUN destino: ${ZAPI_DESTINO}"
  echo "DRY-RUN url:     https://api.z-api.io/instances/***/token/***/send-text"
  echo "DRY-RUN payload: ${payload}"
  exit 0
fi

CURL="${ZAPI_CURL_CMD:-curl}"
# O corpo da resposta e capturado junto do codigo: sem ele, uma falha de envio
# vira "HTTP 400" e mais nada, e o motivo real (instancia desconectada, telefone
# invalido, token vencido) so existe nessa resposta. Descoberto no E2E do
# ligamento, em 2026-09-08, quando o primeiro envio real falhou sem pista.
resposta="$("$CURL" -s -w '\n%{http_code}' -X POST "$url" \
  -H 'Content-Type: application/json' \
  -H "Client-Token: ${ZAPI_CLIENT_TOKEN}" \
  --data "$payload" --max-time 20 2>/dev/null)" || true

codigo="$(printf '%s' "$resposta" | tail -n 1)"
corpo="$(printf '%s' "$resposta" | sed '$d')"

if [ "$codigo" = "200" ]; then
  echo "enviado"
  exit 0
fi

# O corpo e mensagem de erro do Z-API, nao conteudo nosso. Os segredos vao na
# URL e no header, nunca na resposta; e o Actions ainda mascara secrets no log.
echo "falha no envio ao Z-API: HTTP ${codigo:-000}" >&2
echo "resposta do Z-API: ${corpo:-<vazia>}" >&2
exit 1
