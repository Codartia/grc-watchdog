#!/usr/bin/env bash
# Este e o script que carrega segredo. Alem do comportamento, os testes provam
# que nenhum token vaza para a saida - criterio de aceite 8 da spec.

_tmp="$(mktemp -d)"

cat > "$_tmp/curl-200.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" > "$CHAMADA_ARQUIVO"
echo "200"
STUB
chmod +x "$_tmp/curl-200.sh"

cat > "$_tmp/curl-401.sh" <<'STUB'
#!/usr/bin/env bash
echo "401"
STUB
chmod +x "$_tmp/curl-401.sh"

export ZAPI_INSTANCE_ID="INST123"
export ZAPI_INSTANCE_TOKEN="TOKENSECRETO456"
export ZAPI_CLIENT_TOKEN="CLIENTSECRETO789"
# groupId sintetico, no formato que o Z-API usa. Nunca por aqui um identificador
# real de cliente: este repositorio e publico.
export ZAPI_DESTINO="120360000000000000-group"
export CHAMADA_ARQUIVO="$_tmp/chamada.txt"

# --- dry-run nao envia e nao vaza segredo ---
saida="$(bash scripts/notifica-zapi.sh --dry-run "teste de mensagem")"
assert_saida "0" "$?" "dry-run sai 0"
assert_eq "0" "$(echo "$saida" | grep -c 'TOKENSECRETO456')" "dry-run nao imprime o instance token"
assert_eq "0" "$(echo "$saida" | grep -c 'CLIENTSECRETO789')" "dry-run nao imprime o client token"
assert_eq "1" "$(echo "$saida" | grep -c 'teste de mensagem')" "dry-run mostra a mensagem"
assert_eq "1" "$(echo "$saida" | grep -c '^DRY-RUN destino: 120360000000000000-group$')" "dry-run mostra o destino na linha legivel"

# --- envio com sucesso ---
: > "$CHAMADA_ARQUIVO"
saida="$(ZAPI_CURL_CMD="$_tmp/curl-200.sh" bash scripts/notifica-zapi.sh "ola")"
assert_saida "0" "$?" "envio com HTTP 200 sai 0"
assert_eq "1" "$(grep -c 'send-text' "$CHAMADA_ARQUIVO")" "url termina em send-text"
assert_eq "1" "$(grep -c 'Client-Token: CLIENTSECRETO789' "$CHAMADA_ARQUIVO")" "header Client-Token vai na chamada"
assert_eq "1" "$(grep -c '"phone":"120360000000000000-group"' "$CHAMADA_ARQUIVO")" "payload usa o campo phone"

# --- Z-API recusando ---
bash -c 'ZAPI_CURL_CMD="'"$_tmp"'/curl-401.sh" bash scripts/notifica-zapi.sh "ola"' >/dev/null 2>&1
assert_saida "1" "$?" "HTTP diferente de 200 sai 1"

# --- mensagem com quebra de linha e aspas nao quebra o JSON ---
: > "$CHAMADA_ARQUIVO"
ZAPI_CURL_CMD="$_tmp/curl-200.sh" bash scripts/notifica-zapi.sh "$(printf 'linha1\nlinha "2"')" >/dev/null
assert_eq "1" "$(grep -c 'linha1\\nlinha \\"2\\"' "$CHAMADA_ARQUIVO")" "quebra de linha e aspas sao escapadas"

# --- variavel obrigatoria ausente ---
saida="$(ZAPI_DESTINO="" bash scripts/notifica-zapi.sh --dry-run "x" 2>&1)"
assert_saida "2" "$?" "variavel obrigatoria ausente sai 2"
assert_eq "1" "$(echo "$saida" | grep -c 'ZAPI_DESTINO')" "erro diz qual variavel falta"

# --- mensagem vazia ---
bash -c 'ZAPI_INSTANCE_ID=a ZAPI_INSTANCE_TOKEN=b ZAPI_CLIENT_TOKEN=c ZAPI_DESTINO=d bash scripts/notifica-zapi.sh --dry-run "" ' >/dev/null 2>&1
assert_saida "2" "$?" "mensagem vazia sai 2"

unset ZAPI_INSTANCE_ID ZAPI_INSTANCE_TOKEN ZAPI_CLIENT_TOKEN ZAPI_DESTINO CHAMADA_ARQUIVO
rm -rf "$_tmp"
