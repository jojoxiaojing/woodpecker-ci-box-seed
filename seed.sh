#!/usr/bin/env bash
# seed.sh - builds ~/ci-box: Forgejo + Woodpecker v3.12.0 (SQLite) + 3 docker agents,
# ~20 repos, a few thousand pipelines of history, secrets, crons, and live traffic.
# Needs: bash, docker (compose v2), curl, git, python3 (python3 only on the host side
# for small JSON parsing; the history generator runs in a python container).
set -euo pipefail

CI_BOX="${CI_BOX:-$HOME/ci-box}"
TRAFFIC_DIR="${TRAFFIC_DIR:-$HOME/.ci-traffic}"
PROJECT="${PROJECT:-ci-box}"
FORGEJO_PORT="${FORGEJO_PORT:-3000}"
WP_PORT="${WP_PORT:-8000}"
PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
REAL_TARGET="${REAL_TARGET:-150}"          # real pipelines to build during the seed
REAL_BUDGET_S="${REAL_BUDGET_S:-420}"      # max seconds spent on real builds
SYNTH_TOTAL="${SYNTH_TOTAL:-2900}"         # synthetic (inserted) pipelines
SYNTH_LOG_LINES="${SYNTH_LOG_LINES:-200000}"

FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:11.0.16"
WP_SERVER_IMAGE="woodpeckerci/woodpecker-server:v3.12.0"
WP_AGENT_IMAGE="woodpeckerci/woodpecker-agent:v3.12.0"
PG_IMAGE="postgres:16"
PY_IMAGE="python:3.12-alpine"
GIT_IMAGE="alpine/git:2.47.2"

ADMIN_USER=forge-admin;  ADMIN_PASS='Fj-admin-2291'
ALICE_PASS='alice-ci-4471'; BOB_PASS='bob-ci-8812'

FJ="http://127.0.0.1:${FORGEJO_PORT}"
WP="http://127.0.0.1:${WP_PORT}"
WORK="$(mktemp -d /tmp/seed.XXXXXX)"
T0=$(date +%s)
log() { printf '[seed %4ss] %s\n' "$(( $(date +%s) - T0 ))" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -e "$CI_BOX" ] && die "$CI_BOX already exists"
command -v docker >/dev/null && docker compose version >/dev/null || die "docker compose v2 needed"
for c in curl git python3; do command -v $c >/dev/null || die "$c needed"; done

jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

mkdir -p "$CI_BOX"/{data/forgejo,deploys} "$TRAFFIC_DIR"
touch "$CI_BOX/deploys/markers.log"; chmod 777 "$CI_BOX/deploys"; chmod 666 "$CI_BOX/deploys/markers.log"
cd "$CI_BOX"

AGENT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
PG_PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > .env <<EOF
FORGEJO_PORT=${FORGEJO_PORT}
WP_PORT=${WP_PORT}
WOODPECKER_HOST=http://${PUBLIC_HOST}:${WP_PORT}
WOODPECKER_AGENT_SECRET=${AGENT_SECRET}
WOODPECKER_FORGEJO_CLIENT=
WOODPECKER_FORGEJO_SECRET=
POSTGRES_PASSWORD=${PG_PASS}
EOF
chmod 600 .env

cat > docker-compose.yml <<'EOF'
name: ci-box

services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:11.0.16
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      FORGEJO__database__DB_TYPE: sqlite3
      FORGEJO__server__DOMAIN: forgejo
      FORGEJO__server__HTTP_PORT: "3000"
      FORGEJO__server__ROOT_URL: http://forgejo:3000/
      FORGEJO__server__SSH_DOMAIN: forgejo
      FORGEJO__server__DISABLE_SSH: "true"
      FORGEJO__security__INSTALL_LOCK: "true"
      FORGEJO__service__DISABLE_REGISTRATION: "true"
      FORGEJO__repository__DEFAULT_BRANCH: main
      FORGEJO__webhook__ALLOWED_HOST_LIST: "*"
      FORGEJO__webhook__DELIVER_TIMEOUT: "10"
      FORGEJO__log__LEVEL: Warn
    volumes:
      - ./data/forgejo:/data
    ports:
      - "${FORGEJO_PORT}:3000"

  woodpecker-server:
    image: woodpeckerci/woodpecker-server:v3.12.0
    restart: unless-stopped
    depends_on: [forgejo]
    environment:
      WOODPECKER_HOST: ${WOODPECKER_HOST}
      WOODPECKER_EXPERT_WEBHOOK_HOST: http://woodpecker-server:8000
      WOODPECKER_OPEN: "true"
      WOODPECKER_ADMIN: alice
      WOODPECKER_FORGEJO: "true"
      WOODPECKER_FORGEJO_URL: http://forgejo:3000
      WOODPECKER_FORGEJO_CLIENT: ${WOODPECKER_FORGEJO_CLIENT}
      WOODPECKER_FORGEJO_SECRET: ${WOODPECKER_FORGEJO_SECRET}
      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET}
      WOODPECKER_DATABASE_DRIVER: sqlite3
      WOODPECKER_DATABASE_DATASOURCE: /var/lib/woodpecker/woodpecker.sqlite
      WOODPECKER_LOG_LEVEL: info
    volumes:
      - woodpecker-server-data:/var/lib/woodpecker
    ports:
      - "${WP_PORT}:8000"

  agent-1: &agent
    image: woodpeckerci/woodpecker-agent:v3.12.0
    restart: unless-stopped
    command: agent
    depends_on: [woodpecker-server]
    environment: &agentenv
      WOODPECKER_SERVER: woodpecker-server:9000
      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET}
      WOODPECKER_MAX_WORKFLOWS: "2"
      WOODPECKER_BACKEND: docker
      WOODPECKER_BACKEND_DOCKER_NETWORK: ci-box_default
      WOODPECKER_HOSTNAME: agent-1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - agent-1-config:/etc/woodpecker

  agent-2:
    <<: *agent
    environment:
      <<: *agentenv
      WOODPECKER_HOSTNAME: agent-2
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - agent-2-config:/etc/woodpecker

  agent-3:
    <<: *agent
    environment:
      <<: *agentenv
      WOODPECKER_HOSTNAME: agent-3
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - agent-3-config:/etc/woodpecker

  # not wired up yet - target DB for woodpecker (see NOTES.txt)
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: woodpecker
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: woodpecker
    volumes:
      - postgres-data:/var/lib/postgresql/data

