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
: > "$IDS_ARQUIVO"
: > "$CONCLUSOES_ARQUIVO"
assert_eq "ok
ok" "$(bash scripts/estado-anterior.sh 2)" "repo recem-criado nao inventa queda"

# --- run cancelado nao vira queda ---
printf '%s\n' '111' '222' > "$IDS_ARQUIVO"
printf '%s\n' '111=cancelled' '222=success' > "$CONCLUSOES_ARQUIVO"
assert_eq "ok
ok" "$(bash scripts/estado-anterior.sh 2)" "run cancelado nao e tratado como queda"

unset GH_CMD IDS_ARQUIVO CONCLUSOES_ARQUIVO
rm -rf "$_tmp"
