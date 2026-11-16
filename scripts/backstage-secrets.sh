#!/usr/bin/env bash
# Chaves do backstage-prd: Vaultwarden -> /opt/app/.env do LXC (oute-infra-ops ADR-0010/0011/0016).
# Roda no terminal do host, como ubuntu. Nunca pelo canal dos agentes: lê o vault.
# Mantido aqui (veio do renatobardi/lab, arquivado — oute-infra-ops ADR-0012). No host fica em
#   ~/.local/bin/backstage-secrets; atualizar do Mac com:
#   scp scripts/backstage-secrets.sh oute-server:.local/bin/backstage-secrets
# O CLI é o `bw` nativo se houver; senão o da imagem local do oute-agent, com o estado em
# ~/.oute/bwcli (o mesmo dos helpers frentes/financial-control). Se o vault estiver
# trancado e não houver BW_SESSION, pede a master password no terminal (sem eco).
#
# Fonte: Nota segura de nome exato `backstage-prd`, com campos personalizados de nome
# exatamente igual a cada chave (texto ou oculto):
#   POSTGRES_PASSWORD (role app_backstage_prd do oute-supabase-db)
#   OAUTH2_PROXY_CLIENT_ID, OAUTH2_PROXY_CLIENT_SECRET, OAUTH2_PROXY_COOKIE_SECRET (Google, oute-sso)
#   GITHUB_APP_ID, GITHUB_APP_CLIENT_ID, GITHUB_APP_CLIENT_SECRET, GITHUB_APP_PRIVATE_KEY
#     (GitHub App oute-backstage; a chave é o PEM inteiro, multilinha)
#   OUTE_INFRA_OPS_CATALOG_TOKEN (leitura do catálogo pela automação, ADR-0005)
#   GITHUB_APP_WEBHOOK_SECRET (HMAC dos webhooks do GitHub App, oute-infra-ops ADR-0011)
#
# Uso: backstage-secrets --check   (diz presente/ausente por chave; não escreve nada)
#      backstage-secrets --apply   (grava no .env e recria o serviço backstage)
#
# Os valores vão por stdin (nunca argv). O receptor no LXC
# troca só essas linhas do .env (root:root 0600) com escrita atômica e preserva o resto.
set -euo pipefail

NOME=backstage-prd
ITEM=backstage-prd
CHAVES=(POSTGRES_PASSWORD OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET
  GITHUB_APP_ID GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET GITHUB_APP_PRIVATE_KEY OUTE_INFRA_OPS_CATALOG_TOKEN
  GITHUB_APP_WEBHOOK_SECRET)
PATH="$PATH:/snap/bin"

MODO=${1:-}
case "$MODO" in
  --check|--apply) ;;
  *) echo "uso: $0 --check|--apply" >&2; exit 2 ;;
esac