volumes:
  woodpecker-server-data:
  agent-1-config:
  agent-2-config:
  agent-3-config:
  postgres-data:
EOF
if [ "$PROJECT" != "ci-box" ]; then
  sed -i "s/^name: ci-box/name: ${PROJECT}/; s/ci-box_default/${PROJECT}_default/" docker-compose.yml
fi
DC() { docker compose --project-directory "$CI_BOX" "$@"; }

log "pulling images"
DC pull -q
docker pull -q "$PY_IMAGE" >/dev/null; docker pull -q alpine:3.20 >/dev/null

# ---------------------------------------------------------------- forgejo
log "starting forgejo + postgres"
DC up -d forgejo postgres
for i in $(seq 1 90); do curl -fs "$FJ/api/healthz" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "$FJ/api/healthz" >/dev/null || die "forgejo did not come up"

DC exec -T -u git forgejo forgejo admin user create --admin --username "$ADMIN_USER" \
  --password "$ADMIN_PASS" --email admin@ci-box.lan --must-change-password=false >/dev/null
fj() { # fj METHOD PATH [json]  (admin basic auth)
  curl -sS --fail-with-body -u "$ADMIN_USER:$ADMIN_PASS" -X "$1" -H 'Content-Type: application/json' "$FJ/api/v1$2" ${3:+-d "$3"}; }
for u in alice:"$ALICE_PASS" bob:"$BOB_PASS"; do
  n=${u%%:*}; p=${u#*:}
  fj POST /admin/users "{\"username\":\"$n\",\"email\":\"$n@ci-box.lan\",\"password\":\"$p\",\"must_change_password\":false,\"full_name\":\"${n^}\"}" >/dev/null
done
ALICE_FJ_TOKEN=$(curl -sS --fail-with-body -u "alice:$ALICE_PASS" -H 'Content-Type: application/json' \
  -d '{"name":"seed","scopes":["all"]}' "$FJ/api/v1/users/alice/tokens" | jget 'd["sha1"]')
BOB_FJ_TOKEN=$(curl -sS --fail-with-body -u "bob:$BOB_PASS" -H 'Content-Type: application/json' \
  -d '{"name":"laptop","scopes":["all"]}' "$FJ/api/v1/users/bob/tokens" | jget 'd["sha1"]')
fa() { curl -sS --fail-with-body -H "Authorization: token $ALICE_FJ_TOKEN" -X "$1" -H 'Content-Type: application/json' "$FJ/api/v1$2" ${3:+-d "$3"}; }

LONG_ORG="customer-integrations-partner-onboarding"
for o in platform web ops data mobile "$LONG_ORG"; do
  fa POST /orgs "{\"username\":\"$o\",\"visibility\":\"public\"}" >/dev/null
done

# owner/name:kind[:sha256]
REPOS="
platform/api-gateway:std
platform/auth-service:std
platform/billing-worker:secret
platform/notification-hub:std
platform/shared-libs:multi
platform/config-registry:std:sha256
web/storefront:multi
web/admin-dashboard:std
web/docs-site:std
ops/release-train:deploy
ops/infra-terraform:secret
ops/ansible-playbooks:std
data/etl-nightly:biglog
data/metrics-exporter:std
data/lakehouse-schemas:std:sha256
mobile/ios-app:std
mobile/android-app:multi
alice/dotfiles:std
bob/playground:std
${LONG_ORG}/legacy-payment-reconciliation-batch-processor-service-v2:std
${LONG_ORG}/partner-webhook-relay-and-event-normalization-gateway:multi
"
log "creating repos"
for spec in $REPOS; do
  full=${spec%%:*}; rest=${spec#*:}; owner=${full%%/*}; name=${full#*/}
  fmt=sha1; [[ "$rest" == *:sha256 ]] && fmt=sha256
  body="{\"name\":\"$name\",\"auto_init\":true,\"default_branch\":\"main\",\"object_format_name\":\"$fmt\",\"description\":\"$name\"}"
  case $owner in
    alice) fa POST /user/repos "$body" >/dev/null ;;
    bob)   curl -sS --fail-with-body -H "Authorization: token $BOB_FJ_TOKEN" -H 'Content-Type: application/json' -d "$body" "$FJ/api/v1/user/repos" >/dev/null
           curl -sS --fail-with-body -H "Authorization: token $BOB_FJ_TOKEN" -H 'Content-Type: application/json' -X PUT -d '{"permission":"admin"}' "$FJ/api/v1/repos/$full/collaborators/alice" >/dev/null ;;
    *)     fa POST "/orgs/$owner/repos" "$body" >/dev/null
           fa PUT "/repos/$full/collaborators/bob" '{"permission":"write"}' >/dev/null ;;
  esac
