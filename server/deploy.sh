#!/usr/bin/env bash
# VPS deploy (BACKEND.md §5). Run ON the VPS as a user in the docker group,
# with backend/ copied to /opt/backend. Prereqs: Ubuntu LTS, Docker + compose
# plugin, firewall allowing 22/80/443 only, DNS A record api.<domain> -> this box.
#
#   API_DOMAIN=api.example.com ./deploy.sh
set -euo pipefail

: "${API_DOMAIN:?usage: API_DOMAIN=api.yourdomain.com ./deploy.sh}"
cd "$(dirname "$0")"

# 1. Secrets — generated once into .env (never in git, never echoed).
if [ ! -f .env ]; then
	{
		printf 'NAKAMA_SERVER_KEY=%s\n' "$(openssl rand -hex 32)"
		printf 'SESSION_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
		printf 'SESSION_REFRESH_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
		printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)"
		# Console (admin API) — never ship the admin/admin defaults publicly.
		printf 'CONSOLE_USERNAME=console\n'
		printf 'CONSOLE_PASSWORD=%s\n' "$(openssl rand -hex 24)"
		printf 'CONSOLE_SIGNING_KEY=%s\n' "$(openssl rand -hex 32)"
	} > .env
	chmod 600 .env
	echo "[deploy] generated .env with fresh secrets"
else
	echo "[deploy] .env exists — keeping it (rotating = new file + restart; sessions invalidate)"
fi

# 2. Production Caddyfile — TLS via Let's Encrypt, auto-provisioned on first boot.
cat > Caddyfile <<EOF
{
	admin off
}

${API_DOMAIN} {
	encode gzip
	root * /srv/config
	handle /config/* {
		header Content-Type application/json
		file_server
	}
	reverse_proxy nakama:7350
}
EOF
echo "[deploy] wrote Caddyfile for ${API_DOMAIN}"

# 2b. Analytics Go plugin — must be built against the pinned Nakama version
# (see plugins/analytics/build.sh and README.md for the version-pinning rule).
./plugins/analytics/build.sh
if [ ! -s functions/analytics.so ]; then
	echo "[deploy] FAIL: functions/analytics.so missing after build"
	exit 1
fi

# 3. Start the production stack.
docker compose -f docker-compose.prod.yml up -d

# 4. Verify (health route verified in apigrpc.swagger.json).
ok=0
for _ in $(seq 1 60); do
	if curl -fsS "https://${API_DOMAIN}/healthcheck" >/dev/null 2>&1; then ok=1; break; fi
	sleep 2
done
if [ "$ok" != "1" ]; then
	echo "[deploy] FAIL: https://${API_DOMAIN}/healthcheck not answering — check: docker compose -f docker-compose.prod.yml logs"
	exit 1
fi
echo "[deploy] Nakama healthy at https://${API_DOMAIN}/healthcheck"

config_status="$(curl -fsS -o /dev/null -w '%{http_code}' "https://${API_DOMAIN}/config/remote_config.json")"
if [ "$config_status" != "200" ]; then
	echo "[deploy] FAIL: /config/remote_config.json returned HTTP ${config_status}"
	exit 1
fi
echo "[deploy] config endpoint OK (HTTP 200)"

echo "[deploy] DONE. Point the client's game/backend_base_url at https://${API_DOMAIN}"
echo "[deploy] Nightly backups: install backup.sh via cron (BACKEND.md §5)."
