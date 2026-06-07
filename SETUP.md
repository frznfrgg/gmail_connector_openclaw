# OpenClaw Gmail Connector Setup

This runbook documents the clean setup path for a VPS-hosted OpenClaw instance that can receive Gmail messages, process them with an OpenClaw agent, read attachments, and send a Gmail reply to the original sender.

The connector stays outside OpenClaw core. It uses the existing OpenClaw hook mapping system, a small allowlist transform, the `gog` CLI, Gmail Pub/Sub push, and a dedicated Gmail agent.

## Target Architecture

Message flow:

```text
sender email
  -> Gmail inbox
  -> Gmail watch
  -> Google Pub/Sub topic
  -> Pub/Sub push subscription
  -> Tailscale Funnel public URL
  -> gog gmail watch serve on the VPS
  -> OpenClaw /hooks/gmail
  -> gmail-allowlist.mjs
  -> OpenClaw agent "gmail"
  -> gog gmail send
  -> Gmail reply to the original sender
```

Important boundaries:

- OpenClaw core files are not edited.
- Source checkout stays in `/home/openclaw/openclaw_vk`.
- Default/main runtime workspace is `/home/openclaw/openclaw_workspace`.
- Gmail runtime workspace is `/home/openclaw/openclaw_gmail_workspace`.
- Gmail hook runs are routed to agent id `gmail`.
- Broad gateway exec is scoped only to the `gmail` agent.
- The global/default exec policy is returned to `allowlist`.

## Files In This Connector

- `gmail-allowlist.mjs`: webhook transform that accepts only approved sender email addresses.
- `openclaw-gmail-mapping.json`: hook mapping template for Gmail auto-reply behavior.
- `render-mapping.mjs`: renders the mapping template with `GMAIL_ACCOUNT`.
- `install.sh`: installs the transform and Gmail hook mapping into `~/.openclaw`.
- `scope-gmail-agent.sh`: creates/routes the dedicated `gmail` agent and workspace.
- `test-transform.mjs`: local unit checks for the allowlist transform.

## Assumptions

This runbook assumes:

- VPS user is `openclaw`.
- Repo checkout path is `/home/openclaw/openclaw_vk`.
- Main workspace path is `/home/openclaw/openclaw_workspace`.
- Gmail workspace path is `/home/openclaw/openclaw_gmail_workspace`.
- Connector path on the VPS is `/home/openclaw/gmail_connector`.
- Gmail account used by OpenClaw is exported as `GMAIL_ACCOUNT`.
- Google Cloud project id is exported as `GCP_PROJECT`.
- OpenClaw gateway runs as a user systemd service named `openclaw-gateway.service`.
- Tailscale Funnel hostname is already available for the VPS.

If your paths differ, set `MAIN_WS`, `GMAIL_WS`, `GOG_BIN`, or edit the scripts before running them.

## Stage 1: Build OpenClaw

Important: this repo expects OpenClaw version to be `OpenClaw 2026.4.1`
You can use the installation guide below, to install the correct version (its a fork from official OpenClaw repo that also introduces VK messaging channel.)

Install baseline tools:

```bash
sudo apt update
sudo apt install -y git curl ca-certificates build-essential python3
```

Install Node 22 or newer by your preferred method, then verify:

```bash
node -v
npm -v
```

Install the pnpm version used successfully with this repo:

```bash
sudo npm install -g --prefix /usr/local pnpm@10.32.1
export PATH="/usr/local/bin:$PATH"
hash -r
pnpm -v
```

Expected:

```text
10.32.1
```

Clone and build:

```bash
cd /home/openclaw
git clone https://github.com/frznfrgg/openclaw_vk.git openclaw_vk
cd /home/openclaw/openclaw_vk

pnpm config set block-exotic-subdeps false --location project
pnpm install
pnpm build
```

Expose the `openclaw` command globally:

```bash
cd /home/openclaw/openclaw_vk
sudo npm link
hash -r
openclaw --version
```

If you do not want a global link, you can use `pnpm openclaw ...` from the repo, but the systemd gateway flow is simpler when `openclaw` is in `PATH`.

