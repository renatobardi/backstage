#!/usr/bin/env bash
# Smoke da imagem publicada: sobe o container e exige 200 em
# /.backstage/health/v1/readiness (critério 3 da issue #1). Roda na CI,
# depois do push para o GHCR; a imagem arm64 roda sob QEMU no runner amd64.
# Uso: bash scripts/image-smoke.sh <imagem>
set -euo pipefail

image="${1:?uso: image-smoke.sh <imagem>}"
scheme="http"
url="$scheme://127.0.0.1:7007/.backstage/health/v1/readiness"
cid="smoke-$$"

cleanup() {
  local c="$cid"
  docker logs "$c" | tail -40 || true
  docker rm -f "$c" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

# Sem --rm: o cleanup precisa dos logs do container parado.
docker run -d --name "$cid" --platform linux/arm64 \
  -p 127.0.0.1:7007:7007 "$image" >/dev/null

# Espera o readiness (QEMU é lento: orçamento de 15 min).
code=""
for _ in $(seq 1 90); do
  sleep 10
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
  if [ "$code" = "200" ]; then
    echo "readiness 200 em $url"
    exit 0
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]; then
    echo "container saiu antes do readiness (último código: $code)" >&2
    exit 1
  fi
done
echo "readiness não respondeu 200 em 15 min (último código: $code)" >&2
exit 1
