#!/usr/bin/env bash
# Ramo de estado do scripts/versions-bump-pr.sh (issue #1): sem mudanças não
# abre PR; PR do dia já aberto não abre outro. O script roda num repo git
# temporário (cópia dele), então o resultado não depende da árvore de quem
# roda. O gh é um stub; o ramo que cria branch só roda na CI.
# Uso: bash tests/versions-bump-pr.test.sh (da raiz ou de qualquer lugar).
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
repo="$(mktemp -d)"
printf '#!/bin/sh\necho 1\n' >"$stub_dir/gh"
chmod +x "$stub_dir/gh"
cleanup() {
  rm -rf "${stub_dir:?}" "${repo:?}"
  return 0
}
trap cleanup EXIT

# Repo temporário com o script e o backstage.json (o script lê a versão dele).
mkdir "$repo/scripts"
cp scripts/versions-bump-pr.sh "$repo/scripts/"
cp backstage.json "$repo/"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=teste -c user.email=teste@example.invalid commit -qm base

script="$repo/scripts/versions-bump-pr.sh"

# Ramo 1: árvore limpa depois do bump → avisa e não abre PR.
out="$(bash "$script" 2>&1)"
if echo "$out" | grep -qF 'sem PR'; then
  ok "árvore limpa: não abre PR"
else
  fail "árvore limpa devia pular o PR; saída: $out"
fi

# Ramo 2: bump mudou algo, mas o PR do dia já existe → não abre outro.
branches_before="$(git -C "$repo" branch --list 'chore/versions-bump-*' | wc -l)"
touch "$repo/probe-sujo"
out="$(PATH="$stub_dir:$PATH" bash "$script" 2>&1)"
branches_after="$(git -C "$repo" branch --list 'chore/versions-bump-*' | wc -l)"
if echo "$out" | grep -qF 'já está aberto'; then
  ok "PR do dia já aberto: não abre outro"
else
  fail "PR existente devia ser pulado; saída: $out"
fi
if [ "$branches_before" = "$branches_after" ]; then
  ok "nenhum branch criado nos dois ramos"
else
  fail "o script criou branch ($branches_before -> $branches_after)"
fi

echo "1..$n"
