#!/usr/bin/env bash
# Canario do canal de aviso: confere se a instancia da Levazap esta CONNECTED.
#
# Por que existe: a Z-API ficou 36 dias sem entregar nenhuma mensagem (assinatura
# vencida) e ninguem notou, porque o envio so e exercitado quando ha algo a avisar.
# O vigia roda este canario a cada ciclo; saida diferente de 0 manda o batimento
# do healthchecks.io para /fail, que avisa por e-mail (fora do WhatsApp).
#
#   GET {LEVAZAP_BASE_URL}/instances/{LEVAZAP_INSTANCE_ID}/status
#   sai 0 so com "status":"CONNECTED"; 1 em qualquer outro caso; 2 sem configuracao.
#
# Seams de teste: LEVAZAP_CURL_CMD e LEVAZAP_BASE_URL.
set -uo pipefail

for nome in LEVAZAP_API_KEY LEVAZAP_INSTANCE_ID; do
  eval "valor=\${${nome}:-}"
  if [ -z "$valor" ]; then
    echo "variavel obrigatoria ausente: ${nome}" >&2
    exit 2
  fi
done

base="${LEVAZAP_BASE_URL:-https://api.levazap.com.br/v1}"
base="${base%/}"
url="${base}/instances/${LEVAZAP_INSTANCE_ID}/status"

CURL="${LEVAZAP_CURL_CMD:-curl}"
resposta="$("$CURL" -s -w '\n%{http_code}' "$url" \
  -H "Authorization: Bearer ${LEVAZAP_API_KEY}" --max-time 20 2>/dev/null)" || true

codigo="$(printf '%s' "$resposta" | tail -n 1)"
corpo="$(printf '%s' "$resposta" | sed '$d')"

if [ "$codigo" != "200" ]; then
  echo "canario: status da instancia indisponivel: HTTP ${codigo:-000}" >&2
  echo "resposta da Levazap: ${corpo:-<vazia>}" >&2
  exit 1
fi

status="$(printf '%s' "$corpo" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([A-Z_]*\)".*/\1/p' | head -n 1)"
if [ "$status" = "CONNECTED" ]; then
  echo "canario: canal CONNECTED"
  exit 0
fi

echo "canario: canal ${status:-desconhecido} (esperado CONNECTED)" >&2
exit 1