done

# ---------------------------------------------------------------- pipeline files
pipeline_std() { cat <<'EOF'
when:
  - event: [push, pull_request, manual, cron]

steps:
  - name: build
    image: alpine:3.20
    commands:
      - printf '\033[1;34m==>\033[0m building %s @ %s\n' "$CI_REPO" "$CI_COMMIT_SHA"
      - for i in $(seq 1 40); do printf '\033[32m[ok]\033[0m compile unit %03d\n' $i; done
      - printf 'legacy encoder output -> caf\xe9 na\xefve \xff\xfe\x80 done\n'
      - printf '\033[33mwarning:\033[0m deprecated flag --fast used\n'
  - name: test
    image: alpine:3.20
    commands:
      - for i in $(seq 1 30); do printf '\033[36mPASS\033[0m test_case_%02d (%dms)\n' $i $((RANDOM % 900)); done
      - sh -c 'test $((RANDOM % 9)) -ne 0' || { printf '\033[31mFAIL\033[0m flaky test_case_17\n'; exit 1; }
EOF
}
pipeline_secret() { cat <<'EOF'
when:
  - event: [push, manual, cron]

steps:
  - name: build
    image: alpine:3.20
    commands:
      - printf '\033[1;34m==>\033[0m build %s\n' "$CI_COMMIT_SHA"
      - for i in $(seq 1 25); do printf 'pkg %02d \033[32mresolved\033[0m\n' $i; done
  - name: publish
    image: alpine:3.20
    environment:
      REGISTRY_TOKEN:
        from_secret: registry_token
      SLACK_WEBHOOK:
        from_secret: slack_webhook
    commands:
      - test -n "$REGISTRY_TOKEN" && echo "token present (len ${#REGISTRY_TOKEN})"
      - printf '\033[35mpublish\033[0m artifact-%s.tar.gz\n' "${CI_COMMIT_SHA:0:8}"
EOF
}
pipeline_biglog() { cat <<'EOF'
when:
  - event: [push, manual, cron]

steps:
  - name: extract
    image: alpine:3.20
    commands:
      - printf '\033[1m[etl]\033[0m extracting partitions\n'
      - for i in $(seq 1 24000); do echo "row $i|2024-01-01T00:00:00Z|customer_$((i % 997))|amount=$((i * 7 % 10000))|status=settled|region=eu-west-1"; done
      - printf 'bad bytes in partition -> \xc3\x28 \xa0\xa1 \xf0\x28\x8c\x28\n'
  - name: load
    image: alpine:3.20
    commands:
      - printf '\033[32mloaded\033[0m 24000 rows\n'
EOF
}
pipeline_deploy() { cat <<EOF
when:
  - event: [push, manual, cron]
    branch: main

steps:
  - name: build
    image: alpine:3.20
    commands:
      - printf '\\033[1;34m==>\\033[0m building release %s\\n' "\$CI_COMMIT_SHA"
      - for i in \$(seq 1 20); do printf 'layer %02d \\033[32mpushed\\033[0m\\n' \$i; done
  - name: deploy
    image: alpine:3.20
    environment:
      DEPLOY_KEY:
        from_secret: deploy_key
    volumes:
      - ${CI_BOX}/deploys:/deploys
    commands:
      - printf '\\033[1;33mdeploying\\033[0m %s build-%s to production\\n' "\$CI_REPO" "\$CI_PIPELINE_NUMBER"
      - 'T=\$((180 + \$(od -An -N1 -tu1 /dev/urandom) % 120)); i=0; while [ \$i -lt \$T ]; do sleep 15; i=\$((i+15)); echo "rollout \$i/\$T s"; done'
      - echo "\$CI_REPO \$CI_PIPELINE_NUMBER \$CI_COMMIT_SHA" >> /deploys/markers.log
      - printf '\\033[32mdeployed\\033[0m\\n'
EOF
}
multi_build() { cat <<'EOF'
when:
  - event: [push, pull_request, manual, cron]

steps:
  - name: compile
    image: alpine:3.20
    commands:
      - printf '\033[1;34m[build]\033[0m %s\n' "$CI_COMMIT_SHA"
      - for i in $(seq 1 30); do printf '  \033[32mCC\033[0m src/module_%02d.c\n' $i; done
      - printf 'locale noise -> \xe4\xf6\xfc \xa7\n'
EOF
}
multi_test() { cat <<'EOF'
when:
  - event: [push, pull_request, manual, cron]

depends_on: [build]

steps:
  - name: unit
    image: alpine:3.20
    commands:
      - for i in $(seq 1 25); do printf '\033[36mok\033[0m   pkg/%02d\t0.%03ds\n' $i $((RANDOM % 999)); done
  - name: lint
    image: alpine:3.20
    commands:
      - printf '\033[33m3 warnings\033[0m\n'
EOF
}
multi_package() { cat <<'EOF'
when:
  - event: [push, manual]

depends_on: [build, test]

steps:
  - name: package
    image: alpine:3.20
    commands:
      - printf '\033[35mpackaging\033[0m %s\n' "${CI_COMMIT_SHA:0:10}"
EOF
}