## Stage 2: Create Clean Workspaces

Why: using the source checkout as the agent workspace makes OpenClaw read repository instructions like `AGENTS.md`, which are irrelevant for Gmail processing and can be large. Runtime workspaces keep generated files and agent context away from source code.

Create the main workspace:

```bash
mkdir -p /home/openclaw/openclaw_workspace/skills

openclaw config set agents.defaults.workspace "/home/openclaw/openclaw_workspace"
```

Later, `scope-gmail-agent.sh` will create `/home/openclaw/openclaw_gmail_workspace` for Gmail-only processing.

## Stage 3: Install And Verify Skills

Why: the Gmail auto-reply prompt tells the agent to use the `gog` skill for Google service operations.

During OpenClaw onboarding, install the `gog` and `clawhub` skills if offered. After installation, verify:

```bash
ls -la /home/openclaw/openclaw_workspace/skills/gog/SKILL.md
ls -la /home/openclaw/openclaw_workspace/skills/clawhub/SKILL.md
```

If the skills were installed somewhere else, copy them into the main workspace:

```bash
mkdir -p /home/openclaw/openclaw_workspace/skills
cp -a /path/where/skills/gog /home/openclaw/openclaw_workspace/skills/
cp -a /path/where/skills/clawhub /home/openclaw/openclaw_workspace/skills/
```

The Gmail scoping script copies `skills/gog` from the main workspace into the Gmail workspace.

## Stage 4: Install Required CLIs

Why: the gateway uses local CLIs for the plumbing.

Required commands:

```bash
command -v openclaw
command -v gog
command -v gcloud
command -v tailscale
```

Install these using their official instructions:

- `gog`: the gog CLI used for Gmail, Drive, Docs, and Sheets.
- `gcloud`: Google Cloud CLI for project/API/Pub/Sub setup.
- `tailscale`: provides the public HTTPS Funnel endpoint for Pub/Sub push.

Verify:

```bash
gog --version
gcloud --version
tailscale version
```

## Stage 5: Google Cloud Project And OAuth

Why: two Google auth layers are needed.

- `gcloud` manages Google Cloud resources: APIs, Pub/Sub topic, Pub/Sub subscription.
- `gog` manages user OAuth tokens for the Gmail account: reading messages, downloading attachments, sending replies.

### 5.1 Create Or Choose The Google Cloud Project

Why: Gmail push notifications need a Google Cloud project because Gmail publishes mailbox changes into a Pub/Sub topic owned by that project. The same project also owns the OAuth app configuration that `gog` uses when it asks the Gmail account for permission.

In Google Cloud Console:

1. Open `https://console.cloud.google.com/`.
2. Use the project selector in the top bar.
3. Either choose an existing project or click `New project`.
4. Give it a clear name, for example `openclaw-gmail`.
5. After creation, copy the `Project ID`, not just the display name.

On the VPS, export that project id:

```bash
export GCP_PROJECT="your-project-id"
gcloud auth login
gcloud config set project "$GCP_PROJECT"
gcloud projects describe "$GCP_PROJECT"
```

Expected: `gcloud projects describe` prints the project and `lifecycleState: ACTIVE`.

### 5.2 Enable Required APIs

Why: Google blocks API calls until each API is enabled for the project. This setup needs Gmail for messages, Pub/Sub for push delivery, and optionally Drive/Docs/Sheets because the `gog` skill can work with attached or referenced Google files.

Console path:

1. Open `Google Cloud Console`.
2. Select your project.
3. Go to `APIs & Services` -> `Library`.
4. Search for and enable each API:
   - `Gmail API`
   - `Cloud Pub/Sub API`
   - `Google Drive API`
   - `Google Docs API`
   - `Google Sheets API`

CLI equivalent:

```bash
gcloud services enable \
  gmail.googleapis.com \
  drive.googleapis.com \
  docs.googleapis.com \
  sheets.googleapis.com \
  pubsub.googleapis.com \
  --project "$GCP_PROJECT" \
  --quiet
```

Verify:

