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

# --- arquivo sem newline final nao perde o ultimo alvo ---
# O README manda humanos editarem o alvos.conf; um editor sem quebra final
# faria o ultimo alvo sumir da sonda em silencio.
printf 'https://exemplo.test/a 200\nhttps://exemplo.test/b 200' > "$_tmp/alvos-sem-nl.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-200.sh" bash scripts/sonda.sh "$_tmp/alvos-sem-nl.conf")"
codigo=$?
assert_saida "0" "$codigo" "arquivo sem newline final sai 0 quando tudo responde"
assert_eq "2" "$(echo "$saida" | grep -c '^OK ')" "ultimo alvo sem newline final e sondado"
assert_eq "OK https://exemplo.test/b 200 200" \
  "$(echo "$saida" | sed -n '2p')" "o alvo recuperado e mesmo o ultimo do arquivo"

# E ele tambem precisa DERRUBAR o ciclo quando falha - de nada adianta aparecer
# na listagem e nao contar para o codigo de saida.
printf 'https://exemplo.test/a 200\nhttps://exemplo.test/b 200' > "$_tmp/alvos-sem-nl2.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-000.sh" bash scripts/sonda.sh "$_tmp/alvos-sem-nl2.conf")"
codigo=$?
assert_saida "1" "$codigo" "alvo sem newline final em falha faz a sonda sair 1"
assert_eq "2" "$(echo "$saida" | grep -c '^FALHA ')" "as duas linhas viram FALHA"

# Arquivo de UMA linha so, sem newline nenhum: o caso extremo do mesmo bug.
printf 'https://exemplo.test/unico 200' > "$_tmp/alvos-uma-linha.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-000.sh" bash scripts/sonda.sh "$_tmp/alvos-uma-linha.conf")"
codigo=$?
assert_saida "1" "$codigo" "arquivo de uma linha sem newline ainda e sondado"
assert_eq "FALHA https://exemplo.test/unico 000 200" "$saida" "e a linha sai completa"

# --- arquivo totalmente vazio nao entra em laco nem quebra ---
: > "$_tmp/alvos-nada.conf"
saida="$(SONDA_FETCH_CMD="$_tmp/fetch-000.sh" bash scripts/sonda.sh "$_tmp/alvos-nada.conf")"
codigo=$?
assert_saida "0" "$codigo" "arquivo vazio nao gera falha"
assert_eq "" "$saida" "arquivo vazio nao gera saida"

# --- arquivo de resultados da pagina de status (SONDA_RESULTADOS) ---
cat > "$_tmp/fetch-tempo.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  *lenta*) echo "200 3.2041" ;;
  *fora*)  echo "000 10.001" ;;
  *)       echo "200 0.0425" ;;
esac
STUB
chmod +x "$_tmp/fetch-tempo.sh"
printf '%s\n' 'https://exemplo.test/rapida 200' 'https://exemplo.test/lenta 200' 'https://exemplo.test/fora 200' > "$_tmp/alvos-tempo.conf"
saida="$(SONDA_RESULTADOS="$_tmp/res.tsv" SONDA_FETCH_CMD="$_tmp/fetch-tempo.sh" bash scripts/sonda.sh "$_tmp/alvos-tempo.conf")"
codigo=$?
assert_saida "1" "$codigo" "com resultados ligado o codigo de saida nao muda"
assert_eq "OK https://exemplo.test/lenta 200 200" "$(echo "$saida" | sed -n '2p')" "a saida padrao nao ganha o tempo"
assert_eq "3" "$(wc -l < "$_tmp/res.tsv" | tr -d ' ')" "uma linha de resultado por alvo"
assert_eq "$(printf 'OK\thttps://exemplo.test/rapida\t200\t200\t42')" "$(sed -n '1p' "$_tmp/res.tsv")" "tempo em ms truncado"
assert_eq "$(printf 'OK\thttps://exemplo.test/lenta\t200\t200\t3204')" "$(sed -n '2p' "$_tmp/res.tsv")" "segundos inteiros viram milhares"
assert_eq "$(printf 'FALHA\thttps://exemplo.test/fora\t000\t200\t10001')" "$(sed -n '3p' "$_tmp/res.tsv")" "falha tambem registra"

# Stub sem tempo (o formato antigo do seam): ms fica vazio, nao quebra.
SONDA_RESULTADOS="$_tmp/res2.tsv" SONDA_FETCH_CMD="$_tmp/fetch-200.sh" bash scripts/sonda.sh "$_tmp/alvos-um.conf" >/dev/null
assert_eq "$(printf 'OK\thttps://exemplo.test/a\t200\t200\t')" "$(cat "$_tmp/res2.tsv")" "sem tempo medido o campo ms fica vazio"

# Rodada nova zera o arquivo (nao acumula rodadas anteriores).
SONDA_RESULTADOS="$_tmp/res2.tsv" SONDA_FETCH_CMD="$_tmp/fetch-200.sh" bash scripts/sonda.sh "$_tmp/alvos-um.conf" >/dev/null
assert_eq "1" "$(wc -l < "$_tmp/res2.tsv" | tr -d ' ')" "cada rodada reescreve o arquivo"

rm -rf "$_tmp"