GIT_ENV=(-c user.name=alice -c user.email=alice@ci-box.lan -c init.defaultBranch=main)
log "pushing pipeline configs"
for spec in $REPOS; do
  full=${spec%%:*}; rest=${spec#*:}; kind=${rest%%:*}
  d="$WORK/repos/$full"; mkdir -p "$(dirname "$d")"
  git "${GIT_ENV[@]}" clone -q "http://alice:${ALICE_FJ_TOKEN}@127.0.0.1:${FORGEJO_PORT}/$full.git" "$d"
  case $kind in
    std)    pipeline_std > "$d/.woodpecker.yml" ;;
    secret) pipeline_secret > "$d/.woodpecker.yml" ;;
    biglog) pipeline_biglog > "$d/.woodpecker.yml" ;;
    deploy) pipeline_deploy > "$d/.woodpecker.yml" ;;
    multi)  mkdir -p "$d/.woodpecker"; multi_build > "$d/.woodpecker/build.yml"
            multi_test > "$d/.woodpecker/test.yml"; multi_package > "$d/.woodpecker/package.yml" ;;
  esac
  printf '# %s\n\nService repository.\n' "${full#*/}" > "$d/README.md"
  echo "0" > "$d/VERSION"
  git -C "$d" "${GIT_ENV[@]}" add -A
  git -C "$d" "${GIT_ENV[@]}" commit -qm "ci: add woodpecker pipeline"
  git -C "$d" "${GIT_ENV[@]}" push -q origin main
done

# ---------------------------------------------------------------- oauth app + woodpecker
log "creating oauth app, starting woodpecker"
APP=$(fj POST /user/applications/oauth2 "{\"name\":\"Woodpecker CI\",\"redirect_uris\":[\"http://${PUBLIC_HOST}:${WP_PORT}/authorize\"],\"confidential_client\":true}")
CID=$(echo "$APP" | jget 'd["client_id"]'); CSEC=$(echo "$APP" | jget 'd["client_secret"]')
sed -i "s/^WOODPECKER_FORGEJO_CLIENT=.*/WOODPECKER_FORGEJO_CLIENT=$CID/; s/^WOODPECKER_FORGEJO_SECRET=.*/WOODPECKER_FORGEJO_SECRET=$CSEC/" .env
DC up -d woodpecker-server
for i in $(seq 1 60); do curl -fs "$WP/healthz" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "$WP/healthz" >/dev/null || die "woodpecker did not come up"