```bash
gcloud services list --enabled --project "$GCP_PROJECT" \
  | grep -E 'gmail|pubsub|drive|docs|sheets'
```

### 5.3 Configure Google Auth Platform / OAuth Consent

Why: `gog auth add` opens a Google OAuth consent flow. Google will not issue user tokens for Gmail/Drive/Docs/Sheets until the project has an OAuth consent configuration.

Console path:

1. Open `Google Cloud Console`.
2. Select your project.
3. Go to `Google Auth platform` -> `Branding`.
4. If Google says the Auth platform is not configured, click `Get started`.
5. Under `App information`:
   - `App name`: use something recognizable, for example `OpenClaw Gmail Connector`.
   - `User support email`: choose an email you control.
6. Under `Audience`:
   - For a personal Gmail account or accounts outside one Google Workspace organization, choose `External`.
   - For a Google Workspace-only deployment where the OpenClaw Gmail account is inside your organization, `Internal` can be used if your admin policy allows it.
7. Under `Contact information`, enter your email.
8. Accept the Google API Services User Data Policy and create the app.

If you chose `External`, keep the app in `Testing` mode unless you plan to publish and verify it. Then add test users:

1. Go to `Google Auth platform` -> `Audience`.
2. In `Test users`, click `Add users`.
3. Add the Gmail account that OpenClaw will log into with `gog auth add`.
4. If you later switch the OpenClaw Gmail account, add the new account here before authorizing it.

Important: test users are OAuth users, not email senders. People who only send emails to OpenClaw do not need to be listed here.

### 5.4 Configure OAuth Scopes

Why: the OAuth app should declare the Google Workspace data it may request. This reduces confusing consent prompts and makes it clear why the app needs access.

Console path:

1. Go to `Google Auth platform` -> `Data Access`.
2. Click `Add or remove scopes`.
3. Add scopes for the APIs this connector uses. For a broad private VPS connector, use:
   - `https://www.googleapis.com/auth/gmail.modify`
   - `https://www.googleapis.com/auth/gmail.send`
   - `https://www.googleapis.com/auth/drive`
   - `https://www.googleapis.com/auth/documents`
   - `https://www.googleapis.com/auth/spreadsheets`
4. Save the scope selection.

Notes:

- `gmail.modify` covers reading messages, reading attachments, mailbox history, and Gmail watch operations. `gmail.send` makes the send permission explicit in the consent screen.
- `drive` is broad and restricted, but it matches the "agent may need arbitrary Drive access" behavior. If you want a narrower deployment, start with `https://www.googleapis.com/auth/drive.file` instead and only switch to `drive` if `gog` cannot access the files you need.
- `documents` and `spreadsheets` allow Docs and Sheets operations requested by the `gog` skill.
- For a private testing deployment, do not submit the app for verification unless Google explicitly blocks the exact account you are authorizing. In testing mode, the allowlisted OAuth test users can authorize the app even if the app is not publicly verified.
- External apps in `Testing` mode can receive refresh tokens that expire after 7 days for non-basic scopes. For a long-running VPS, expect to either reauthorize periodically or move the OAuth app out of Testing mode and handle Google's verification requirements for sensitive/restricted scopes.

### 5.5 Create OAuth Client Credentials

Why: `gog` runs as a local CLI on the VPS, so it needs an OAuth Client ID of type `Desktop app`. Do not create a `Web application` client for this flow.

Console path:

1. Go to `Google Auth platform` -> `Clients`.
2. Click `Create Client`.
3. For `Application type`, choose `Desktop app`.
4. Name it, for example `OpenClaw VPS gog`.
5. Click `Create`.
6. Download the client JSON file.

Copy the downloaded JSON to the VPS, for example:

```bash
# Run this from your local machine.
scp ~/Downloads/client_secret_*.json openclaw@your-vps:/home/openclaw/google-oauth-client.json

# Run this on the VPS.
chmod 600 /home/openclaw/google-oauth-client.json
```

The JSON file is private. Do not commit it, paste it into chat, or publish it.

Register the OAuth client with `gog`:

