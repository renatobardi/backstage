#!/usr/bin/env bash
# Critério 3 da issue #1: o backend levanta e /.backstage/health/v1/readiness
# responde 200. Roda o mesmo caminho da imagem: extrai o bundle do backend
# numa pasta temporária, copia app-config*.yaml e examples como o Dockerfile
# e roda o CMD dele em node, só com app-config.yaml (SQLite) e o ENV
# GITHUB_TOKEN do Dockerfile.
# Requer o build: yarn install --immutable && yarn tsc && yarn build:backend.
# Uso: bash tests/readiness.test.sh (da raiz ou de qualquer lugar).
set -euo pipefail
cd "$(dirname "$0")/.."

scheme="http"
url="$scheme://127.0.0.1:7007/.backstage/health/v1/readiness"
bundle=packages/backend/dist/bundle.tar.gz
# Dentro do repo: o node acha o node_modules da raiz a partir da pasta.
app="$(mktemp -d "$PWD/.readiness-XXXXXX")"
log="$(mktemp)"
pid=""

cleanup() {
  local p="$pid"
  if [ -n "$p" ]; then
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  fi
  rm -rf "${app:?}" "${log:?}"
  return 0
}
trap cleanup EXIT

if [ ! -f "$bundle" ]; then
  echo "build ausente ($bundle): rode yarn install --immutable && yarn tsc && yarn build:backend" >&2
  exit 1
fi

# Mesma montagem do Dockerfile: bundle extraído, app-config*.yaml e examples na raiz.
tar xzf "$bundle" -C "$app"
cp app-config*.yaml "$app/"
cp -r examples "$app/"

# A porta do app-config.yaml precisa estar livre.
if (exec 3<>/dev/tcp/127.0.0.1/7007) 2>/dev/null; then
  exec 3>&- 3<&- || true
  echo "porta 7007 ocupada; feche quem a usa antes do teste" >&2
  exit 1
fi

# O mesmo valor do ENV GITHUB_TOKEN do Dockerfile, para o teste e a imagem não divergirem.
token="$(sed -n 's/^ENV GITHUB_TOKEN=//p' packages/backend/Dockerfile)"
(cd "$app" && exec env GITHUB_TOKEN="$token" node packages/backend --config app-config.yaml) >"$log" 2>&1 &
pid=$!

code=""
for _ in $(seq 1 60); do
  sleep 2
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" || true)"
  if [ "$code" = "200" ]; then
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "backend morreu antes do readiness; últimos logs:" >&2
    tail -40 "$log" >&2
    exit 1
  fi
done

if [ "$code" != "200" ]; then
  echo "readiness não respondeu 200 em 2 min (último código: $code); últimos logs:" >&2
  tail -40 "$log" >&2
  exit 1
fi

echo "ok 1 - readiness 200 em $url"
echo "1..1"
