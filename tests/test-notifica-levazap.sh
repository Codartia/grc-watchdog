#!/usr/bin/env bash
# Envio pela Levazap. Este script carrega segredo: alem do comportamento, os testes provam que a
# chave nunca vai para a saida. Identificadores sinteticos: este repositorio e publico.

_tmp="$(mktemp -d)"

# Stub do curl: grava os argumentos e devolve corpo + codigo, como o -w '\n%{http_code}' do script.
cat > "$_tmp/curl.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CHAMADA_ARQUIVO"
printf '%s\n%s' "${STUB_CORPO:-}" "${STUB_CODIGO:-202}"
STUB
chmod +x "$_tmp/curl.sh"

export LEVAZAP_API_KEY="wag_live_CHAVESECRETA123"
export LEVAZAP_INSTANCE_ID="INST123"
export LEVAZAP_DESTINO="120360000000000000@g.us"
export CHAMADA_ARQUIVO="$_tmp/chamada.txt"

# --- dry-run nao envia e nao vaza a chave ---
saida="$(bash scripts/notifica-levazap.sh --dry-run "teste de mensagem" 2>&1)"
assert_saida "0" "$?" "levazap dry-run sai 0"
assert_eq "0" "$(echo "$saida" | grep -c 'CHAVESECRETA123')" "levazap dry-run nao imprime a chave"
assert_eq "0" "$(echo "$saida" | grep -c 'Bearer')" "levazap dry-run nao imprime o header de autorizacao"
assert_eq "1" "$(echo "$saida" | grep -c '^DRY-RUN destino: 120360000000000000@g.us$')" "levazap dry-run mostra o destino"

# --- payload com aspas e quebra de linha e JSON valido ---
payload="$(bash scripts/notifica-levazap.sh --dry-run "$(printf 'linha1\nlinha "2"')" | sed -n 's/^DRY-RUN payload: //p')"
py=""
for c in python3 python; do "$c" -c '' >/dev/null 2>&1 && py="$c" && break; done
printf '%s' "$payload" | "$py" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["text"] == "linha1\nlinha \"2\"" else 1)'
assert_saida "0" "$?" "levazap payload com aspas e quebra de linha e JSON valido"

# --- envio aceito (202) ---
: > "$CHAMADA_ARQUIVO"
saida="$(STUB_CODIGO=202 LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" 2>&1)"
assert_saida "0" "$?" "levazap 202 sai 0"
assert_eq "1" "$(grep -c '^https://api.levazap.com.br/v1/instances/INST123/messages/text$' "$CHAMADA_ARQUIVO")" "levazap url padrao de producao"
assert_eq "1" "$(grep -c '"groupId":"120360000000000000@g.us"' "$CHAMADA_ARQUIVO")" "levazap destino de grupo usa groupId"
assert_eq "1" "$(grep -c '^Authorization: Bearer wag_live_CHAVESECRETA123$' "$CHAMADA_ARQUIVO")" "levazap chave vai no header Authorization"
assert_eq "0" "$(echo "$saida" | grep -c 'CHAVESECRETA123')" "levazap envio nao imprime a chave"

# --- base url sobrescrevivel (seam de teste) ---
: > "$CHAMADA_ARQUIVO"
STUB_CODIGO=202 LEVAZAP_BASE_URL="https://stub.local/v1" LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" >/dev/null 2>&1
assert_eq "1" "$(grep -c '^https://stub.local/v1/instances/INST123/messages/text$' "$CHAMADA_ARQUIVO")" "levazap LEVAZAP_BASE_URL muda a base"

# --- destino que nao e grupo usa "to" ---
: > "$CHAMADA_ARQUIVO"
STUB_CODIGO=202 LEVAZAP_DESTINO="5511900000000" LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" >/dev/null 2>&1
assert_eq "1" "$(grep -c '"to":"5511900000000"' "$CHAMADA_ARQUIVO")" "levazap destino sem @g.us usa to"

# --- instancia desconectada (409): falha com status e corpo, sem a chave ---
saida="$(STUB_CODIGO=409 STUB_CORPO='{"error":{"code":"INSTANCE_NOT_CONNECTED"}}' LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" 2>&1)"
assert_saida "1" "$?" "levazap 409 sai 1"
assert_eq "1" "$(echo "$saida" | grep -c 'HTTP 409')" "levazap 409 informa o status"
assert_eq "1" "$(echo "$saida" | grep -c 'INSTANCE_NOT_CONNECTED')" "levazap 409 mostra o motivo do corpo"
assert_eq "0" "$(echo "$saida" | grep -c 'CHAVESECRETA123')" "levazap falha nao imprime a chave"

# --- chave recusada (401) ---
STUB_CODIGO=401 LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" >/dev/null 2>&1
assert_saida "1" "$?" "levazap 401 sai 1"

# --- 200 nao e o contrato (202 = enfileirado) ---
STUB_CODIGO=200 LEVAZAP_CURL_CMD="$_tmp/curl.sh" bash scripts/notifica-levazap.sh "ola" >/dev/null 2>&1
assert_saida "1" "$?" "levazap status diferente de 202 sai 1"

# --- variavel obrigatoria ausente / mensagem vazia ---
saida="$(LEVAZAP_API_KEY="" bash scripts/notifica-levazap.sh --dry-run "x" 2>&1)"
assert_saida "2" "$?" "levazap variavel ausente sai 2"
assert_eq "1" "$(echo "$saida" | grep -c 'LEVAZAP_API_KEY')" "levazap erro diz qual variavel falta"
bash scripts/notifica-levazap.sh --dry-run "" >/dev/null 2>&1
assert_saida "2" "$?" "levazap mensagem vazia sai 2"

unset LEVAZAP_API_KEY LEVAZAP_INSTANCE_ID LEVAZAP_DESTINO CHAMADA_ARQUIVO
rm -rf "$_tmp"