```bash
export GMAIL_ACCOUNT="openclaw-gmail-account@example.com"

gog auth credentials /home/openclaw/google-oauth-client.json
gog auth add "$GMAIL_ACCOUNT" --services gmail,drive,docs,sheets --manual
gog auth list --check
gog auth doctor --check
```

Verify Gmail access:

```bash
gog gmail search 'newer_than:7d in:inbox' --account "$GMAIL_ACCOUNT" --max 5
```

If `gog` uses a file keyring passphrase, the systemd service needs noninteractive access. Set this for the user service:

```bash
systemctl --user edit openclaw-gateway.service
```

Add:

```ini
[Service]
Environment=GOG_KEYRING_PASSWORD=your-keyring-passphrase
```

Then reload:

```bash
systemctl --user daemon-reload
```

Reason: when the gateway handles a Gmail push, there is no TTY for `gog` to ask for the keyring passphrase. Without this, logs contain `no TTY available for keyring file backend password prompt; set GOG_KEYRING_PASSWORD`.

## Stage 6: Tailscale Funnel

Why: Gmail Pub/Sub push needs a public HTTPS endpoint. Tailscale Funnel exposes the local `gog gmail watch serve` HTTP listener.

Enable Tailscale and Funnel:

```bash
sudo tailscale up
sudo tailscale funnel --bg --set-path /gmail-pubsub --yes 8788
tailscale funnel status
```

If the non-root OpenClaw service cannot configure Funnel, allow the `openclaw` user to operate Tailscale:

```bash
sudo tailscale set --operator=openclaw
```

Expected Funnel status should contain a public HTTPS hostname and this path:

```text
/gmail-pubsub proxy http://127.0.0.1:8788
```

## Stage 7: Configure Gmail Pub/Sub Watch

Why: Gmail push notifications are not sent directly to your app. Gmail publishes changes to Pub/Sub; Pub/Sub pushes those changes to your HTTPS endpoint.

Run the OpenClaw helper first:

```bash
cd /home/openclaw/openclaw_vk

export GMAIL_ACCOUNT="openclaw-gmail-account@example.com"
export GCP_PROJECT="your-project-id"

openclaw webhooks gmail setup \
  --account "$GMAIL_ACCOUNT" \
  --project "$GCP_PROJECT" \
  --tailscale funnel \
  --include-body \
  --max-bytes 20000
```

Verify OpenClaw Gmail hook config:

```bash
openclaw config get hooks.gmail
```

Expected important fields:

- `account`: your Gmail account
- `topic`: `projects/<project>/topics/gog-gmail-watch`
- `subscription`: `gog-gmail-watch-push`
- `hookUrl`: `http://127.0.0.1:18789/hooks/gmail`
- `serve.port`: `8788`
- `tailscale.mode`: `funnel`
- `tailscale.path`: `/gmail-pubsub`

If Google Cloud CLI IAM or Pub/Sub commands hang, prefer the Google Cloud Shell fallback below. Cloud Shell runs inside Google's network and is usually more reliable for Pub/Sub setup than a VPS with flaky Google API connectivity. Use the direct API fallback only when Cloud Shell is unavailable.

### Recommended Fallback: Google Cloud Shell

Use this when `openclaw webhooks gmail setup`, `gcloud pubsub ...`, or Pub/Sub `curl` calls hang/fail on the VPS.

First, get the public push endpoint from the VPS. The endpoint has this shape:

```text
https://<tailscale-hostname>/gmail-pubsub?token=<push-token>
```

If `openclaw webhooks gmail setup` already wrote a token, read it from the raw config:

```bash
export TAILSCALE_HOST="$(tailscale funnel status | awk '/^https:\/\// {print $1; exit}')"

python3 - <<'PY'
import json, pathlib, os

cfg = json.load(open(pathlib.Path.home() / ".openclaw" / "openclaw.json"))
gmail = cfg.get("hooks", {}).get("gmail", {})
base = os.environ["TAILSCALE_HOST"].rstrip("/")
path = gmail.get("tailscale", {}).get("path", "/gmail-pubsub")
token = gmail.get("pushToken")
if not token:
    raise SystemExit("hooks.gmail.pushToken is missing; run openclaw webhooks gmail setup once or create a token manually")
print(f"{base}{path}?token={token}")
PY
```

