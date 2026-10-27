#!/usr/bin/env bash
# Critérios 2 e 4 da issue #1: o CI constrói e publica imagem arm64 no GHCR;
# o workflow versions-bump roda uma vez por mês e abre PR.
# Uso: bash tests/ci-workflows.test.sh (da raiz ou de qualquer lugar).
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

assert_contains() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$desc"
  else
    fail "em $file falta: $needle"
  fi
  return 0
}

ci=.github/workflows/ci.yml
bump=.github/workflows/versions-bump.yml
pr_script=scripts/versions-bump-pr.sh

for f in "$ci" "$bump"; do
  if [ -f "$f" ]; then
    ok "existe: $f"
  else
    fail "arquivo ausente: $f"
  fi
done

# Critério 2: build arm64 e publicação no GHCR, só no push para a main.
assert_contains "$ci" "platforms: linux/arm64" "ci.yml constrói para linux/arm64"
assert_contains "$ci" "ghcr.io/renatobardi/backstage:latest" "ci.yml publica no GHCR (tag latest)"
assert_contains "$ci" "ghcr.io/renatobardi/backstage:sha-" "ci.yml publica tag por commit"
assert_contains "$ci" "packages: write" "ci.yml tem permissão packages: write"
assert_contains "$ci" "github.event_name == 'push' && github.ref == 'refs/heads/main'" "publicação só no push para a main"
assert_contains "$ci" "secrets.GITHUB_TOKEN" "login no GHCR com o GITHUB_TOKEN"
assert_contains "$ci" "scripts/image-smoke.sh" "ci.yml roda o smoke da imagem publicada"
assert_contains "$ci" "tests/readiness.test.sh" "ci.yml roda o teste de readiness do bundle"
assert_contains "$ci" "tests/image-smoke.test.sh" "ci.yml roda o teste dos ramos do smoke"
assert_contains "$ci" "tests/versions-bump-pr.test.sh" "ci.yml roda o teste dos ramos do bump"
assert_contains "$ci" "push: false" "PR constrói a imagem sem push (prova antes do merge)"
assert_contains "$ci" "image-pr:" "job de build da imagem no PR existe"

# Actions por SHA completo de commit, com a tag em comentário (auditoria do PR #3).
unpinned="$(grep -hE '^[[:space:]]*(- )?uses:' "$ci" "$bump" | grep -vE '@[0-9a-f]{40} # v[0-9]+' || true)"
if [ -z "$unpinned" ]; then
  ok "todas as actions pinadas por SHA completo, com a tag em comentário"
else
  fail "action sem SHA completo: $unpinned"
fi

# Critério 4: cron mensal (dia 1) e abertura de PR.
assert_contains "$bump" "schedule:" "versions-bump.yml é agendado"
assert_contains "$bump" "yarn backstage-cli versions:bump" "versions-bump.yml roda o versions:bump"
assert_contains "$bump" "pull-requests: write" "versions-bump.yml pode abrir PR"
assert_contains "$bump" "contents: write" "versions-bump.yml pode escrever branch"
assert_contains "$bump" "$pr_script" "versions-bump.yml abre o PR pelo script"

if [ -f "$pr_script" ] && grep -qF 'gh pr create' "$pr_script"; then
  ok "o script do bump cria o PR (gh pr create)"
else
  fail "o script do bump não cria PR"
fi

# O valor de --release tem que ser um dos aceitos pelo backstage-cli
# versions:bump (cli-module-migrate 0.2.2, src/commands/versions/bump.ts): uma
# versão semver, next, ou uma linha de release (main é o padrão). `line` não é
# linha de release: o workflow falhou com "No 'line' release line found" (#1).
release_re='^(next|main|[0-9]+\.[0-9]+\.[0-9]+)$'
for f in "$bump" "$pr_script"; do
  release="$(grep -oE -- '--release [A-Za-z0-9.]+' "$f" | head -1 | cut -d' ' -f2 || true)"
  if echo "$release" | grep -qE -- "$release_re"; then
    ok "$f: --release $release é valor aceito pelo backstage-cli"
  else
    fail "$f: --release '$release' não é versão, next nem main"
  fi
done

# O step do versions:bump roda yarn install (dentro do CLI). Com CI=true o yarn
# trava o lockfile (YN0028), então o step desliga a trava, e só ele.
bump_step="$(awk '/name: backstage-cli versions:bump/ {f = 1} f && /^      - / && !/versions:bump/ {exit} f' "$bump")"
if echo "$bump_step" | grep -qF "YARN_ENABLE_IMMUTABLE_INSTALLS: 'false'"; then
  ok "step versions:bump desliga YARN_ENABLE_IMMUTABLE_INSTALLS"
else
  fail "step versions:bump sem YARN_ENABLE_IMMUTABLE_INSTALLS: 'false'"
fi

# O campo cron tem 5 posições (min hora dia mês dia-da-semana); mensal =
# dia do mês 1 e mês coringa.
cron="$(grep -oE '"[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+"' "$bump" | head -1 | tr -d '"')"
if [ -n "$cron" ]; then
  ok "versions-bump.yml declara cron: $cron"
else
  fail "versions-bump.yml sem expressão cron"
fi
# read, não set --: o * do cron viraria glob contra os arquivos do diretório.
read -r _min _hora dia mes _dow <<<"$cron"
if [ "$dia" = "1" ] && [ "$mes" = "*" ]; then
  ok "cron mensal (dia do mês 1, mês *)"
else
  fail "cron não é mensal: campo dia='$dia' mês='$mes'"
fi

echo "1..$n"
