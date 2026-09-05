#!/usr/bin/env bash
# O historico do GitHub e a unica memoria do vigia (decisao D-7). Se esta leitura
# errar, ele alerta duas vezes ou nao alerta nunca.

_tmp="$(mktemp -d)"

# Stub de gh: "run list" devolve ids; "api .../jobs" devolve a conclusao que
# estiver mapeada em CONCLUSOES (formato "id=conclusao" por linha).
cat > "$_tmp/gh-stub.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  cat "$IDS_ARQUIVO"
  exit 0
fi
if [ "$1" = "api" ]; then
  caminho="$2"
  id="${caminho#repos/*/actions/runs/}"
  id="${id%/jobs}"
  grep "^${id}=" "$CONCLUSOES_ARQUIVO" | head -1 | cut -d= -f2
  exit 0
fi
exit 1
STUB
chmod +x "$_tmp/gh-stub.sh"

# Stub de gh que sempre falha: token sem escopo, outage da API, rate limit.
# E o caso que precisa ser distinguido de "gh devolveu vazio com sucesso".
cat > "$_tmp/gh-quebrado.sh" <<'STUB'
#!/usr/bin/env bash
echo "gh: could not read the run list" >&2
exit 1
STUB
chmod +x "$_tmp/gh-quebrado.sh"

# Stub que grava os argumentos do "run list" para provar o que foi repassado.
cat > "$_tmp/gh-argumentos.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  printf '%s\n' "$@" > "$ARGS_ARQUIVO"
  exit 0
fi
exit 1
STUB
chmod +x "$_tmp/gh-argumentos.sh"

export GH_CMD="$_tmp/gh-stub.sh"
export IDS_ARQUIVO="$_tmp/ids.txt"
export CONCLUSOES_ARQUIVO="$_tmp/conclusoes.txt"

# --- dois ciclos saudaveis ---
printf '%s\n' '111' '222' > "$IDS_ARQUIVO"
printf '%s\n' '111=success' '222=success' > "$CONCLUSOES_ARQUIVO"
assert_eq "ok
ok" "$(bash scripts/estado-anterior.sh 2)" "dois ciclos com sucesso viram ok/ok"

# --- ciclo mais recente falhou ---
printf '%s\n' '111=failure' '222=success' > "$CONCLUSOES_ARQUIVO"
assert_eq "falha
ok" "$(bash scripts/estado-anterior.sh 2)" "ordem e do mais recente para o mais antigo"

# --- historico insuficiente (repo novo) ---
printf '%s\n' '111' > "$IDS_ARQUIVO"
printf '%s\n' '111=success' > "$CONCLUSOES_ARQUIVO"
assert_eq "ok
ok" "$(bash scripts/estado-anterior.sh 2)" "historico curto e completado com ok"

# --- sem historico nenhum ---
# Este caso e o gemeo do de baixo: gh SAIU 0 e nao devolveu nada, o que e um
# repo recem-criado - legitimo. Aqui "ok" e a resposta certa.
: > "$IDS_ARQUIVO"
: > "$CONCLUSOES_ARQUIVO"
saida="$(bash scripts/estado-anterior.sh 2)"
assert_saida "0" "$?" "gh devolvendo vazio COM SUCESSO sai 0"
assert_eq "ok
ok" "$saida" "repo recem-criado nao inventa queda: 2 linhas de ok"

# --- historico ilegivel: gh saiu diferente de zero ---
# O caso oposto ao de cima, e que antes era indistinguivel dele. Preencher com
# "ok" aqui seria mentira: nao se sabe nada dos ciclos anteriores, e o "ok"
# faria o vigia nunca chegar em "queda" - silencio permanente e invisivel.
saida="$(GH_CMD="$_tmp/gh-quebrado.sh" bash scripts/estado-anterior.sh 2 2>"$_tmp/erro.txt")"
assert_saida "3" "$?" "gh FALHANDO sai 3 (memoria indisponivel)"
assert_eq "" "$saida" "gh falhando nao imprime linha nenhuma no stdout"
if [ -s "$_tmp/erro.txt" ]; then _tem_stderr=sim; else _tem_stderr=nao; fi
assert_eq "sim" "$_tem_stderr" "gh falhando explica o motivo no stderr"
assert_eq "1" "$(grep -ci 'memoria' "$_tmp/erro.txt" | tr -d ' ')" \
  "o stderr diz que a memoria esta indisponivel"

# --- run cancelado nao vira queda ---
printf '%s\n' '111' '222' > "$IDS_ARQUIVO"
printf '%s\n' '111=cancelled' '222=success' > "$CONCLUSOES_ARQUIVO"
assert_eq "ok
ok" "$(bash scripts/estado-anterior.sh 2)" "run cancelado nao e tratado como queda"

# --- o laco respeita QUANTOS mesmo se o gh devolver mais ids ---
# O --limit do gh e do gh; quem imprime as linhas e o laco, e e ele que precisa
# parar. Com 5 ids e QUANTOS=2 a saida tem que ter exatamente 2 linhas.
printf '%s\n' '111' '222' '333' '444' '555' > "$IDS_ARQUIVO"
printf '%s\n' '111=success' '222=success' '333=failure' '444=failure' '555=failure' \
  > "$CONCLUSOES_ARQUIVO"
saida="$(bash scripts/estado-anterior.sh 2)"
assert_eq "2" "$(printf '%s\n' "$saida" | grep -c .)" "saida e limitada a QUANTOS linhas"
assert_eq "ok
ok" "$saida" "as linhas extras do gh sao descartadas, nao concatenadas"

# --- o historico e lido por branch ---
# Sem --branch, o E2E numa branch separada e o cron da main compartilhariam
# memoria: as falhas forjadas do teste fariam o ciclo seguinte da main anunciar
# uma recuperacao que nunca aconteceu, no grupo real.
export ARGS_ARQUIVO="$_tmp/args.txt"

: > "$ARGS_ARQUIVO"
GH_CMD="$_tmp/gh-argumentos.sh" GITHUB_REF_NAME="teste/e2e" \
  bash scripts/estado-anterior.sh 2 >/dev/null
assert_eq "teste/e2e" "$(grep -A1 '^--branch$' "$ARGS_ARQUIVO" | sed -n '2p')" \
  "gh run list recebe --branch com a branch corrente"

: > "$ARGS_ARQUIVO"
env -u GITHUB_REF_NAME GH_CMD="$_tmp/gh-argumentos.sh" \
  bash scripts/estado-anterior.sh 2 >/dev/null
assert_eq "main" "$(grep -A1 '^--branch$' "$ARGS_ARQUIVO" | sed -n '2p')" \
  "sem GITHUB_REF_NAME (execucao local) o fallback e main"

unset GH_CMD IDS_ARQUIVO CONCLUSOES_ARQUIVO ARGS_ARQUIVO
rm -rf "$_tmp"