If there is no stored token because setup failed early, create one manually:

```bash
export TAILSCALE_HOST="$(tailscale funnel status | awk '/^https:\/\// {print $1; exit}')"
export PUSH_TOKEN="$(openssl rand -hex 32)"
printf '%s/gmail-pubsub?token=%s\n' "${TAILSCALE_HOST%/}" "$PUSH_TOKEN"
```

Then open Google Cloud Console, start Cloud Shell, and run:

```bash
export GCP_PROJECT="your-project-id"
export PUSH_ENDPOINT="https://<tailscale-hostname>/gmail-pubsub?token=<push-token>"

gcloud config set project "$GCP_PROJECT"

gcloud pubsub topics create gog-gmail-watch || true

gcloud pubsub topics add-iam-policy-binding gog-gmail-watch \
  --member=serviceAccount:gmail-api-push@system.gserviceaccount.com \
  --role=roles/pubsub.publisher \
  --quiet

gcloud pubsub subscriptions create gog-gmail-watch-push \
  --topic gog-gmail-watch \
  --push-endpoint "$PUSH_ENDPOINT" \
  --ack-deadline 10 \
  || gcloud pubsub subscriptions modify-push-config gog-gmail-watch-push \
       --push-endpoint "$PUSH_ENDPOINT"

gcloud pubsub subscriptions describe gog-gmail-watch-push
```

Expected subscription fields:

```text
topic: projects/<project-id>/topics/gog-gmail-watch
pushConfig:
  pushEndpoint: https://<tailscale-hostname>/gmail-pubsub?token=...
state: ACTIVE
```

After Cloud Shell creates or updates the Pub/Sub resources, return to the VPS and make sure `hooks.gmail` points at the same account/project:

```bash
export GMAIL_ACCOUNT="openclaw-gmail-account@example.com"
export GCP_PROJECT="your-project-id"
export TOPIC="projects/${GCP_PROJECT}/topics/gog-gmail-watch"
export PUSH_TOKEN="<push-token-from-the-push-endpoint>"

openclaw config set hooks.gmail.account "$GMAIL_ACCOUNT"
openclaw config set hooks.gmail.label INBOX
openclaw config set hooks.gmail.topic "$TOPIC"
openclaw config set hooks.gmail.subscription gog-gmail-watch-push
openclaw config set hooks.gmail.pushToken "$PUSH_TOKEN"
openclaw config set hooks.gmail.hookUrl "http://127.0.0.1:18789/hooks/gmail"
openclaw config set hooks.gmail.includeBody true --strict-json
openclaw config set hooks.gmail.maxBytes 20000 --strict-json
openclaw config set hooks.gmail.renewEveryMinutes 720 --strict-json
openclaw config set hooks.gmail.serve '{"bind":"127.0.0.1","port":8788,"path":"/"}' --strict-json
openclaw config set hooks.gmail.tailscale '{"mode":"funnel","path":"/gmail-pubsub"}' --strict-json
```

### Direct API Fallback

Set variables:

```bash
export TOKEN="$(gcloud auth print-access-token)"
export TOPIC="projects/${GCP_PROJECT}/topics/gog-gmail-watch"
export SUB="projects/${GCP_PROJECT}/subscriptions/gog-gmail-watch-push"
```

Allow Gmail to publish to the topic:

```bash
curl -4 --http1.1 -sS --connect-timeout 10 --max-time 60 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://pubsub.googleapis.com/v1/${TOPIC}:setIamPolicy" \
  --data '{"policy":{"bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:gmail-api-push@system.gserviceaccount.com"]}]}}'
```

Create or update the push subscription. Use the public push endpoint from your existing subscription or from the OpenClaw setup output. It has this shape:

```text
https://<tailscale-hostname>/gmail-pubsub?token=<push-token>
```

Then:

