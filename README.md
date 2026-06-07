# Gmail Connector

Self-contained Gmail auto-reply setup for OpenClaw.

This does not modify OpenClaw core files. It installs a hook mapping and an allowlist transform into the existing OpenClaw hook system, then routes Gmail hook runs to a dedicated `gmail` agent.

For the full VPS setup runbook, start with [SETUP.md](SETUP.md).

## Behavior

- Allowed senders trigger one OpenClaw agent run under agent id `gmail`.
- Non-allowed senders are silently skipped.
- OpenClaw chat delivery is disabled with `deliver: false`.
- The agent is instructed to send exactly one Gmail reply using `gog gmail send`.
- Replies go only to the original `From` sender, never reply-all.
- Reasoning level is `medium`.
- Agent timeout is `300` seconds.
- Attachments are handled by agent instructions using `gog` commands.
- The dedicated Gmail agent gets broad gateway exec for `gog` and helper commands.
- The default/global exec policy can stay in `allowlist` mode for Telegram/VK.
- The installer preserves non-Gmail hook mappings and replaces existing Gmail-path mappings.

Phase 1 limitation: timeout replies are best-effort. Because the agent itself sends the email in this phase, a hard agent timeout can stop the run before any timeout email is sent.

## Allowlist

The transform reads allowed senders from a private `.env` file, case-insensitively.

```bash
cp .env.example .env
$EDITOR .env
```

Format:

```bash
GMAIL_ALLOWED_SENDERS=allowed.user@example.com,trusted.sender@example.org
```

`install.sh` copies `.env` to `~/.openclaw/hooks/transforms/gmail-allowlist.env` with `0600` permissions. The runtime transform fails closed when no allowlist is configured.

## Local Checks

From this directory:

```bash
node test-transform.mjs
GMAIL_ACCOUNT=openclaw@example.com node render-mapping.mjs | python3 -m json.tool >/dev/null
bash -n install.sh
bash -n scope-gmail-agent.sh
```

## Install On VPS

Copy this directory to the VPS, then run as the same user that runs OpenClaw:

```bash
cd /path/to/gmail_connector
cp .env.example .env
$EDITOR .env
export GMAIL_ACCOUNT=openclaw-gmail-account@example.com
bash install.sh
bash scope-gmail-agent.sh
openclaw gateway restart
```

Verify:

```bash
openclaw config get agents.list --json | python3 -m json.tool
openclaw config get hooks.mappings --json | python3 -m json.tool
journalctl --user -u openclaw-gateway.service -f
```

Send one email from an allowlisted address and confirm exactly one Gmail reply. Logs should include `agent:gmail:hook:gmail:`. Then send one email from a non-allowlisted address and confirm there is no reply.

## Rollback

To disable this mapping:

```bash
openclaw config set hooks.mappings '[]' --strict-json
openclaw gateway restart
```

To restore the default Gmail preset behavior:

```bash
openclaw config set hooks.presets '["gmail"]' --strict-json
openclaw gateway restart
```
