#!/usr/bin/env bash
# Envia uma mensagem de texto pela Levazap (substitui o notifica-zapi.sh).
#
# Contrato:
#   POST {LEVAZAP_BASE_URL}/instances/{LEVAZAP_INSTANCE_ID}/messages/text
#   headers: Authorization: Bearer {LEVAZAP_API_KEY} + Content-Type: application/json
#   body:    {"groupId":"<jid>@g.us","text":"..."}  (destino de grupo)
#            {"to":"<numero>","text":"..."}          (qualquer outro destino)
#   sucesso: 202 (mensagem enfileirada). Qualquer outro codigo e falha.
#
# Uso:  notifica-levazap.sh [--dry-run] [<mensagem>]
#       Sem argumento de mensagem, le do stdin.
#
# Seams de teste: LEVAZAP_CURL_CMD substitui o curl; LEVAZAP_BASE_URL a base da API.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

if [ "$#" -ge 1 ]; then
  mensagem="$1"
else
  mensagem="$(cat)"
fi

for nome in LEVAZAP_API_KEY LEVAZAP_INSTANCE_ID LEVAZAP_DESTINO; do
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

case "$LEVAZAP_DESTINO" in
  *@g.us) campo="groupId" ;;
  *)      campo="to" ;;
esac

base="${LEVAZAP_BASE_URL:-https://api.levazap.com.br/v1}"
base="${base%/}"
url="${base}/instances/${LEVAZAP_INSTANCE_ID}/messages/text"
payload="{\"${campo}\":\"$(escapar_json "$LEVAZAP_DESTINO")\",\"text\":\"$(escapar_json "$mensagem")\"}"

if [ "$DRY" -eq 1 ]; then
  # A chave vai num header: nunca e impressa, nem mascarada.
  echo "DRY-RUN destino: ${LEVAZAP_DESTINO}"
  echo "DRY-RUN url:     ${url}"
  echo "DRY-RUN payload: ${payload}"
  exit 0
fi

CURL="${LEVAZAP_CURL_CMD:-curl}"
# O corpo da resposta e capturado junto do codigo: o motivo real de uma falha
# (INSTANCE_NOT_CONNECTED, INVALID_API_KEY) so existe nele.
resposta="$("$CURL" -s -w '\n%{http_code}' -X POST "$url" \
  -H "Authorization: Bearer ${LEVAZAP_API_KEY}" \
  -H 'Content-Type: application/json' \
  --data "$payload" --max-time 20 2>/dev/null)" || true

codigo="$(printf '%s' "$resposta" | tail -n 1)"
corpo="$(printf '%s' "$resposta" | sed '$d')"

if [ "$codigo" = "202" ]; then
  echo "enviado"
  exit 0
fi

# O corpo e mensagem de erro da Levazap, nao conteudo nosso, e nunca traz a chave.
echo "falha no envio a Levazap: HTTP ${codigo:-000}" >&2
echo "resposta da Levazap: ${corpo:-<vazia>}" >&2
exit 1
