# BACKEND — Nakama server (D5b)

> **Status (2026-11-07)**: **D5b.1 DONE** — `server/` compose stack (Nakama 3.37.0 + Postgres 16 + Caddy :8080 api) runs locally; the ONE server function `team_ops` and the analytics Go plugin are live-verified; `tools/probe_nakama.gd` = 12/12 PASS against it. **D5b.2 DONE** — Godot integration complete (OnlineService + NakamaSocialBackend/NakamaSaveSyncBackend/NakamaAnalyticsBackend + IdentityService v2 session persistence + §3.18 offline gating); analytics sink = in-Nakama Go plugin RPC (Satori plan dropped 2026-11-07 — cloud-only; DECISIONS.md); gate hermetic on mocks, 265/265 green; real mode activates behind `game/backend_base_url`. **PENDING D5b.3** — needs from the user: subdomain name + VPS access (deploy = §5 runbook; two-device smoke = §8).
> Decision rationale: DECISIONS.md 2026-11-06 entry. Execution plan: ROADMAP D5b. Verified API
> facts: NOTES.md "Nakama + Go-plugin verified facts". This document is updated BEFORE server work,
> per project docs-first policy.

## 1. What runs where

ONE VPS (4GB RAM class, ~€8–10/mo — e.g. Hetzner CX32), Ubuntu LTS, Docker + compose plugin.
The user owns the domain; ONE subdomain:

- `api.<domain>` → Caddy → Nakama (:7350) + static `/config` (remote config JSON)