BW_NATIVO=$(type -P bw || true)
BW_IMAGEM=''
if [[ -z "$BW_NATIVO" ]]; then
  BW_IMAGEM=$(docker inspect --format '{{.Image}}' oute-agent 2>/dev/null) \
    || { echo "erro: sem bw nativo e sem a imagem local do oute-agent" >&2; exit 1; }
  [[ "$BW_IMAGEM" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "erro: digest inválido da imagem do CLI" >&2; exit 1; }
fi

# Segredos chegam ao CLI pelo ambiente do processo, nunca por argv nem pelo Config.Env do
# Docker: no container, as variáveis BW_* entram por stdin e o bootstrap as entrega ao bw.
bw() (
  export BW_SESSION BW_PASSWORD
  if [[ -n "$BW_NATIVO" ]]; then
    "$BW_NATIVO" "$@"
  else
    python3 -c 'import json,os,sys; json.dump({k:os.environ[k] for k in ("BW_SESSION","BW_PASSWORD") if os.environ.get(k)}, sys.stdout)' | \
    docker run --rm -i --pull never --log-driver none --entrypoint python3 \
      --add-host vault.oute.pro:100.66.254.24 --user "$(id -u):$(id -g)" \
      -e HOME=/tmp -e BITWARDENCLI_APPDATA_DIR=/bwcli \
      --mount "type=bind,src=$HOME/.oute/bwcli,dst=/bwcli" "$BW_IMAGEM" \
      -c 'import json,os,sys; os.umask(0o077); env=os.environ.copy(); env.update(json.load(sys.stdin)); os.execvpe("bw",["bw",*sys.argv[1:]],env)' "$@"
  fi
)

estado() { bw status | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }
if [[ "$(estado)" != unlocked ]]; then
  [[ -r /dev/tty ]] || { echo "erro: vault trancado e sem terminal para pedir a senha" >&2; exit 1; }
  read -rs -p "master password do Vaultwarden: " BW_PASSWORD </dev/tty; echo >&2
  BW_SESSION=$(bw unlock --raw --passwordenv BW_PASSWORD) || { unset BW_PASSWORD; echo "erro: unlock falhou" >&2; exit 1; }
  unset BW_PASSWORD
  [[ "$(estado)" = unlocked ]] || { echo "erro: vault continua trancado" >&2; exit 1; }
fi
bw sync >/dev/null

# Extrai os campos do item e emite KEY=valor (uma linha por chave, \n escapado) em stdout
# só para o pipe; --check imprime presente/ausente em stderr e nada em stdout.
extrai() {
  bw list items --search "$ITEM" | python3 -c '
import json, re, sys
modo, item, chaves = sys.argv[1], sys.argv[2], sys.argv[3:]
itens = [i for i in json.load(sys.stdin) if i.get("name") == item]
if len(itens) != 1:
    sys.exit(f"erro: esperava 1 item de nome exato {item!r}, achei {len(itens)}")
campos = {}
for f in itens[0].get("fields") or []:
    nome = f.get("name")
    if nome in campos:
        sys.exit(f"erro: campo repetido {nome!r}")
    campos[nome] = f.get("value")
falta = []
for k in chaves:
    v = campos.get(k)
    # Só a chave privada (PEM) é multilinha; as demais são uma linha só.
    multi = k == "GITHUB_APP_PRIVATE_KEY"
    ok = isinstance(v, str) and v.strip() != "" and (multi or ("\n" not in v and "\r" not in v))
    if ok and multi:
        ok = re.fullmatch(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.+-----END [A-Z ]*PRIVATE KEY-----", v.strip(), re.S) is not None
    estado = "presente" if ok else "ausente"
    print(f"    {k}: {estado}", file=sys.stderr)
    if not ok:
        falta.append(k)
if falta:
    sys.exit(1)
if modo == "--apply":
    for k in chaves:
        v = campos[k].strip()
        if k == "GITHUB_APP_PRIVATE_KEY":
            # O campo do Vaultwarden é de uma linha: o PEM chega sem as quebras (ou com
            # espaços no lugar). Remonta: cabeçalho, corpo base64 em linhas de 64, rodapé.
            m = re.fullmatch(r"(-----BEGIN [A-Z ]+-----)(.*?)(-----END [A-Z ]+-----)", v, re.S)
            corpo = re.sub(r"[^A-Za-z0-9+/=]", "", m.group(2))
            v = chr(10).join([m.group(1)] + [corpo[i:i + 64] for i in range(0, len(corpo), 64)] + [m.group(3)])
            # Formato do .env do compose: entre aspas duplas, \n vira quebra de linha.
            q, b = chr(34), chr(92)
            v = q + v.replace(chr(13), "").replace(b, b + b).replace(q, b + q).replace(chr(10), b + "n") + b + "n" + q
        print(f"{k}={v}")
' "$MODO" "$ITEM" "${CHAVES[@]}"
}

echo "==> $ITEM no Vaultwarden"
if [[ "$MODO" = --check ]]; then
  extrai >/dev/null
  lxc exec "$NOME" -- test -f /opt/app/.env </dev/null && echo "    /opt/app/.env: existe" \
    || echo "    /opt/app/.env: ausente (rode o install-backstage-prd.sh antes)"
  echo "--check: nada foi alterado"
  exit 0
fi

# Receptor: lê KEY=valor do stdin, troca as linhas no .env, escrita atômica 0600.
RECEPTOR='
import os, sys, tempfile
alvo = "/opt/app/.env"
st = os.stat(alvo, follow_symlinks=False)
import stat
if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or (st.st_mode & 0o077):
    sys.exit("erro: .env precisa ser regular, root, 0600")
novos = dict(l.split("=", 1) for l in sys.stdin.read().splitlines() if l)
linhas = [l for l in open(alvo).read().splitlines() if l.split("=", 1)[0] not in novos]
linhas += [f"{k}={v}" for k, v in novos.items()]
fd, tmp = tempfile.mkstemp(dir="/opt/app", prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(linhas) + "\n"); f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o600)
os.replace(tmp, alvo)
print(f"    .env: {len(novos)} chaves gravadas")
'
# Extrai antes de abrir o LXC: com uma chave ausente ou inválida o script para aqui e o
# receptor nem roda (num pipe ele começaria antes do extrator falhar).
dados=$(extrai)
printf '%s\n' "$dados" | lxc exec "$NOME" -- python3 -c "$RECEPTOR"
unset dados

echo "==> sobe/recria a stack (deploy/compose.yaml) e espera o backstage healthy"
lxc exec "$NOME" -- bash -lc 'cd /opt/app && docker compose -f deploy/compose.yaml --env-file .env up -d --force-recreate >/dev/null 2>&1
for i in $(seq 1 60); do
  [[ "$(docker inspect -f "{{.State.Health.Status}}" backstage-backstage-1)" = healthy ]] && { echo "    healthy"; exit 0; }
  sleep 3
done
echo "FAIL: backstage não ficou healthy (docker compose logs backstage)" >&2; exit 1' </dev/null
