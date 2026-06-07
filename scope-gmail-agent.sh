#!/usr/bin/env bash
set -euo pipefail

MAIN_WS="${MAIN_WS:-/home/openclaw/openclaw_workspace}"
GMAIL_WS="${GMAIL_WS:-/home/openclaw/openclaw_gmail_workspace}"
GOG_BIN="${GOG_BIN:-$(command -v gog)}"
GOG_DIR="$(dirname "$GOG_BIN")"

mkdir -p "$MAIN_WS" "$GMAIL_WS/skills" "$GMAIL_WS/tmp"

cp -a "$MAIN_WS/skills/gog" "$GMAIL_WS/skills/" 2>/dev/null \
  || cp -a /home/openclaw/openclaw_vk/skills/gog "$GMAIL_WS/skills/"

cat > "$GMAIL_WS/AGENTS.md" <<'EOF'
This workspace is dedicated to Gmail hook processing.

Rules:
- Stay within email scope.
- Do not send Telegram, VK, or chat notifications.
- Reply only by Gmail to the original sender.
- Use gog for Gmail, Drive, Docs, and Sheets operations when needed.
- Keep temporary and generated files outside the source repository.
EOF

openclaw config set agents.defaults.workspace "$MAIN_WS"

openclaw config get agents.list --json >/tmp/openclaw-agents-list.json 2>/dev/null \
  || printf '[]' >/tmp/openclaw-agents-list.json

MAIN_WS="$MAIN_WS" GMAIL_WS="$GMAIL_WS" GOG_DIR="$GOG_DIR" python3 - <<'PY' >/tmp/openclaw-agents-list.next.json
import json, os

raw = open("/tmp/openclaw-agents-list.json").read().strip()
agents = json.loads(raw) if raw else []
if not isinstance(agents, list):
    agents = []

if not agents:
    agents.append({
        "id": "main",
        "default": True,
        "workspace": os.environ["MAIN_WS"],
    })

agents = [
    a for a in agents
    if not (isinstance(a, dict) and str(a.get("id", "")).lower() == "gmail")
]

agents.append({
    "id": "gmail",
    "name": "Gmail Auto Reply",
    "workspace": os.environ["GMAIL_WS"],
    "skills": ["gog"],
    "tools": {
        "exec": {
            "host": "gateway",
            "security": "full",
            "ask": "off",
            "pathPrepend": [
                os.environ["GOG_DIR"],
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
        }
    }
})

print(json.dumps(agents, ensure_ascii=False))
PY

openclaw config set agents.list "$(cat /tmp/openclaw-agents-list.next.json)" --strict-json

openclaw config get hooks.mappings --json >/tmp/openclaw-hooks-mappings.json

python3 - <<'PY' >/tmp/openclaw-hooks-mappings.next.json
import json

mappings = json.load(open("/tmp/openclaw-hooks-mappings.json"))
for mapping in mappings:
    match = mapping.get("match") or {}
    if mapping.get("id") == "gmail-auto-reply" or match.get("path") == "gmail":
        mapping["agentId"] = "gmail"

print(json.dumps(mappings, ensure_ascii=False))
PY

openclaw config set hooks.mappings "$(cat /tmp/openclaw-hooks-mappings.next.json)" --strict-json
openclaw config set hooks.allowedAgentIds '["gmail"]' --strict-json

openclaw config set tools.exec.security allowlist
openclaw config set tools.exec.ask off

openclaw approvals allowlist remove --agent "*" "$GOG_BIN" || true

openclaw gateway restart
