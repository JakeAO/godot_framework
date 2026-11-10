# godot_framework

Mobile game framework + its backend, in one repo:

| Folder | What it is |
|---|---|
| `framework/` | Godot 4.7 (mobile renderer) game project — the "Game Stage Prototype" framework: code-first GDScript UI, GUT test suite, headless verification gate, Android export. Docs in `framework/documentation/`. |
| `server/` | Nakama server stack (D5b): pinned Nakama 3.37.0 + Postgres 16 + Caddy in docker-compose, one JS server function (`team_ops`), in-Nakama Go analytics plugin. Docs in `server/README.md` + `framework/documentation/BACKEND.md`. |

## Prerequisites

- **Godot 4.7 stable** (headless binary used by the gate; expected at `~/tools/godot`, override with `GODOT_BIN`)
- **Android SDK** with `platforms;android-34` + `build-tools;34.0.0` (gate's export step; default `~/Android/Sdk`, override with `ANDROID_HOME`)
- **JDK** — the framework's editor settings point at an explicit path (`export/android/java_sdk_path` in Godot's editor settings)
- **Docker + compose plugin** (server only)

## Framework quickstart

```sh
cd framework
bash tools/gate.sh        # 4-stage gate: import clean, boot clean, GUT all-pass, Android APK built
```

Green output ends with `GATE GREEN: import clean, boot clean, GUT all-pass, Android APK built.`
The debug APK lands in `framework/build/android/game.apk` (gitignored).

Run the game in a real editor: open `framework/` in Godot 4.7 and press Play (main scene is set in `project.godot`).

## Server quickstart

```sh
cd server
cp .env.example .env      # local dev defaults are safe for the dev machine only
./plugins/analytics/build.sh   # builds functions/analytics.so (Docker, Go 1.25.5)
docker compose up -d
curl http://localhost:8080/healthcheck   # {} = healthy
```

Point the framework at it with the project setting `game/backend_base_url`
(local: `http://localhost:8080`). Headless integration probe:

```sh
cd framework
~/tools/godot --headless --path . -s res://tools/probe_nakama.gd \
    -- --host localhost --port 8080 --scheme http
```

Deploy runbook (4GB VPS): `framework/documentation/BACKEND.md` §5.

## Documentation map

- `framework/documentation/TDD.md` — normative technical design (architecture rules, verification)
- `framework/documentation/GDD.md` — game design
- `framework/documentation/TODO.md` / `ROADMAP.md` — status + sequencing
- `framework/documentation/DECISIONS.md` — why things are the way they are
- `framework/documentation/NOTES.md` — gotchas, verified API facts
- `framework/documentation/BACKEND.md` — server design, deploy runbook, security posture
- `server/README.md` — day-to-day server operations
- `framework/AGENTS.md` — agent/contributor conventions for the Godot project

## Conventions (short version)

- Framework: tabs, explicit static typing, EventBus-only cross-system comms, ThemeFactory for all UI chrome; warnings are errors (the import gate fails on any).
- Server: pinned upstream Nakama, no core fork; secrets live in `.env` only — never committed.
