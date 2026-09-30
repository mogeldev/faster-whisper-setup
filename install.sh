#!/usr/bin/env bash
#
# Install faster-whisper-fastapi on Debian 13 (Trixie).
#
# Sets up: system packages, virtualenv, dependencies, .env with a
# generated API key, and a systemd service. It does NOT touch Caddy
# or any other reverse proxy; see the README for that part.
#
# Safe to run more than once: an existing .env is never overwritten,
# so the API key survives re-runs.
#
# Usage:
#   sudo ./install.sh [options]
#
# Options are also readable from the environment, e.g.
#   sudo MODEL_SIZE=small PORT=9000 ./install.sh

set -euo pipefail

# --------------------------------------------------------------------
# Defaults (override via environment or flags)
# --------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/faster-whisper-fastapi}"
SERVICE_NAME="${SERVICE_NAME:-faster-whisper}"
SERVICE_USER="${SERVICE_USER:-root}"
REPO_URL="${REPO_URL:-https://github.com/mogeldev/faster-whisper-setup.git}"

MODEL_SIZE="${MODEL_SIZE:-large-v3-turbo}"
COMPUTE_TYPE="${COMPUTE_TYPE:-int8}"
CPU_THREADS="${CPU_THREADS:-2}"
PORT="${PORT:-8000}"
BIND_HOST="${BIND_HOST:-127.0.0.1}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
START_SERVICE="${START_SERVICE:-1}"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"

# --------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------
if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
	C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
fi

step()  { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
	cat <<-EOF
	Install faster-whisper-fastapi on Debian 13 (Trixie).

	Sets up system packages, a virtualenv, dependencies, an .env with a
	generated API key, and a systemd service. It does NOT touch Caddy or
	any other reverse proxy; see the README for that part.

	Safe to run more than once: an existing .env is never overwritten, so
	the API key survives re-runs.

	Usage:
	  sudo ./install.sh [options]

	Every option can also be given as an environment variable, e.g.
	  sudo MODEL_SIZE=small PORT=9000 ./install.sh

	Options:
	  --install-dir PATH    install location (default: $INSTALL_DIR)
	  --service-name NAME   systemd unit name (default: $SERVICE_NAME)
	  --user NAME           user the service runs as (default: $SERVICE_USER)
	  --model NAME          whisper model (default: $MODEL_SIZE)
	  --compute-type TYPE   int8, int8_float32, float32 (default: $COMPUTE_TYPE)
	  --threads N           CPU threads (default: $CPU_THREADS)
	  --port N              port uvicorn listens on (default: $PORT)
	  --bind-host ADDR      bind address (default: $BIND_HOST)
	  --python-bin NAME     python interpreter (default: $PYTHON_BIN)
	  --no-start            install but do not start the service
	  --help                show this help
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--install-dir)   INSTALL_DIR="$2"; shift 2 ;;
		--service-name)  SERVICE_NAME="$2"; shift 2 ;;
		--user)          SERVICE_USER="$2"; shift 2 ;;
		--model)         MODEL_SIZE="$2"; shift 2 ;;
		--compute-type)  COMPUTE_TYPE="$2"; shift 2 ;;
		--threads)       CPU_THREADS="$2"; shift 2 ;;
		--port)          PORT="$2"; shift 2 ;;
		--bind-host)     BIND_HOST="$2"; shift 2 ;;
		--python-bin)    PYTHON_BIN="$2"; shift 2 ;;
		--no-start)      START_SERVICE=0; shift ;;
		-h|--help)       usage; exit 0 ;;
		*)               die "unknown option: $1 (try --help)" ;;
	esac
done

# --------------------------------------------------------------------
# 1. Preconditions
# --------------------------------------------------------------------
step "Checking preconditions"

[ "$(id -u)" -eq 0 ] || die "run this script as root (sudo ./install.sh)"

if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	if [ "${ID:-}" != "debian" ] || [ "${VERSION_ID:-}" != "13" ]; then
		warn "this script targets Debian 13, found ${PRETTY_NAME:-unknown}"
		warn "continuing, but package names may differ"
	fi