# Scripted browser login: woodpecker /authorize -> forgejo login -> grant -> callback
wp_login() { # wp_login user pass -> prints woodpecker personal token
  local u=$1 p=$2 fjar="$WORK/fj-$1.jar" wjar="$WORK/wp-$1.jar" loc page csrf
  loc=$(curl -s -o /dev/null -c "$wjar" -b "$wjar" -w '%{redirect_url}' "$WP/authorize")
  [ -n "$loc" ] || die "no redirect from woodpecker /authorize"
  loc=${loc/http:\/\/forgejo:3000/$FJ}
  page=$(curl -s -c "$fjar" -b "$fjar" "$FJ/user/login")
  csrf=$(printf '%s' "$page" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')
  curl -s -o /dev/null -c "$fjar" -b "$fjar" --data-urlencode "_csrf=$csrf" \
    --data-urlencode "user_name=$u" --data-urlencode "password=$p" "$FJ/user/login"
  page=$(curl -s -c "$fjar" -b "$fjar" -w '\n%{http_code} %{redirect_url}' "$loc")
  local code_line; code_line=$(printf '%s' "$page" | tail -1)
  local cb
  if [[ "$code_line" == 30* ]]; then cb=${code_line#* }
  else
    local form; form=$(printf '%s' "$page" | python3 -c '
import sys,re,html
s=sys.stdin.read()
f=re.search(r"<form[^>]*action=\"[^\"]*/login/oauth/grant\"[^>]*>(.*?)</form>",s,re.S)
assert f, "grant form not found"
for n,v in re.findall(r"<input[^>]*name=\"([^\"]+)\"[^>]*value=\"([^\"]*)\"",f.group(1)):
    print(n+"="+html.unescape(v))
')
    local args=(); while IFS= read -r kv; do args+=(--data-urlencode "$kv"); done <<<"$form"
    cb=$(curl -s -o /dev/null -c "$fjar" -b "$fjar" -w '%{redirect_url}' "${args[@]}" --data-urlencode "granted=true" "$FJ/login/oauth/grant")
  fi
  [[ "$cb" == *"/authorize?"* ]] || die "oauth grant did not redirect back to woodpecker ($cb)"
  cb=${cb/http:\/\/${PUBLIC_HOST}:${WP_PORT}/$WP}
  curl -s -o /dev/null -c "$wjar" -b "$wjar" "$cb"
  csrf=$(curl -s -b "$wjar" "$WP/web-config.js" | grep -o 'WOODPECKER_CSRF = "[^"]*"' | sed 's/.*= "//; s/"$//')
  curl -sS --fail-with-body -b "$wjar" -X POST -H "X-CSRF-TOKEN: $csrf" "$WP/api/user/token"
}
WP_TOKEN=$(wp_login alice "$ALICE_PASS"); [ ${#WP_TOKEN} -gt 20 ] || die "alice woodpecker login failed"
BOB_WP_TOKEN=$(wp_login bob "$BOB_PASS"); [ ${#BOB_WP_TOKEN} -gt 20 ] || die "bob woodpecker login failed"
log "woodpecker logins done"
wpa() { curl -sS --fail-with-body -H "Authorization: Bearer $WP_TOKEN" -X "$1" -H 'Content-Type: application/json' "$WP/api$2" ${3:+-d "$3"}; }

DC up -d agent-1 agent-2 agent-3

declare -A WPID
for spec in $REPOS; do
  full=${spec%%:*}
  rid=$(fa GET "/repos/$full" | jget 'd["id"]')
  if [[ $full == bob/* ]]; then
    id=$(curl -sS --fail-with-body -H "Authorization: Bearer $BOB_WP_TOKEN" -X POST "$WP/api/repos?forge_remote_id=$rid" | jget 'd["id"]')
  else
    id=$(wpa POST "/repos?forge_remote_id=$rid" | jget 'd["id"]')
  fi
  WPID[$full]=$id
done
log "activated ${#WPID[@]} repos"
# deploy repo needs host volume -> trusted
wpa PATCH "/repos/${WPID[ops/release-train]}" '{"trusted":{"volumes":true,"security":false,"network":false}}' >/dev/null

# secrets
sec() { wpa POST "/repos/${WPID[$1]}/secrets" "{\"name\":\"$2\",\"value\":\"$3\",\"events\":[\"push\",\"manual\",\"cron\",\"tag\"]}" >/dev/null; }
sec platform/billing-worker registry_token "rg_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sec platform/billing-worker slack_webhook "https://hooks.slack.example/T000/B000/$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sec ops/infra-terraform registry_token "rg_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sec ops/infra-terraform slack_webhook "https://hooks.slack.example/T000/B111/x"
sec ops/release-train deploy_key "-----BEGIN OPENSSH PRIVATE KEY-----\\nb3BlbnNzaC1rZXktdjEAAAAA$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')\\n-----END OPENSSH PRIVATE KEY-----"
wpa POST /orgs/$(wpa GET "/repos/${WPID[platform/api-gateway]}" | jget 'd["org_id"]')/secrets \
  '{"name":"sonar_token","value":"sq_0f9e8d7c6b5a","events":["push","pull_request"]}' >/dev/null || true

# ---------------------------------------------------------------- real builds
log "real builds: target $REAL_TARGET pipelines, budget ${REAL_BUDGET_S}s"
REPO_LIST=(); for spec in $REPOS; do f=${spec%%:*}; [ "$f" = ops/release-train ] || REPO_LIST+=("$f"); done
push_commit() { # repo [branch]
  local full=$1 br=${2:-main} d="$WORK/repos/$1"
  git -C "$d" "${GIT_ENV[@]}" checkout -q -B "$br" 2>/dev/null
  echo "$(date +%s%N)" > "$d/VERSION"
  git -C "$d" "${GIT_ENV[@]}" commit -qam "$(shuf -n1 -e 'fix: handle nil config' 'feat: add retry budget' 'chore: bump deps' 'refactor: split handler' 'docs: update runbook' 'perf: cache lookups' 'test: cover edge case')"
  git -C "$d" "${GIT_ENV[@]}" push -q origin "$br" 2>/dev/null || true
  git -C "$d" "${GIT_ENV[@]}" checkout -q main 2>/dev/null
}
count_pipelines() { local n=0; for f in "${!WPID[@]}"; do
  c=$(wpa GET "/repos/${WPID[$f]}/pipelines?perPage=50" | python3 -c 'import sys,json;print(len(json.load(sys.stdin) or []))'); n=$((n+c)); done; echo $n; }
queue_len() { wpa GET /queue/info | python3 -c 'import sys,json;d=json.load(sys.stdin);s=d.get("stats",{});print(s.get("pending_count",0)+s.get("waiting_on_deps_count",0)+s.get("running_count",0))'; }
START=$(date +%s); made=0
push_commit ops/release-train; made=$((made+1))
while [ $made -lt "$REAL_TARGET" ] && [ $(( $(date +%s) - START )) -lt "$REAL_BUDGET_S" ]; do
  if [ "$(queue_len)" -gt 14 ]; then sleep 3; continue; fi
  r=${REPO_LIST[$((RANDOM % ${#REPO_LIST[@]}))]}
  case $((RANDOM % 4)) in
    0) wpa POST "/repos/${WPID[$r]}/pipelines" '{"branch":"main"}' >/dev/null || true ;;
    1) push_commit "$r" "feature/$(shuf -n1 -e login cache metrics retry ui-tweaks)" ;;
    *) push_commit "$r" ;;
  esac
  made=$((made+1))
done
log "triggered $made real pipelines; waiting for queue to drain"
for i in $(seq 1 100); do q=$(queue_len); [ "$q" -eq 0 ] && break; sleep 5; done
log "queue now $(queue_len)"

# a few user-deleted pipelines (id gaps in real data too)
for f in web/docs-site mobile/ios-app; do
  n=$(wpa GET "/repos/${WPID[$f]}/pipelines?perPage=5" | python3 -c 'import sys,json;d=json.load(sys.stdin) or [];print(d[-1]["number"] if d else "")')
  [ -n "$n" ] && wpa DELETE "/repos/${WPID[$f]}/pipelines/$n" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------- synthetic history
log "stopping server, generating synthetic history"
DC stop agent-1 agent-2 agent-3 >/dev/null 2>&1
DC stop woodpecker-server >/dev/null 2>&1
cat > "$WORK/gen_history.py" <<'PYEOF'
import sqlite3, random, sys, time, json, hashlib
random.seed(20251122)
db = sqlite3.connect(sys.argv[1]); TOTAL = int(sys.argv[2]); LINES = int(sys.argv[3])
db.row_factory = sqlite3.Row
cols = lambda t: [r[1] for r in db.execute(f"PRAGMA table_info({t})")]
PC, WC, SC, LC = cols("pipelines"), cols("workflows"), cols("steps"), cols("log_entries")
repos = [r["repo_id"] for r in db.execute("SELECT DISTINCT repo_id FROM pipelines")]
tmpl = {}
for p in db.execute("SELECT * FROM pipelines WHERE status IN ('success','failure') ORDER BY id"):
    tmpl.setdefault(p["repo_id"], []).append(dict(p))
real_min = {r[0]: r[1] for r in db.execute("SELECT repo_id, MIN(created) FROM pipelines GROUP BY repo_id")}
per_repo = {r: TOTAL // len(repos) for r in repos}
for r in random.sample(repos, TOTAL % len(repos)): per_repo[r] += 1
lines_per_pipe = max(5, LINES // TOTAL)
WORDS = ["compile", "resolve", "fetch", "link", "test", "lint", "pack", "upload", "verify", "cache"]
def ins(t, c, row):
    keys = [k for k in c if k in row and k != "id"]
    cur = db.execute(f"INSERT INTO {t} ({','.join('"'+k+'"' for k in keys)}) VALUES ({','.join('?'*len(keys))})", [row[k] for k in keys])
    return cur.lastrowid
db.execute("BEGIN")
now = int(time.time()); made = 0; deleted = 0; nlines = 0; longv = 0
for repo, n in per_repo.items():
    if repo not in tmpl: continue
    # shift real pipeline numbers up so synthetic history is older
    db.execute("UPDATE pipelines SET number = -(number + ?), parent = CASE WHEN parent > 0 THEN parent + ? ELSE parent END WHERE repo_id = ?", (n, n, repo))
    db.execute("UPDATE pipelines SET number = -number WHERE repo_id = ? AND number < 0", (repo,))
    end = real_min[repo] - 600
    start = end - 180 * 86400
    times = sorted(random.randint(start, end) for _ in range(n))
    for num, ts in enumerate(times, 1):
        t = random.choice(tmpl[repo])
        p = dict(t)
        status = random.choices(["success", "failure", "killed", "error"], [82, 13, 3, 2])[0]
        sha = hashlib.sha1(f"{repo}-{num}".encode()).hexdigest()
        if len(t.get("commit") or "") == 64: sha = hashlib.sha256(f"{repo}-{num}".encode()).hexdigest()
        dur = random.randint(20, 400)
        p.update(number=num, status=status, created=ts, updated=ts + dur + 5, started=ts + random.randint(1, 30),
                 finished=ts + dur, commit=sha, timestamp=ts - random.randint(5, 300))
        if "message" in p:
            p["message"] = random.choice(["fix: handle nil config", "feat: add retry budget", "chore(deps): bump alpine", "Merge branch 'release'", "refactor: split handler", "docs: runbook"]) + "\n"
        if "event" in p: p["event"] = random.choices(["push", "pull_request", "manual", "cron"], [70, 15, 5, 10])[0]
        if random.random() < 0.004 and longv < 12:
            longv += 1
            br = "feature/" + "/".join(["very-long-branch-name-segment-%02d" % i for i in range(9)])
            for k in ("branch", "ref"):
                if k in p: p[k] = ("refs/heads/" if k == "ref" else "") + br
            if "forge_url" in p and p["forge_url"]: p["forge_url"] = p["forge_url"].rsplit("/", 1)[0] + "/" + sha + "?" + "&".join("ctx%d=compare-against-upstream-release-candidate" % i for i in range(8))
            for k in ("title", "message"):
                if k in p and p[k] is not None: p[k] = "Release candidate: " + ("aggregate changes across modules; " * 12)
        pid = ins("pipelines", PC, p)
        if status == "failure" and "errors" in p: pass
        for w in db.execute("SELECT * FROM workflows WHERE pipeline_id=?", (t["id"],)).fetchall():
            w = dict(w); oldw = w["id"]
            wst = "success" if status == "success" else status
            w.update(pipeline_id=pid, state=wst, started=p["started"], finished=p["finished"])
            wid = ins("workflows", WC, w)
            for s in db.execute("SELECT * FROM steps WHERE pipeline_id=? AND ppid=?", (t["id"], w["pid"])).fetchall():
                s = dict(s); olds = s["id"]
                s.update(pipeline_id=pid, state="success" if status == "success" or random.random() < 0.6 else status,
                         started=p["started"], finished=p["finished"], uuid=hashlib.md5(f"{pid}-{olds}".encode()).hexdigest())
                sid = ins("steps", SC, s)
                k = random.randint(lines_per_pipe // 3, lines_per_pipe // 2 + 3)
                rows = []
                for i in range(k):
                    w_ = random.choice(WORDS)
                    txt = f"\x1b[32m[{w_}]\x1b[0m item {i:04d} {sha[:8]} ok" if random.random() > 0.03 else "legacy bytes: caf\xe9".encode("latin-1").decode("latin-1")
                    data = txt.encode("utf-8") if random.random() > 0.01 else b"raw \xff\xfe\xc3\x28 bytes"
                    rows.append((sid, i, i, data, ts + i, 0))
                db.executemany("INSERT INTO log_entries (step_id, time, line, data, created, type) VALUES (?,?,?,?,?,?)", rows)
                nlines += k
        made += 1
        if random.random() < 0.02:  # user deleted this pipeline later -> id gap
            for (sid,) in db.execute("SELECT id FROM steps WHERE pipeline_id=?", (pid,)).fetchall():
                db.execute("DELETE FROM log_entries WHERE step_id=?", (sid,))
            db.execute("DELETE FROM steps WHERE pipeline_id=?", (pid,))
            db.execute("DELETE FROM workflows WHERE pipeline_id=?", (pid,))
            db.execute("DELETE FROM pipelines WHERE id=?", (pid,))
            deleted += 1
db.execute("COMMIT")
print(json.dumps({"inserted": made, "deleted": deleted, "log_lines": nlines, "long_values": longv}))
PYEOF
docker run --rm -v "${PROJECT}_woodpecker-server-data:/var/lib/woodpecker" -v "$WORK:/w:ro" "$PY_IMAGE" \
  python /w/gen_history.py /var/lib/woodpecker/woodpecker.sqlite "$SYNTH_TOTAL" "$SYNTH_LOG_LINES"
DC up -d woodpecker-server
for i in $(seq 1 60); do curl -fs "$WP/healthz" >/dev/null 2>&1 && break; sleep 1; done
DC up -d agent-1 agent-2 agent-3

# history inserts shifted real pipeline numbers: rewrite deploy markers to match
RT_JSON=$(wpa GET "/repos/${WPID[ops/release-train]}/pipelines?perPage=50")
python3 - "$CI_BOX/deploys/markers.log" "$RT_JSON" <<'PYEOF'
import sys, json
path, pipes = sys.argv[1], json.loads(sys.argv[2]) or []
num = {p["commit"]: p["number"] for p in pipes}
out = []
for line in open(path):
    parts = line.split()
    if len(parts) == 3 and parts[2] in num: parts[1] = str(num[parts[2]])
    out.append(" ".join(parts) + "\n")
open(path, "w").writelines(out)
PYEOF

# crons
wpa POST "/repos/${WPID[platform/api-gateway]}/cron" '{"name":"smoke-every-5m","schedule":"@every 5m","branch":"main"}' >/dev/null
wpa POST "/repos/${WPID[ops/release-train]}/cron" '{"name":"nightly-deploy","schedule":"0 2 * * *","branch":"main"}' >/dev/null
wpa POST "/repos/${WPID[data/etl-nightly]}/cron" '{"name":"nightly-etl","schedule":"30 1 * * *","branch":"main"}' >/dev/null

# ---------------------------------------------------------------- live traffic
log "starting traffic clients"
cat > "$TRAFFIC_DIR/pusher.sh" <<'EOF'
#!/bin/sh
# commits to 3 repos every 20-60s; appends "time repo branch sha" to /out/pushes.log
set -u
mkdir -p /work; cd /work
for r in platform/api-gateway web/storefront ops/release-train; do
  [ -d "$r/.git" ] || git clone -q "http://bob:${TOKEN}@forgejo:3000/$r.git" "$r"
done
while true; do
  case $(( $(od -An -N1 -tu1 /dev/urandom) % 3 )) in 0) r=platform/api-gateway;; 1) r=web/storefront;; *) r=ops/release-train;; esac
  cd "/work/$r"
  git pull -q --rebase origin main 2>/dev/null
  date +%s >> CHANGELOG
  git add -A
  git -c user.name=bob -c user.email=bob@ci-box.lan commit -qm "chore: update changelog $(date +%H:%M:%S)"
  if git push -q origin main 2>/dev/null; then
    echo "$(date -u +%FT%TZ) $r main $(git rev-parse HEAD)" >> /out/pushes.log
  else
    git reset -q --hard origin/main
  fi
  cd /work
  sleep $(( 20 + $(od -An -N1 -tu1 /dev/urandom) % 41 ))
done
EOF
cat > "$TRAFFIC_DIR/prbot.sh" <<'EOF'
#!/bin/sh
# opens or updates a PR on platform/auth-service every few minutes
set -u
R=platform/auth-service; API=http://forgejo:3000/api/v1
mkdir -p /work; cd /work; [ -d auth/.git ] || git clone -q "http://bob:${TOKEN}@forgejo:3000/$R.git" auth
cd auth
n=0
while true; do
  git fetch -q origin
  open=$(curl -s -H "Authorization: token $TOKEN" "$API/repos/$R/pulls?state=open" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "$open" ] && [ $(( $(od -An -N1 -tu1 /dev/urandom) % 3 )) -ne 0 ]; then
    br=$(curl -s -H "Authorization: token $TOKEN" "$API/repos/$R/pulls/$open" | grep -o '"head":{"label":"[^"]*"' | sed 's/.*"label":"//; s/"$//')
    git checkout -q -B "$br" "origin/$br" 2>/dev/null || { sleep 60; continue; }
    date +%s >> pr-notes.txt
    git -c user.name=bob -c user.email=bob@ci-box.lan add -A
    git -c user.name=bob -c user.email=bob@ci-box.lan commit -qm "review: address comments"
    git push -q origin "$br" && echo "$(date -u +%FT%TZ) update $R#$open $(git rev-parse HEAD)" >> /out/prbot.log
  else
    n=$((n+1)); br="bot/deps-$(date +%s)"
    git checkout -q -B "$br" origin/main
    echo "dep-$n $(date +%s)" >> deps.lock
    git -c user.name=bob -c user.email=bob@ci-box.lan add -A
    git -c user.name=bob -c user.email=bob@ci-box.lan commit -qm "deps: bump dependency set $n"
    git push -q origin "$br"
    body="{\"title\":\"deps: bump dependency set $n\",\"head\":\"$br\",\"base\":\"main\",\"body\":\"Automated dependency update.\"}"
    num=$(curl -s -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' -d "$body" "$API/repos/$R/pulls" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2)
    echo "$(date -u +%FT%TZ) open $R#$num $(git rev-parse HEAD)" >> /out/prbot.log
    # keep the number of open PRs small: close the oldest when > 3 are open
    old=$(curl -s -H "Authorization: token $TOKEN" "$API/repos/$R/pulls?state=open&sort=oldest" | grep -o '"number":[0-9]*' | cut -d: -f2)
    cnt=$(echo "$old" | grep -c .)
    if [ "$cnt" -gt 3 ]; then o=$(echo "$old" | tail -1)
      curl -s -X PATCH -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' -d '{"state":"closed"}' "$API/repos/$R/pulls/$o" >/dev/null 2>&1 || true
    fi
  fi
  sleep $(( 120 + $(od -An -N1 -tu1 /dev/urandom) % 180 ))
done
EOF
chmod +x "$TRAFFIC_DIR"/*.sh
printf 'FROM alpine:3.20
RUN apk add --no-cache git curl coreutils
' | docker build -q -t ci-traffic:local - >/dev/null
for c in pusher prbot; do
  docker run -d --name "${PROJECT}-traffic-$c" --restart unless-stopped --network "${PROJECT}_default" \
    -e TOKEN="$BOB_FJ_TOKEN" -v "$TRAFFIC_DIR:/out" -v "$TRAFFIC_DIR/$c.sh:/run.sh:ro" \
    ci-traffic:local /bin/sh /run.sh >/dev/null
done

# ---------------------------------------------------------------- notes
cat > "$CI_BOX/NOTES.txt" <<EOF
ci-box - build server notes
===========================

Everything runs from docker compose in this folder:
  cd ~/ci-box && docker compose ps

Services
  forgejo            git hosting       http://${PUBLIC_HOST}:${FORGEJO_PORT}   (data in ./data/forgejo)
  woodpecker-server  CI                http://${PUBLIC_HOST}:${WP_PORT}   (sqlite, volume woodpecker-server-data)
  agent-1..3         woodpecker agents, docker backend, 2 workflows each
  postgres           postgres 16 for woodpecker - not in use yet

  forgejo's ROOT_URL is http://forgejo:3000 (what the containers use). For a browser
  login to woodpecker put "127.0.0.1 forgejo" in /etc/hosts.

Logins (forgejo; woodpecker logs in through forgejo)
  ${ADMIN_USER} / ${ADMIN_PASS}   forgejo site admin
  alice / ${ALICE_PASS}          woodpecker admin, owns the orgs
  bob / ${BOB_PASS}            developer

Tokens
  woodpecker API token for alice: ${WP_TOKEN}
    curl -H "Authorization: Bearer \$TOKEN" http://${PUBLIC_HOST}:${WP_PORT}/api/user
  secrets for compose (oauth client, agent secret, postgres password) are in .env

Misc
  release-train deploys append to ./deploys/markers.log
  nightly deploy cron 02:00, etl 01:30, api-gateway smoke every 5 min
  backups: none yet (TODO)
EOF

rm -rf "$WORK"
log "done in $(( $(date +%s) - T0 ))s"
DC ps --format '{{.Name}}\t{{.Status}}'
