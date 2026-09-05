#!/usr/bin/env bash
# A sonda e o unico ponto que fala com o mundo real, entao o seam de fetch
# precisa estar bem coberto - e o que permite testar sem rede.

_tmp="$(mktemp -d)"

# Stub que devolve sempre 200.
cat > "$_tmp/fetch-200.sh" <<'STUB'
#!/usr/bin/env bash
echo "200"
STUB
chmod +x "$_tmp/fetch-200.sh"

# Stub que simula erro de rede (curl devolve 000 quando nao conecta).
cat > "$_tmp/fetch-000.sh" <<'STUB'
#!/usr/bin/env bash
echo "000"
STUB
chmod +x "$_tmp/fetch-000.sh"

# Stub que conta quantas vezes foi chamado, para provar a regra de 2 tentativas.
cat > "$_tmp/fetch-conta.sh" <<'STUB'
#!/usr/bin/env bash
echo "x" >> "$CONTADOR"
echo "500"
STUB
chmod +x "$_tmp/fetch-conta.sh"

printf '%s\n' \
  '# comentario deve ser ignorado' \
  '' \
  'https://exemplo.test/a 200' \
  'https://exemplo.test/b 200' \
  > "$_tmp/alvos.conf"

# --- todos os alvos saudaveis ---
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-200.sh" bash scripts/sonda.sh "$_tmp/alvos.conf")"
codigo=$?
assert_saida "0" "$codigo" "sonda sai 0 quando todos os alvos respondem"
assert_eq "2" "$(echo "$saida" | grep -c '^OK ')" "duas linhas OK"
assert_eq "0" "$(echo "$saida" | grep -c '^FALHA ')" "nenhuma linha FALHA"

# --- alvo inalcancavel ---
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-000.sh" bash scripts/sonda.sh "$_tmp/alvos.conf")"
codigo=$?
assert_saida "1" "$codigo" "sonda sai 1 quando alvo nao responde"
assert_eq "2" "$(echo "$saida" | grep -c '^FALHA ')" "duas linhas FALHA"
assert_eq "FALHA https://exemplo.test/a 000 200" \
  "$(echo "$saida" | head -1)" "linha de falha traz obtido e esperado"

# --- codigo diferente do esperado tambem e falha ---
printf '%s\n' 'https://exemplo.test/raiz 302' > "$_tmp/alvos-302.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-200.sh" bash scripts/sonda.sh "$_tmp/alvos-302.conf")"
codigo=$?
assert_saida "1" "$codigo" "200 onde se espera 302 e falha"

# --- comentario e linha em branco nao viram alvo ---
printf '%s\n' '# so comentario' '' > "$_tmp/alvos-vazio.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-000.sh" bash scripts/sonda.sh "$_tmp/alvos-vazio.conf")"
codigo=$?
assert_saida "0" "$codigo" "arquivo so com comentario nao gera falha"
assert_eq "" "$saida" "arquivo so com comentario nao gera saida"

# --- regra de 2 tentativas ---
export CONTADOR="$_tmp/contador.txt"
: > "$CONTADOR"
printf '%s\n' 'https://exemplo.test/a 200' > "$_tmp/alvos-um.conf"
SONDA_FETCH_CMD="$_tmp/fetch-conta.sh" bash scripts/sonda.sh "$_tmp/alvos-um.conf" >/dev/null
assert_eq "2" "$(wc -l < "$CONTADOR" | tr -d ' ')" "alvo em falha e tentado 2 vezes"

: > "$CONTADOR"
printf '%s\n' 'https://exemplo.test/a 500' > "$_tmp/alvos-500.conf"
SONDA_FETCH_CMD="$_tmp/fetch-conta.sh" bash scripts/sonda.sh "$_tmp/alvos-500.conf" >/dev/null
assert_eq "1" "$(wc -l < "$CONTADOR" | tr -d ' ')" "alvo que acerta de primeira nao tenta de novo"
unset CONTADOR

rm -rf "$_tmp"