```bash
export PUSH_ENDPOINT="https://your-tailnet-host/gmail-pubsub?token=your-token"

cat > /tmp/gog-subscription.json <<EOF
{
  "topic": "${TOPIC}",
  "pushConfig": {
    "pushEndpoint": "${PUSH_ENDPOINT}"
  },
  "ackDeadlineSeconds": 10
}
EOF

curl -4 --http1.1 -sS --connect-timeout 10 --max-time 60 -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "https://pubsub.googleapis.com/v1/${SUB}" \
  --data @/tmp/gog-subscription.json
```

If the subscription already exists, update only the push config:

```bash
cat > /tmp/gog-push-config.json <<EOF
{
  "pushConfig": {
    "pushEndpoint": "${PUSH_ENDPOINT}"
  }
}
EOF

curl -4 --http1.1 -sS --connect-timeout 10 --max-time 60 -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "https://pubsub.googleapis.com/v1/${SUB}:modifyPushConfig" \
  --data @/tmp/gog-push-config.json
```

Verify subscription:

```bash
curl -4 --http1.1 -sS --connect-timeout 10 --max-time 60 \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://pubsub.googleapis.com/v1/${SUB}" \
  | python3 -m json.tool
```

Verify Gmail watch:

```bash
gog gmail watch status --account "$GMAIL_ACCOUNT"
```

Expected:

- `last_delivery_status ok` after a test message
- `expiration` about one week in the future
- `history_id` present

## Stage 8: Install This Gmail Connector

Why: the OpenClaw Gmail preset can wake an agent, but this connector adds:

- sender allowlist
- Gmail-in/Gmail-out behavior
- no Telegram/VK delivery
- attachment instructions
- dedicated Gmail agent routing

Copy the connector directory to the VPS:

```bash
scp -r gmail_connector openclaw@your-vps:/home/openclaw/
```

Create the private sender allowlist on the VPS:

```bash
cd /home/openclaw/gmail_connector
cp .env.example .env
nano .env
chmod 600 .env
```

Use this format:

```bash
GMAIL_ACCOUNT=openclaw-gmail-account@example.com
GMAIL_ALLOWED_SENDERS=allowed.user@example.com,trusted.sender@example.org
```

Reason: `gmail-allowlist.mjs` fails closed when no allowlist is configured. `install.sh` copies this private file to `~/.openclaw/hooks/transforms/gmail-allowlist.env` with `0600` permissions so the gateway can read it at runtime. Do not commit or publish `.env`.

Install the hook mapping and transform:

```bash
cd /home/openclaw/gmail_connector
set -a
source .env
set +a
bash install.sh
```

Scope Gmail to its own agent:

```bash
cd /home/openclaw/gmail_connector
bash scope-gmail-agent.sh
```

What `install.sh` does:

- copies `gmail-allowlist.mjs` to `~/.openclaw/hooks/transforms`
- copies `.env` to `~/.openclaw/hooks/transforms/gmail-allowlist.env` when present
- renders `openclaw-gmail-mapping.json` with your Gmail account
- enables hooks
- removes the built-in `gmail` preset to avoid duplicate processing
- replaces existing Gmail-path mappings while preserving unrelated mappings

What `scope-gmail-agent.sh` does:

- keeps `/home/openclaw/openclaw_workspace` as the main workspace
- creates `/home/openclaw/openclaw_gmail_workspace`
- copies the `gog` skill into the Gmail workspace
- adds or replaces agent id `gmail`
- gives only the `gmail` agent `tools.exec.security=full`
- routes Gmail hook mappings to `agentId=gmail`
- restricts explicit hook agent routing to `["gmail"]`
- returns global exec policy to `allowlist`
- restarts the gateway

## Stage 9: Verify Configuration

Run:

```bash
openclaw config get agents.defaults.workspace
openclaw config get agents.list --json | python3 -m json.tool
openclaw config get hooks.mappings --json | python3 -m json.tool
openclaw config get tools.exec --json | python3 -m json.tool
```

Expected:

- `agents.defaults.workspace` is `/home/openclaw/openclaw_workspace`
- `agents.list` has an entry with `"id": "gmail"`
- the `gmail` agent workspace is `/home/openclaw/openclaw_gmail_workspace`
- the `gmail` agent has `tools.exec.security` set to `full`
- the Gmail hook mapping has `"agentId": "gmail"`
- global `tools.exec.security` is `allowlist`, not `full`

