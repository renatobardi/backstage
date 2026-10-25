#!/usr/bin/env bash
# Abre o PR mensal de versions:bump (ADR-0001). Chamado pelo workflow
# .github/workflows/versions-bump.yml, que roda o bump antes deste script.
# Saída 0: PR aberto, ou nada a fazer (sem mudanças / PR já aberto).
set -euo pipefail
cd "$(dirname "$0")/.."

# Sem mudanças depois do versions:bump: nada a fazer.
main() {
  local branch date from to body
  if git diff --quiet && [ -z "$(git status --porcelain)" ]; then
    echo "versions:bump não mudou nada; sem PR."
    return 0
  fi
  date="$(date -u +%F)"
  branch="chore/versions-bump-$date"
  if [ "$(gh pr list --head "$branch" --state open --json number --jq 'length')" != "0" ]; then
    echo "PR do bump de $date já está aberto (branch $branch); sem PR novo."
    return 0
  fi
  from="${FROM_VERSION:?FROM_VERSION não definida}"
  to="$(node -p "require('./backstage.json').version")"
  body="$(mktemp)"
  cat >"$body" <<EOF
Bump mensal das dependências \`@backstage/*\` (ADR-0001 em renatobardi/oute-infra-ops).

- \`yarn backstage-cli versions:bump --release line\`: $from → $to.
- Diff de dependências: os arquivos deste PR.
- Diff do template (Upgrade Helper), a aplicar antes de fazer merge:
  https://backstage.github.io/upgrade-helper/?from=$from&to=$to
EOF
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git checkout -b "$branch"
  git add -A
  git commit -m "chore(deps): versions:bump mensal $date (backstage $from -> $to)"
  git push origin "$branch"
  gh pr create \
    --title "chore(deps): versions:bump mensal $date (backstage $from -> $to)" \
    --body-file "$body" \
    --base main
  rm -f "${body:?}"
  return 0
}

main "$@"
