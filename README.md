# seed-jvr2c2ct kit

`seed.sh` builds `~/ci-box`: a running CI setup to use as the task's starting state.

- docker compose project `ci-box`: forgejo 11.0.16 (SQLite, ./data/forgejo), woodpecker-server
  v3.12.0 (SQLite, log store = database, volume `ci-box_woodpecker-server-data`), agent-1..3
  (docker backend, 2 workflows each), and an idle postgres:16 (volume `ci-box_postgres-data`).
- Forgejo users: forge-admin (site admin), alice (woodpecker admin), bob. Six orgs, 21 repos. One org has a
  39-char name, two repos have 50+ char names, and two repos use SHA-256
  (platform/config-registry, data/lakehouse-schemas).
- The OAuth2 app is created and alice and bob log in to Woodpecker through the scripted OAuth flow
  (forgejo login form -> authorize/grant -> woodpecker callback). Repos are activated via the API.
- Pipelines: ANSI colour output, non-UTF-8 bytes, a step logging about 2 MB / 24k lines (data/etl-nightly),
  multi-workflow repos with depends_on (shared-libs, storefront, android-app, partner-webhook-relay),
  and the ops/release-train deploy step (3-5 min). That step appends `<repo> <pipeline number> <commit>` to
  `~/ci-box/deploys/markers.log`. The repo is trusted for volumes.
- History: about 150 real builds, plus about 2900 synthetic pipelines inserted into SQLite with the server stopped.
  They copy the real rows' shape and are older, and the real pipeline numbers are shifted above them.
  About 2% of them are deleted (id gaps), and 12 rows have a branch/forge_url/title/message longer than 255 chars.
  Expect about 3000 pipelines and about 420k log_entries.
- Secrets on billing-worker, infra-terraform and release-train, plus an org secret on platform.
  Crons: api-gateway `@every 5m`, release-train nightly-deploy `0 2 * * *`, etl-nightly `30 1 * * *`.
- Live traffic, left running as containers `ci-box-traffic-pusher` and `ci-box-traffic-prbot`
  (scripts and logs are in `~/.ci-traffic/`):
  - The pusher commits to api-gateway, storefront or release-train every 20-60 s. It logs to `pushes.log`.
  - The PR bot opens or updates a PR on platform/auth-service every 2-5 min. It logs to `prbot.log`.

`pushes.log`, `prbot.log` and `markers.log` let a checker see whether every push got a pipeline and
whether any deploy ran twice or never ran.

## Run

```sh
bash seed.sh          # in the lane, as the lane user; needs docker + compose, curl, git, python3
```

It takes about 4-5 min with images cached and about 6-7 min with fresh pulls. Overrides are env vars: CI_BOX,
TRAFFIC_DIR, FORGEJO_PORT (3000), WP_PORT (8000), REAL_TARGET, REAL_BUDGET_S, SYNTH_TOTAL,
SYNTH_LOG_LINES.