Verify workspace files:

```bash
tree /home/openclaw/openclaw_workspace
tree /home/openclaw/openclaw_gmail_workspace
```

Expected Gmail workspace:

```text
openclaw_gmail_workspace/
├── AGENTS.md
├── skills
│   └── gog
│       └── SKILL.md
└── tmp
```

## Stage 10: Test End To End

Watch logs:

```bash
journalctl --user -u openclaw-gateway.service -f
```

Send an email from an allowlisted sender to the OpenClaw Gmail account.

Expected logs:

```text
[gmail-allowlist] accepted sender=<allowed-email>
sessionKey=agent:gmail:hook:gmail:<message-id>
```

After OpenClaw sends the reply, Gmail will emit another event for the sent/self message. This is expected:

```text
[gmail-allowlist] skipped sender=<openclaw-gmail-account>
```

That line means the self-reply was skipped and no email loop happened.

Confirm sent mail:

```bash
gog gmail search 'newer_than:30m in:sent to:sender@example.com' \
  --account "$GMAIL_ACCOUNT" \
  --max 5
```

Test rejection:

1. Send an email from a non-allowlisted sender.
2. Logs should show `skipped sender=...`.
3. No reply should be sent.

## Sender Allowlist

Allowed senders are stored in private env files, not in committed source.

Local connector file:

```bash
/home/openclaw/gmail_connector/.env
```

Installed runtime file:

```bash
~/.openclaw/hooks/transforms/gmail-allowlist.env
```

Supported keys:

```bash
GMAIL_ALLOWED_SENDERS=allowed.user@example.com,trusted.sender@example.org
```

or:

```bash
GMAIL_ALLOWLIST=allowed.user@example.com;trusted.sender@example.org
```

To change the allowlist:

1. Edit `/home/openclaw/gmail_connector/.env`.
2. Rerun:

```bash
cd /home/openclaw/gmail_connector
export GMAIL_ACCOUNT="openclaw-gmail-account@example.com"
bash install.sh
openclaw gateway restart
```

Reason: `install.sh` copies both the transform and the private allowlist env file into `~/.openclaw/hooks/transforms`.

## Attachment Behavior

The connector does not parse attachments itself. It prompts the agent to use `gog` commands:

- `gog gmail get --format full --json`
- `gog gmail attachment ... --out ...`
- `gog gmail thread get --download ...`

The agent can then read downloaded files from disk, summarize them, and attach generated files to replies using:

```bash
gog gmail send \
  --account "$GMAIL_ACCOUNT" \
  --to "sender@example.com" \
  --subject "Re: original subject" \
  --reply-to-message-id "gmail-message-id" \
  --body-file reply.txt \
  --attach file1 \
  --attach file2 \
  --no-input \
  --yes
```

This was tested with image and PDF attachments. Browser-preview failures on a headless VPS are not fatal unless the task requires visual/browser verification.

## Security Model

Hard controls:

- Gmail ingress is protected by the webhook token generated in `hooks.gmail.pushToken`.
- Gmail processing is sender-allowlisted by `gmail-allowlist.mjs`.
- OpenClaw self-sent replies are skipped by the allowlist.
- Gmail hook mappings are routed to `agentId=gmail`.
- `hooks.allowedAgentIds` is set to `["gmail"]`.
- Broad gateway exec is scoped to the `gmail` agent.
- Global/default exec policy is returned to `allowlist`.

Soft controls:

- The Gmail agent prompt says to stay in email scope.
- The Gmail workspace `AGENTS.md` says not to send chat notifications.
- The mapping has `deliver=false`, so OpenClaw does not deliver the agent final message to Telegram/VK.

Known tradeoff:

- `allowUnsafeExternalContent=true` is set for this mapping so the agent can act on email body text directly. This is intentionally powerful and should remain paired with a strict sender allowlist.

## Troubleshooting

### No reaction to email

Check:

