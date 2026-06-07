#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GMAIL_ACCOUNT:-}" ]]; then
  echo "GMAIL_ACCOUNT is required, for example:" >&2
  echo "  export GMAIL_ACCOUNT=openclaw@example.com" >&2
  exit 2
fi

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw command not found in PATH" >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node command not found in PATH" >&2
  exit 2
fi

if ! command -v gog >/dev/null 2>&1; then
  echo "gog command not found in PATH" >&2
  exit 2
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
TRANSFORMS_DIR="$OPENCLAW_CONFIG_DIR/hooks/transforms"
ALLOWLIST_ENV_SOURCE="${GMAIL_ALLOWLIST_ENV_FILE:-$SCRIPT_DIR/.env}"
ALLOWLIST_ENV_TARGET="$TRANSFORMS_DIR/gmail-allowlist.env"
MAPPING_FILE="$(mktemp)"
trap 'rm -f "$MAPPING_FILE"' EXIT

mkdir -p "$TRANSFORMS_DIR"
cp "$SCRIPT_DIR/gmail-allowlist.mjs" "$TRANSFORMS_DIR/gmail-allowlist.mjs"

if [[ -f "$ALLOWLIST_ENV_SOURCE" ]]; then
  cp "$ALLOWLIST_ENV_SOURCE" "$ALLOWLIST_ENV_TARGET"
  chmod 600 "$ALLOWLIST_ENV_TARGET"
elif [[ -z "${GMAIL_ALLOWED_SENDERS:-}" && ! -f "$ALLOWLIST_ENV_TARGET" ]]; then
  echo "Gmail sender allowlist is required." >&2
  echo "Create $SCRIPT_DIR/.env from .env.example, or set GMAIL_ALLOWED_SENDERS." >&2
  exit 2
fi

GMAIL_ACCOUNT="$GMAIL_ACCOUNT" node "$SCRIPT_DIR/render-mapping.mjs" > "$MAPPING_FILE"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$MAPPING_FILE"

CURRENT_PRESETS="$(openclaw config get hooks.presets --json 2>/dev/null || printf '[]')"
NEXT_PRESETS="$(
  node -e '
    let presets = [];
    try {
      const parsed = JSON.parse(process.argv[1] || "[]");
      if (Array.isArray(parsed)) presets = parsed;
    } catch {}
    const next = presets.filter((value) => value !== "gmail");
    console.log(JSON.stringify(next));
  ' "$CURRENT_PRESETS"
)"

MAPPING_JSON="$(<"$MAPPING_FILE")"
CURRENT_MAPPINGS="$(openclaw config get hooks.mappings --json 2>/dev/null || printf '[]')"
FINAL_MAPPINGS="$(
  node -e '
    let current = [];
    try {
      const parsed = JSON.parse(process.argv[1] || "[]");
      if (Array.isArray(parsed)) current = parsed;
    } catch {}
    const incoming = JSON.parse(process.argv[2]);
    const isGmailMapping = (entry) =>
      entry &&
      typeof entry === "object" &&
      (entry.id === "gmail-auto-reply" || entry.match?.path === "gmail");
    const preserved = current.filter((entry) => !isGmailMapping(entry));
    console.log(JSON.stringify([...preserved, ...incoming], null, 2));
  ' "$CURRENT_MAPPINGS" "$MAPPING_JSON"
)"

openclaw config set hooks.enabled true --strict-json
openclaw config set hooks.presets "$NEXT_PRESETS" --strict-json
openclaw config set hooks.mappings "$FINAL_MAPPINGS" --strict-json

echo
echo "Installed Gmail allowlist transform:"
echo "  $TRANSFORMS_DIR/gmail-allowlist.mjs"
echo "Installed Gmail allowlist env:"
echo "  $ALLOWLIST_ENV_TARGET"
echo
echo "Applied hooks.mappings for Gmail auto-reply with thinking=medium and timeoutSeconds=300."
echo "Preserved non-Gmail hook mappings and replaced existing Gmail-path mappings."
echo "Removed the built-in gmail preset from hooks.presets to avoid duplicate Gmail handling."
echo
echo "Recommended next commands:"
echo "  openclaw gateway restart"
echo "  openclaw config get hooks.mappings --json | python3 -m json.tool"
echo "  journalctl --user -u openclaw-gateway.service -f"
