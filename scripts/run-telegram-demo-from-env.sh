#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
PICO_HOME="${PICOCLAW_HOME:-$ROOT_DIR/.picoclaw-demo}"
SEC_FILE="$PICO_HOME/.security.yml"
export PICOCLAW_HOME="$PICO_HOME"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

: "${OPENAI_API_KEY:?OPENAI_API_KEY is required (set it in .env)}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required (set it in .env)}"
: "${TELEGRAM_USER_ID:?TELEGRAM_USER_ID is required to restrict bot access (set it in .env)}"

mkdir -p "$PICO_HOME"

if [[ ! -f "$PICO_HOME/config.json" ]]; then
  go run -tags goolm,stdjson ./cmd/picoclaw onboard >/dev/null
fi

# Keep sensitive values out of config.json and materialize them from .env at run time.
cat > "$SEC_FILE" <<EOF
channels:
  telegram:
    token: "${TELEGRAM_BOT_TOKEN}"
model_list:
  gpt-5-nano:0:
    api_keys:
      - "${OPENAI_API_KEY}"
EOF

if [[ -n "${TAVILY_API_KEY:-}" ]]; then
  cat >> "$SEC_FILE" <<EOF
web:
  tavily:
    api_keys:
      - "${TAVILY_API_KEY}"
EOF
fi
chmod 600 "$SEC_FILE"

allow_items=()
IFS=',' read -r -a raw_allow_items <<< "${TELEGRAM_USER_ID}"
for raw in "${raw_allow_items[@]}"; do
  item="${raw#"${raw%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  [[ -z "$item" ]] && continue
  allow_items+=("$item")
  if [[ "$item" =~ ^-?[0-9]+$ ]]; then
    allow_items+=("telegram:${item}")
  elif [[ "$item" != @* && "$item" != *:* ]]; then
    allow_items+=("@${item}")
  fi
done
if [[ ${#allow_items[@]} -eq 0 ]]; then
  echo "TELEGRAM_USER_ID resolved to empty allow list" >&2
  exit 1
fi
allow_csv="$(IFS=,; echo "${allow_items[*]}")"
export PICOCLAW_CHANNELS_TELEGRAM_ALLOW_FROM="${allow_csv}"
echo "Telegram allow_from: ${allow_csv}" >&2

if [[ -n "${TAVILY_API_KEY:-}" ]]; then
  export PICOCLAW_TOOLS_WEB_TAVILY_ENABLED=true
  export PICOCLAW_TOOLS_WEB_TAVILY_API_KEYS="${TAVILY_API_KEY}"
fi

# gpt-5-nano does not accept native web_search_preview tool payloads.
# Force client-side web tool path (Tavily/DDG/etc.) to avoid 400 errors.
export PICOCLAW_TOOLS_WEB_PREFER_NATIVE=false

# gpt-5-nano only supports default temperature (1).
export PICOCLAW_AGENTS_DEFAULTS_TEMPERATURE=1

cd "$ROOT_DIR"
exec go run -tags goolm,stdjson ./cmd/picoclaw gateway