| Service | Image | Port | Purpose |
|---|---|---|---|
| Caddy | `caddy:2` (pinned) | 80/443 | TLS termination (Let's Encrypt), routing, static `/config` |
| Nakama | `registry.heroiclabs.com/heroiclabs/nakama:3.37.0` | 7350 (REST + websocket) | auth, friends, groups (teams), storage objects (save sync), group chat; Phase E: matches/tournaments/leaderboards/presence |
| Postgres | `postgres:16.8-alpine` | 5432 (internal only) | Nakama's database — single data volume, survives upgrades |

**Analytics is NOT a container here either.** It lives INSIDE Nakama as a Go runtime plugin (`../server/plugins/analytics/` → `functions/analytics.so`, auto-loaded alongside `index.js`) — one more RPC endpoint, same Postgres, no extra service and no second subdomain. The original Satori partner was ruled out 2026-11-07 (cloud-only, from $600/mo); the replacement decision is in DECISIONS.md. Full mechanics: §7.

## 2. Versions & pinning policy

- **Pinned upstream release, NO core fork** (user-locked): compose pins exact image tags; `:latest` is banned. Upgrading Nakama = a deliberate change: bump the tag → `docker compose pull` → Nakama runs its migrations on start (`migrate up`) → restart. Postgres data lives on the volume and survives.
- Our customization lives in `../server/`: compose file, Caddyfile, env template, deploy scripts, and server functions under `server/functions/` — exactly ONE function: `team_ops` (group create/update with metadata; §3). Nothing is patched inside the Nakama image. The earlier plan for a Postgres-backed `team_requests` function is OBSOLETE — closed-group join requests are NATIVE in Nakama 3.37 (verified in source; §3).

## 3. Data model mapping (client concept → Nakama primitive)

| Client concept | Nakama primitive | Notes |
|---|---|---|
| Player identity | `accounts.custom_id` = the 64-hex player key | custom-ID auth AUTO-CREATES the user on first login — there is no registration step; session = JWT (TDD §3.17) |
| Player profile | user metadata `{player_code, name, level, best_score, portrait_icon, portrait_flair, portrait_crown}` | client pushes a refresh whenever the `profile` domain changes (best-effort, fire-and-forget — a failed push never blocks play); friend summaries are read from it |
| Friends | Nakama friends, states 0=friends / 1=sent / 2=received / 3=blocked | add-by-code = `GetUsers(usernames=[code])` — the player code IS the Nakama username (set at first custom-ID auth; verified: usernames allow `[A-Za-z0-9._-]`, 1–128 bytes) — then AddFriend → PENDING invitation; accept = AddFriend again (auto-accepts a two-way pending pair), decline/cancel = DeleteFriends, block = BlockFriends, **unblock = DeleteFriends on the blocked edge** (no dedicated unban API exists — verified in `core_friend.go`); two-way pending model (GDD §8 revision 2026-11-06) |
| Teams | Nakama groups — creation-time name = search key; metadata `{access_mode, display_name, power, banner_base, banner_icon, banner_base_lut, banner_icon_lut}`; roster from group members | search by (creation-time) name; the `open` flag maps access_mode ("open" ↔ `open: true`, "by-request" ↔ `open: false`); membership levels owner/admin/member exist but only leader=owner is used in v1 |
| Team creation | server function `team_ops` (action=create → runtime `nk.groupCreate`) | REST CreateGroup has NO metadata field — only the JS/Go runtime API can write group metadata (verified against `apigrpc.swagger.json` + type defs); creator = owner (leader) — TDD §3.17 |
| Team settings update | server function `team_ops` (action=update → runtime `nk.groupUpdate`) | leader-only enforced IN THE FUNCTION (creator check); display-name changes go to `metadata.display_name` (group.name is immutable after creation — accepted limitation: search matches the original name) |
| Join requests (by-request) | NATIVE: JoinGroup on a closed group = member state 3 ("Requested to join") | verified in `core_group.go`: non-admin join of a CLOSED group creates a request edge + notifies owner/admins; duplicate is idempotent. Fetch = ListGroupUsers(state=3); approve = AddGroupUsers (server enforces caller is owner/admin, so only the leader can act — no client-side trust); deny = KickGroupUsers. No custom function needed |
| Team chat | the group's channel (persistent messages) | fetch = REST `ListChannelMessages`; **send = websocket only** (REST has no send endpoint — verified in swagger): the client opens one socket, joins the group channel (type=Group, persistence=true), writes there. Realtime upgrade = Phase E1 |
| Cross-device save sync | storage objects: collection `"save"`, key = domain name, value JSON `{data, updated_at}` | one object per synced domain (`profile`/`piggy_bank`/`campaign_claims`/`team`); per-domain LWW merge stays CLIENT-side (TDD §3.16) — Nakama's CAS version is not used for merge decisions |
| Remote config | static JSON behind Caddy at `https://api.<domain>/config/remote_config.json` | deliberately static JSON, not an analytics-service feature — the schema is framework-specific (DECISIONS.md); `RemoteConfig._load_from_network()` = one HTTP GET |
| Analytics | Go plugin RPC `analytics` → `analytics_events` table in the shared Postgres | event names = our Analytics event names verbatim; identity from the session context (never client-asserted); fire-and-forget batch (TDD §3.17, §7) |
| Phase E: tournaments / leaderboards / matchmaking / presence | Nakama tournaments / leaderboards / matches (+ `NakamaMultiplayerBridge`) / presence notifications | spec-first per item — ROADMAP Phase E, all online-gated per TDD §3.18 |

## 4. Local development

- `server/docker-compose.yml` runs Nakama + Postgres + Caddy on the dev machine; local Caddy serves plain HTTP (no TLS) on one port:
  - **`:8080` = the api base URL** — static `/config/*` (remote config JSON) + reverse-proxy of everything else → `nakama:7350`. The client's `game/backend_base_url` for local dev is `http://localhost:8080`.
- One command: `cd server && docker compose up -d`. Postgres is NOT port-exposed locally (internal network only).
- Dev server key: the compose default (`defaultkey`) is fine locally and MUST NEVER ship to the VPS (see §6).
- **Probe** — `tools/probe_nakama.gd`, a headless one-shot `-s` tool. `-s` SceneTree scripts compile BEFORE the main loop starts, so they must not reference autoload names at compile time (identity_service references RemoteConfig) — it lazy-loads it and constructs its own Nakama client from the addon script (same discipline as `tools/build_stages.gd`). 12 checks, each pass/fail printed: healthcheck; custom-ID auth fresh (username = player code); session restore (static re-hydrate + server acceptance); storage write→read of a `"save"` object (`permission_read=1`); **analytics batch RPC through the Go plugin (2 events → `{ok, count}`)**; team_ops create open + metadata verify; second-user auth; open-group join (member state 2); team_ops create by-request; closed-group request flow (request visible to leader, non-leader approve denied, leader approve → member); chat websocket send → REST fetch; block → unblock. **Status: 12/12 PASS against the local compose stack (2026-11-07).** Run it before any client integration work and it is the first thing pointed at the VPS in D5b.3 (`--host/--port/--scheme/--key/--timeout` args).

## 5. Deploy runbook (4GB VPS)

1. Provision VPS (Ubuntu LTS), sudo user, firewall: allow 22/80/443 only.
2. Install Docker + compose plugin.
3. DNS: A record `api.<domain>` → VPS IP.
4. Copy `server/` to `/opt/backend` (git clone or rsync). Fill the env file on the box: Nakama **server key = generated secret** (never `defaultkey`), Postgres password. Secrets live in `.env` on the VPS only — never in git.
5. `API_DOMAIN=api.<domain> ./deploy.sh` (builds the analytics Go plugin via Docker first — step 2b — then generates .env secrets + prod Caddyfile and starts the prod compose). Caddy auto-provisions Let's Encrypt certs. Verify: Nakama healthcheck route (`GET /healthcheck` through TLS — verified in `apigrpc.swagger.json`), `/config/remote_config.json` serves valid JSON.
6. Point a client at it: set `game/backend_base_url` (project setting — TDD §3.17) to `https://api.<domain>` and boot; DevTools shows the mode + online state.

**Upgrades**: bump the pinned image tag in compose → `docker compose pull` → `docker compose up -d` (Nakama migrates on start). Downgrade is not supported — pin forward only.

**Backups**: nightly cron `pg_dump` of the Nakama Postgres DB → local archive + offsite copy (rclone to S3-compatible storage). Restore = drop schema, re-import, restart. Prototype-grade: a stale-by-hours backup window is acceptable; losing ALL player data is not.

**Monitoring**: one external uptime check on `https://api.<domain>/` (the TLS root) — the only monitoring at prototype scale; Nakama's healthcheck route covers manual checks. No APM, no alerting beyond the uptime check until public players arrive.

## 6. Security posture (prototype-grade, per GDD §8)

- **Identity = custom ID**: whoever holds a device's `player_identity.json` IS that player. There is no PII beyond profile strings (name, portrait picks). No email/password/phone anywhere.
- **The Nakama server key is a shared secret** — treat it like a password: `.env` on the VPS + local dev only. A leaked key lets anyone impersonate any player → rotate the key and re-auth; accept that as the incident response (prototype-grade).
- TLS everywhere (Caddy); REST and websocket both on 443. Postgres never exposed.
- **At the public-player phase (D5b.4)**: enable rate limits, chat message caps + a moderation hook, and use Nakama's native user/group ban workflow for abuse. Until then the game is closed to friends/family — no open registration surface exists beyond holding a player key.
- Accepted risks (documented, not fixed): no WAF, single VPS (no HA), backups may be hours stale, session JWTs are the only auth (they ARE the auth).

## 7. Analytics sink — in-Nakama Go plugin (no second container)

**Decision history**: Satori (the original plan, DECISIONS 2026-11-06) was ruled out 2026-11-07 — cloud-only, from $600/mo. Replacement options were researched the same day (Countly Lite / PostHog / DIY); the user chose the DIY direction and refined it: put the ingest INSIDE Nakama as a Go runtime plugin instead of a separate container — one more RPC endpoint, sharing the existing Postgres.

**Mechanism (verified live 2026-11-07)**:
- `server/plugins/analytics/main.go` + `go.mod`, pinned to **Go 1.25.5 + nakama-common v1.44.2** — must match the Go version Nakama 3.37.0 was built with (`go version -m` on the binary).
- `plugins/analytics/build.sh` = `docker run golang:1.25.5 go build -trimpath -buildmode=plugin` → copies `analytics.so` into `functions/`. Nakama's `--runtime.path /nakama/functions` loads BOTH `index.js` and any `.so` files it finds — zero compose changes for the plugin to exist (Nakama log: `Found runtime modules, count 2`).
- **Gotcha (cost a debugging cycle)**: the build MUST use `-trimpath`. The Go runtime checks per-package SHA-256 fingerprints over unified-IR export data, which embeds source file paths; the official Nakama binary was built with `-trimpath=true`, so a vanilla plugin build fails to load with FATAL `plugin was built with a different version of package internal/goarch`.
- InitModule runs `CREATE TABLE IF NOT EXISTS analytics_events` (+ 2 indexes) in the SAME Postgres as everything else. Handler = RPC id `analytics`.

**Payload contract**: client sends `{"events":[{"name","ts","session_id","props"}]}` (≤500 events/call; name ≤128 chars, session_id ≤64 chars). The server fills `user_id`/`username` from the session context (`RUNTIME_CTX_USER_ID/USERNAME`) — identity is NEVER client-asserted. Batch INSERT in one transaction → `{"ok":true,"count":N}`.

**Client**: `core/nakama_analytics_backend.gd` (TDD §3.17) — always attached, real-mode only; fire-and-forget `rpc_async`; failure = drop batch + warn once.

**Inspecting events**: `docker compose exec postgres psql -U postgres -d nakama -c 'SELECT * FROM analytics_events ORDER BY created_at DESC LIMIT 20'` (columns: id, user_id, username, name, props JSONB, client_ts timestamptz — NULL when the client sent ts=0 — session_id, created_at).

**Later**: dashboards/processing can be added against the same table (Grafana pointed at the Postgres, or any tool that reads it) — nothing in this design blocks on that.

## 8. Integration smoke test (two real devices, manual — D5b.3)

Both devices pointed at `https://api.<domain>`, debug builds with DevTools available:

1. **Boot + identity**: device A boots → player key created, session established, DevTools shows mode=real + ONLINE.
2. **Friend invitation round-trip**: A adds B by player code → B sees the pending (received) invitation → B accepts → both friends lists show each other with correct summary fields (name/level/best_score/portrait).
3. **Pending + block states**: A adds a third code that rejects → sent-pending clears; A blocks B → B disappears from A's list and cannot be re-added until unblocked.
4. **Teams**: A joins a group; B searches by name, joins the same group → rosters match on both devices (owner first); chat: A sends, B polls while the Chat subtab is visible and sees it; send echo appears immediately for the sender.
5. **Offline gating**: airplane mode on B → friends/teams/chat controls disabled + dimmed with the offline hint, chat shows last messages + banner, Profile sync line = "offline", gameplay/rewards fully playable; restore connectivity → state returns to ONLINE within one probe cadence and everything re-enables.
6. **Save sync both directions**: A plays a round (coins/level rise) → upload fires; B fetches on next boot → LWW merge takes the newer domain stamps; reverse direction (B mutates, A picks up) too.
7. **Config**: both devices fetch `/config`; edit the served file (flip a flag) → refetch from DevTools picks it up; kill Caddy's static route → clients fall back to last-good cache with no UI breakage.
8. **Analytics**: `psql` query on `analytics_events` (§7) shows rows for BOTH player ids with the expected event names (screen_view, gameplay_started/finished, experiment_exposure).
9. **Team create + settings**: A creates a team (name, by-request access, custom banner recipe) → banner renders from the recipe on A's header; A renames it and switches to open in settings → B's search shows the new display name + open badge.
10. **By-request flow**: C requests to join A's by-request team → "Request sent" state on C; A sees the request in team settings → approve → C on the roster for both devices; deny path (second requester) clears the pending state.
