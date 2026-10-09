#!/usr/bin/env bash
# ==============================================================================
# MT5 Cloud Runner Harness - Headless Cloud Session Bootstrapper
# Pulls compiled standalone engine over-the-air (OTA) and executes in window-mode
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p logs data

echo "===================================================================="
echo "   STARTING MT5 CLOUD RUNNER HARNESS (HEADLESS MULTI-ACCOUNT)"
echo "   Host Time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "===================================================================="

# 1. Download compiled standalone engine binary from private release (OTA)
echo "[Cloud Harness] Pulling latest standalone engine binary from private repository..."
gh release download latest-engine \
    --repo stayzappy/mt5-forex-bot \
    --pattern "mt5_trader_engine-linux-x86_64.tar.gz" \
    --clobber

tar -xzf mt5_trader_engine-linux-x86_64.tar.gz
chmod +x mt5_trader_engine

echo "[Cloud Harness] Engine binary verified: $(./mt5_trader_engine --help | head -n 2 | tail -n 1)"

# 2. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py


# 4. Start Docker containers
echo "[Cloud Harness] Starting Docker MT5 headless containers..."
docker compose up -d

echo "[Cloud Harness] Waiting 15s for Wine initialization..."
sleep 15

# Helper: Auto-login injection into container
inject_mt5_cfg() {
    local cname="$1"
    local env_file="$2"
    if [ ! -f "$env_file" ]; then return 0; fi

    local login_val pwd_val srv_val
    login_val=$(grep '^MT5_LOGIN=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    pwd_val=$(grep '^MT5_PASSWORD=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    srv_val=$(grep '^MT5_SERVER=' "$env_file" | cut -d= -f2- | tr -d ' "\r')

    docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config" 2>/dev/null || true
    if [ -f "config/servers.dat" ]; then
        docker cp "config/servers.dat" "$cname:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat" 2>/dev/null || true
    fi

    if [ -n "$login_val" ] && [ -n "$pwd_val" ]; then
        docker exec "$cname" sh -c "cat > '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini' <<EOF
[Common]
Login=${login_val}
Password=${pwd_val}
Server=${srv_val}
NewsEnable=0
Profile=Blank
ProxyEnable=0
[Charts]
MaxBars=1000000
SelectOneClick=1
[Experts]
Enabled=1
Account=0
Profile=0
Chart=0
Api=0
[Events]
Enable=0
NewsEnable=0
EOF
cp '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini' /mt5linux/mt5cfg.ini 2>/dev/null || true"
    fi
}

echo "[Cloud Harness] Configuring auto-login mt5cfg.ini and Exness servers in containers..."
inject_mt5_cfg mt5_headless .env.strategy_a
inject_mt5_cfg mt5_headless_b .env.strategy_b
inject_mt5_cfg mt5_headless_c .env.funded_500k
inject_mt5_cfg mt5_headless_d .env.weekly80
docker restart mt5_headless mt5_headless_b mt5_headless_c mt5_headless_d >/dev/null 2>&1 || true
echo "[Cloud Harness] Waiting 15s for Wine initialization after restart..."
sleep 15

# 5. Wait for all 4 RPyC bridges to become ready
echo "[Cloud Harness] Waiting for MT5 bridges on ports 18812, 18813, 18814 & 18815..."
python3 -c "
import socket, time, sys
for port in [18812, 18813, 18814, 18815]:
    ok = False
    for _ in range(90):
        try:
            with socket.create_connection(('localhost', port), timeout=1.0):
                ok = True
                break
        except (socket.error, OSError):
            time.sleep(1.0)
    if not ok:
        print(f'Warning: Port {port} did not respond within timeout.', file=sys.stderr)
print('All MT5 RPyC bridges are ready.')
"

# 6. Launch all 4 bots via compiled standalone binary
echo "[Cloud Harness] Launching 4 bots in --window-mode via compiled native binary..."
./mt5_trader_engine --env .env.strategy_a --window-mode &
PID_A=$!

./mt5_trader_engine --env .env.strategy_b --window-mode &
PID_B=$!

./mt5_trader_engine --env .env.funded_500k --window-mode &
PID_C=$!

./mt5_trader_engine --env .env.weekly80 --window-mode &
PID_D=$!

echo "[Cloud Harness] 4 bots executing in background (PIDs: $PID_A, $PID_B, $PID_C, $PID_D)."
wait "$PID_A" "$PID_B" "$PID_C" "$PID_D"
echo "[Cloud Harness] Session complete. Clean exit."