else
	warn "/etc/os-release not readable, cannot verify the distribution"
fi

case "$PORT" in
	''|*[!0-9]*) die "--port must be a number, got '$PORT'" ;;
esac
case "$CPU_THREADS" in
	''|*[!0-9]*) die "--threads must be a number, got '$CPU_THREADS'" ;;
esac

ok "running as root on ${PRETTY_NAME:-unknown}"

# --------------------------------------------------------------------
# 2. System packages
# --------------------------------------------------------------------
step "Installing system packages"

PACKAGES="${PYTHON_BIN} ${PYTHON_BIN}-venv ${PYTHON_BIN}-dev git curl openssl ca-certificates ffmpeg"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq $PACKAGES

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "$PYTHON_BIN not found after install"

# The code uses PEP 604 unions in runtime-evaluated signatures, so 3.10
# is the hard floor. Debian 13 ships 3.13, Debian 12 ships 3.11.
"$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
	|| die "$PYTHON_BIN is $("$PYTHON_BIN" -V 2>&1), need 3.10 or newer"

ok "$("$PYTHON_BIN" --version)"

# --------------------------------------------------------------------
# 3. Project files
# --------------------------------------------------------------------
step "Placing project files in $INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/requirements.txt" ] && [ -d "$SCRIPT_DIR/src" ]; then
	if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ]; then
		ok "already running from the install directory"
	else
		mkdir -p "$INSTALL_DIR"
		cp -r "$SCRIPT_DIR/src" "$INSTALL_DIR/"
		for f in requirements.txt .env.example Caddyfile README.md LICENSE install.sh; do
			[ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/"
		done
		ok "copied from $SCRIPT_DIR"
	fi
elif [ -d "$INSTALL_DIR/.git" ]; then
	git -C "$INSTALL_DIR" pull --ff-only
	ok "updated existing checkout"
else
	mkdir -p "$INSTALL_DIR"
	git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
	ok "cloned $REPO_URL"
fi

cd "$INSTALL_DIR"

# --------------------------------------------------------------------
# 4. Service user
# --------------------------------------------------------------------
if [ "$SERVICE_USER" != "root" ]; then
	step "Ensuring service user '$SERVICE_USER' exists"
	if id -u "$SERVICE_USER" >/dev/null 2>&1; then
		ok "user already exists"
	else
		useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
		ok "created system user"
	fi
fi

# --------------------------------------------------------------------
# 5. Virtualenv and dependencies
# --------------------------------------------------------------------
step "Creating virtualenv and installing dependencies"

[ -d "$INSTALL_DIR/.venv" ] || "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv"
VENV_PY="$INSTALL_DIR/.venv/bin/python"

"$VENV_PY" -m pip install --upgrade --quiet pip setuptools wheel
"$VENV_PY" -m pip install --quiet -r "$INSTALL_DIR/requirements.txt"
ok "dependencies installed"

# --------------------------------------------------------------------
# 6. Configuration
# --------------------------------------------------------------------
step "Writing configuration"

ENV_FILE="$INSTALL_DIR/.env"

if [ -f "$ENV_FILE" ]; then
	warn "$ENV_FILE exists, leaving it untouched (API key preserved)"
	API_KEY="$(grep -E '^API_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
	[ -n "$API_KEY" ] || warn "no API_KEY found in the existing .env, the service will not start"
else
	API_KEY="$(openssl rand -hex 32)"
	cat > "$ENV_FILE" <<-EOF
	# Generated by install.sh on $(date -Is)
	MODEL_SIZE=$MODEL_SIZE
	COMPUTE_TYPE=$COMPUTE_TYPE
	CPU_THREADS=$CPU_THREADS
	OMP_NUM_THREADS=$CPU_THREADS
	PORT=$PORT
	MODELS_DIR=$INSTALL_DIR/whisper_models
	API_KEY=$API_KEY
	EOF
	ok "created $ENV_FILE with a fresh API key"
fi

chmod 600 "$ENV_FILE"
mkdir -p "$INSTALL_DIR/whisper_models"

if [ "$SERVICE_USER" != "root" ]; then
	chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
fi

# --------------------------------------------------------------------
# 7. systemd unit
# --------------------------------------------------------------------
step "Installing systemd unit $SERVICE_NAME.service"

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<-EOF
	[Unit]
	Description=faster-whisper-fastapi
	After=network.target

	[Service]
	Type=simple
	User=$SERVICE_USER
	WorkingDirectory=$INSTALL_DIR
	EnvironmentFile=$ENV_FILE
	Environment="PYTHONUNBUFFERED=1"
	ExecStart=$INSTALL_DIR/.venv/bin/python -m uvicorn src.app:app --host $BIND_HOST --port \${PORT} --workers 1
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
EOF

systemctl daemon-reload
ok "unit written"

# --------------------------------------------------------------------
# 8. Start
# --------------------------------------------------------------------
if [ "$START_SERVICE" -eq 1 ]; then
	step "Starting service"
	systemctl enable --quiet --now "$SERVICE_NAME"

	# Ask the address the service actually listens on. A wildcard bind
	# is reachable via loopback; a specific address is not.
	if [ "$BIND_HOST" = "0.0.0.0" ] || [ "$BIND_HOST" = "::" ]; then
		HEALTH_HOST="127.0.0.1"
	else
		HEALTH_HOST="$BIND_HOST"
	fi

	printf '     waiting for the model to load (first run downloads it)'
	deadline=$(( $(date +%s) + WAIT_SECONDS ))
	healthy=0
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if curl -fsS -m 3 "http://$HEALTH_HOST:$PORT/health" >/dev/null 2>&1; then
			healthy=1
			break
		fi
		if ! systemctl is-active --quiet "$SERVICE_NAME"; then
			printf '\n'
			die "service stopped; check: journalctl -u $SERVICE_NAME -n 50"
		fi
		printf '.'
		sleep 5
	done
	printf '\n'

	if [ "$healthy" -eq 1 ]; then
		ok "service is up and answering on $HEALTH_HOST:$PORT"
	else
		warn "no /health response after ${WAIT_SECONDS}s"
		warn "the model download may still be running: journalctl -u $SERVICE_NAME -f"
	fi
else
	step "Skipping start (--no-start)"
	ok "start later with: systemctl enable --now $SERVICE_NAME"
fi

# --------------------------------------------------------------------
# 9. Summary
# --------------------------------------------------------------------
cat <<-EOF

	${C_BOLD}Done.${C_RESET}

	  Install dir   $INSTALL_DIR
	  Service       $SERVICE_NAME (user: $SERVICE_USER)
	  Listening on  $BIND_HOST:$PORT
	  Model         $MODEL_SIZE ($COMPUTE_TYPE, $CPU_THREADS threads)
	  Config        $ENV_FILE (mode 600)

	  ${C_BOLD}API key${C_RESET}       ${API_KEY:-<none, see .env>}

	Test it:

	  curl http://${HEALTH_HOST:-$BIND_HOST}:$PORT/health

	  curl -X POST http://${HEALTH_HOST:-$BIND_HOST}:$PORT/v2/transcribe \\
	    -H "X-API-Key: ${API_KEY:-<key>}" \\
	    -F "audio=@/path/to/file.ogg"

	${C_BOLD}Caddy is not configured by this script.${C_RESET} To expose the service,
	add a site block like this to your Caddyfile and reload Caddy:

	  your.domain.example {
	      request_body {
	          max_size 25MB
	      }
	      reverse_proxy ${HEALTH_HOST:-$BIND_HOST}:$PORT {
	          transport http {
	              read_timeout 30m
	              write_timeout 30m
	          }
	      }
	  }

	A ready-made Caddyfile is in $INSTALL_DIR/Caddyfile.

	Logs:  journalctl -u $SERVICE_NAME -f

EOF
