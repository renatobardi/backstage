#!/usr/bin/env bash
# Critério 1 da issue #1: o repo é só a saída do @backstage/create-app mais
# composição (Dockerfile e CI), e nenhum pacote @backstage/* é patcheado
# (ADR-0001 em renatobardi/oute-infra-ops).
# Uso: bash tests/composition.test.sh (da raiz ou de qualquer lugar).
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

assert_file() {
  local path="$1"
  if [ -f "$path" ]; then
    ok "existe: $path"
  else
    fail "arquivo ausente: $path"
  fi
  return 0
}

assert_absent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    ok "ausente: $path"
  else
    fail "presente, mas não devia: $path"
  fi
  return 0
}

# Saída do create-app e composição que a issue #1 pede.
assert_file README.md
assert_file backstage.json
assert_file app-config.yaml
assert_file app-config.production.yaml
assert_file packages/app/package.json
assert_file packages/backend/package.json
assert_file packages/backend/Dockerfile
assert_file .github/workflows/ci.yml
assert_file .github/workflows/versions-bump.yml

# O placeholder do repo vazio sai (critério: só create-app + composição).
assert_absent read.me

# backstage.json carrega a versão do app (entrada do Upgrade Helper).
if node -p "require('./backstage.json').version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "backstage.json com versão semântica"
else
  fail "backstage.json sem versão semântica"
fi

# Nenhum @backstage/* patcheado: sem protocolo patch/file/link/portal em
# package.json, sem patchedDependencies, sem patches/.
if git ls-files '*package.json' | xargs -r grep -n -E '"@backstage/[^"]*": *"(patch|portal|file|link):'; then
  fail "pacote @backstage/* aponta para patch/file/link/portal em algum package.json"
else
  ok "nenhum @backstage/* aponta para patch/file/link/portal"
fi

if grep -n 'patchedDependencies' .yarnrc.yml; then
  fail "patchedDependencies no .yarnrc.yml"
else
  ok "sem patchedDependencies no .yarnrc.yml"
fi

assert_absent patches

# resolutions da raiz não trava @backstage/* em versão própria.
if node -e '
  const r = require("./package.json").resolutions || {};
  const bad = Object.keys(r).filter(k => k.startsWith("@backstage/"));
  if (bad.length) { console.error(bad.join(" ")); process.exit(1); }
'; then
  ok "resolutions da raiz sem @backstage/*"
else
  fail "resolutions da raiz trava @backstage/*: veja a saída acima"
fi

echo "1..$n"