```bash
gog gmail watch status --account "$GMAIL_ACCOUNT"
tailscale funnel status
openclaw config get hooks.gmail
journalctl --user -u openclaw-gateway.service -n 200 --no-pager \
  | grep -Ei 'gmail|gog|hook|tailscale'
```

Look for:

- `gmail watcher started`
- `watch: listening on 127.0.0.1:8788/`
- `last_delivery_status ok`

### Email accepted but no reply

Check for:

```text
exec denied: allowlist miss
pairing required
```

If you see this, Gmail is not running under the scoped `gmail` agent or the scoped config was not applied. Verify:

```bash
openclaw config get hooks.mappings --json | python3 -m json.tool
openclaw config get agents.list --json | python3 -m json.tool
```

The mapping must contain:

```json
"agentId": "gmail"
```

The Gmail agent must contain:

```json
"tools": {
  "exec": {
    "security": "full",
    "ask": "off"
  }
}
```

### Log shows source repo AGENTS.md truncation

Example:

```text
workspace bootstrap file AGENTS.md is 35212 chars (limit 20000); truncating
```

This means the active agent workspace points at the source checkout. Fix:

```bash
openclaw config set agents.defaults.workspace "/home/openclaw/openclaw_workspace"
bash /home/openclaw/gmail_connector/scope-gmail-agent.sh
```

Gmail logs should use:

```text
agent:gmail:hook:gmail:
```

### Keyring asks for passphrase in logs

Example:

```text
no TTY available for keyring file backend password prompt; set GOG_KEYRING_PASSWORD
```

Fix the systemd user service environment:

```bash
systemctl --user edit openclaw-gateway.service
systemctl --user daemon-reload
openclaw gateway restart
```

Add:

```ini
[Service]
Environment=GOG_KEYRING_PASSWORD=your-keyring-passphrase
```

### Browser errors on VPS

Examples:

```text
Navigation blocked: unsupported protocol "file:"
No supported browser found
```

This means the agent tried to preview generated HTML or another local artifact in a browser. It is not fatal if the Gmail reply was sent. Options:

- ignore it for non-browser tasks
- install Chromium on the VPS
- adjust `AGENTS.md` in the Gmail workspace to say not to use browser preview unless required

### OpenClaw sent reply triggers another Gmail event

Expected:

```text
[gmail-allowlist] skipped sender=<openclaw-gmail-account>
```

This is good. It prevents reply loops.

## Rollback

Disable the connector mapping:

```bash
openclaw config set hooks.mappings '[]' --strict-json
openclaw gateway restart
```

Restore built-in Gmail preset behavior:

```bash
openclaw config set hooks.presets '["gmail"]' --strict-json
openclaw gateway restart
```

Remove the scoped Gmail agent:

```bash
openclaw config get agents.list --json >/tmp/openclaw-agents-list.json

python3 - <<'PY' >/tmp/openclaw-agents-list.next.json
import json
agents = json.load(open("/tmp/openclaw-agents-list.json"))
agents = [
    a for a in agents
    if not (isinstance(a, dict) and str(a.get("id", "")).lower() == "gmail")
]
print(json.dumps(agents, ensure_ascii=False))
PY

openclaw config set agents.list "$(cat /tmp/openclaw-agents-list.next.json)" --strict-json
openclaw gateway restart
```

Remove Gmail workspace if no longer needed:

```bash
rm -rf /home/openclaw/openclaw_gmail_workspace
```

## Development Notes

To test connector code locally:

```bash
cd gmail_connector
node test-transform.mjs
GMAIL_ACCOUNT=openclaw@example.com node render-mapping.mjs | python3 -m json.tool >/dev/null
bash -n install.sh
bash -n scope-gmail-agent.sh
```

When changing the mapping prompt:

1. Edit `openclaw-gmail-mapping.json`.
2. Run `render-mapping.mjs`.
3. Copy the connector to the VPS.
4. Rerun `install.sh`.
5. Restart the gateway.

When changing sender authorization:

1. Edit `.env` on the VPS, or update `.env.example` only with placeholder/demo values.
2. Run `node test-transform.mjs`.
3. Rerun `install.sh`.
4. Restart the gateway.
