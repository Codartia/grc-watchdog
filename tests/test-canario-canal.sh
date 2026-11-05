#!/usr/bin/env bash
# Canario do canal: o vigia so considera o WhatsApp vivo com a instancia CONNECTED. Foi a falta disto
# que deixou a Z-API muda 36 dias sem ninguem notar. Identificadores sinteticos (repositorio publico).

_tmp="$(mktemp -d)"

cat > "$_tmp/curl.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CHAMADA_ARQUIVO"
printf '%s\n%s' "${STUB_CORPO:-}" "${STUB_CODIGO:-200}"
STUB
chmod +x "$_tmp/curl.sh"

export LEVAZAP_API_KEY="wag_live_CHAVESECRETA123"
export LEVAZAP_INSTANCE_ID="INST123"
export CHAMADA_ARQUIVO="$_tmp/chamada.txt"
export LEVAZAP_CURL_CMD="$_tmp/curl.sh"

# --- conectada ---
: > "$CHAMADA_ARQUIVO"
saida="$(STUB_CORPO='{"id":"INST123","status":"CONNECTED","queueDepth":0}' bash scripts/canario-canal.sh 2>&1)"
assert_saida "0" "$?" "canario CONNECTED sai 0"
assert_eq "1" "$(grep -c '^https://api.levazap.com.br/v1/instances/INST123/status$' "$CHAMADA_ARQUIVO")" "canario consulta o status da instancia"
assert_eq "0" "$(echo "$saida" | grep -c 'CHAVESECRETA123')" "canario nao imprime a chave"

# --- desconectada ---
saida="$(STUB_CORPO='{"id":"INST123","status":"DISCONNECTED"}' bash scripts/canario-canal.sh 2>&1)"
assert_saida "1" "$?" "canario DISCONNECTED sai 1"
assert_eq "1" "$(echo "$saida" | grep -c 'DISCONNECTED')" "canario informa o status lido"

# --- status com espaco no JSON ---
STUB_CORPO='{"id":"INST123", "status" : "CONNECTED"}' bash scripts/canario-canal.sh >/dev/null 2>&1
assert_saida "0" "$?" "canario aceita espacos no JSON"

# --- erro HTTP (chave revogada) ---
saida="$(STUB_CODIGO=401 STUB_CORPO='{"error":{"code":"INVALID_API_KEY"}}' bash scripts/canario-canal.sh 2>&1)"
assert_saida "1" "$?" "canario HTTP 401 sai 1"
assert_eq "1" "$(echo "$saida" | grep -c 'HTTP 401')" "canario informa o status HTTP"
assert_eq "0" "$(echo "$saida" | grep -c 'CHAVESECRETA123')" "canario com erro nao imprime a chave"

# --- variavel ausente ---
LEVAZAP_INSTANCE_ID="" bash scripts/canario-canal.sh >/dev/null 2>&1
assert_saida "2" "$?" "canario variavel ausente sai 2"

unset LEVAZAP_API_KEY LEVAZAP_INSTANCE_ID CHAMADA_ARQUIVO LEVAZAP_CURL_CMD
rm -rf "$_tmp"
