#!/usr/bin/env bash
# Ramos de estado do scripts/image-smoke.sh (issue #1): readiness 200 passa;
# container que sai antes do readiness falha; readiness que nunca responde
# falha no orçamento. docker, curl e sleep são stubs no PATH, então o teste
# não sobe container nem espera de verdade.
# Uso: bash tests/image-smoke.test.sh (da raiz ou de qualquer lugar).
set -euo pipefail
cd "$(dirname "$0")/.."

n=0
ok() {
  local desc="$1"
  n=$((n + 1))
  echo "ok $n - $desc"
  return 0
}

# Sob set -e, o return 1 para o script na hora.
fail() {
  local msg="$1"
  echo "NÃO OK: $msg" >&2
  return 1
}

stub_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${stub_dir:?}"
  return 0
}
trap cleanup EXIT

# docker: run devolve um id; inspect responde o estado de SMOKE_RUNNING; logs e rm não fazem nada.
cat >"$stub_dir/docker" <<'SH'
#!/bin/sh
case "$1" in
  run) echo stub-id ;;
  inspect) echo "$SMOKE_RUNNING" ;;
esac
exit 0
SH
# curl: devolve o código HTTP de SMOKE_CODE (o script usa -w '%{http_code}').
cat >"$stub_dir/curl" <<'SH'
#!/bin/sh
echo "$SMOKE_CODE"
exit 0
SH
# sleep: não espera, para o orçamento de 90 tentativas rodar na hora.
cat >"$stub_dir/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/docker" "$stub_dir/curl" "$stub_dir/sleep"

script=scripts/image-smoke.sh
run_smoke() {
  local code="$1" running="$2"
  PATH="$stub_dir:$PATH" SMOKE_CODE="$code" SMOKE_RUNNING="$running" bash "$script" imagem-de-teste 2>&1
  return $?
}

# Ramo 1: readiness responde 200 → sai 0.
if out="$(run_smoke 200 true)"; then
  if echo "$out" | grep -qF 'readiness 200'; then
    ok "readiness 200: sai 0"
  else
    fail "readiness 200 sem a linha de confirmação; saída: $out"
  fi
else
  fail "readiness 200 devia sair 0; saída: $out"
fi

# Ramo 2: container sai antes do readiness → sai 1 na hora.
if out="$(run_smoke 000 false)"; then
  fail "container parado devia sair 1; saída: $out"
elif echo "$out" | grep -qF 'saiu antes do readiness'; then
  ok "container parado antes do readiness: sai 1"
else
  fail "container parado sem a mensagem esperada; saída: $out"
fi

# Ramo 3: container segue no ar, mas o readiness nunca responde → esgota o orçamento e sai 1.
if out="$(run_smoke 000 true)"; then
  fail "readiness sem resposta devia sair 1; saída: $out"
elif echo "$out" | grep -qF 'não respondeu 200 em 15 min'; then
  ok "readiness sem resposta: sai 1 no orçamento"
else
  fail "readiness sem resposta sem a mensagem esperada; saída: $out"
fi

echo "1..$n"
