import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EMAIL_RE = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ENV_FILE = path.join(MODULE_DIR, "gmail-allowlist.env");

export function normalizeEmail(value) {
  return String(value ?? "").trim().toLowerCase();
}

export function extractEmailAddress(rawFrom) {
  const value = String(rawFrom ?? "").trim();
  if (!value) {
    return undefined;
  }

  const angleMatch = value.match(/<([^<>]+)>/);
  const preferred = angleMatch?.[1] ?? value;
  const preferredMatch = preferred.match(EMAIL_RE);
  const fallbackMatch = value.match(EMAIL_RE);
  const email = preferredMatch?.[0] ?? fallbackMatch?.[0];

  return email ? normalizeEmail(email) : undefined;
}

function stripOptionalQuotes(value) {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

export function parseDotEnv(text) {
  const result = {};
  for (const rawLine of String(text ?? "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }
    const equalsAt = line.indexOf("=");
    if (equalsAt <= 0) {
      continue;
    }
    const key = line.slice(0, equalsAt).trim();
    const value = stripOptionalQuotes(line.slice(equalsAt + 1));
    if (key) {
      result[key] = value;
    }
  }
  return result;
}

function readEnvFile(filePath) {
  try {
    if (!filePath || !fs.existsSync(filePath)) {
      return {};
    }
    return parseDotEnv(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    console.warn(`[gmail-allowlist] failed to read env file: ${error.message}`);
    return {};
  }
}

export function parseAllowedSenders(value) {
  return new Set(
    String(value ?? "")
      .split(/[,;\n]+/)
      .map(normalizeEmail)
      .filter(Boolean),
  );
}

export function loadAllowedSenders(options = {}) {
  const env = options.env ?? process.env;
  const envFilePath = options.envFilePath ?? env.GMAIL_ALLOWLIST_ENV_FILE ?? DEFAULT_ENV_FILE;
  const fileEnv = readEnvFile(envFilePath);
  const raw =
    options.allowedSenders ??
    env.GMAIL_ALLOWED_SENDERS ??
    env.GMAIL_ALLOWLIST ??
    fileEnv.GMAIL_ALLOWED_SENDERS ??
    fileEnv.GMAIL_ALLOWLIST ??
    "";

  return parseAllowedSenders(raw);
}

export function isAllowedSender(rawFrom, options = {}) {
  const email = extractEmailAddress(rawFrom);
  const allowedSenders = options.allowedSendersSet ?? loadAllowedSenders(options);
  return Boolean(email && allowedSenders.has(email));
}

function firstMessage(payload) {
  const messages = payload?.messages;
  if (!Array.isArray(messages)) {
    return undefined;
  }
  const [message] = messages;
  return message && typeof message === "object" ? message : undefined;
}

export default function gmailAllowlistTransform({ payload }) {
  const message = firstMessage(payload);
  const from = typeof message?.from === "string" ? message.from : "";
  const email = extractEmailAddress(from);
  const allowedSenders = loadAllowedSenders();

  if (allowedSenders.size === 0) {
    console.info(`[gmail-allowlist] skipped sender=${email ?? "<missing>"} reason=empty-allowlist`);
    return null;
  }

  if (!email || !allowedSenders.has(email)) {
    console.info(`[gmail-allowlist] skipped sender=${email ?? "<missing>"}`);
    return null;
  }

  console.info(`[gmail-allowlist] accepted sender=${email}`);
  return {};
}
