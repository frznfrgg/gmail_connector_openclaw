import { readFile } from "node:fs/promises";

const account = process.env.GMAIL_ACCOUNT?.trim();
if (!account) {
  console.error("GMAIL_ACCOUNT is required, for example: export GMAIL_ACCOUNT=openclaw@example.com");
  process.exit(2);
}

const templateUrl = new URL("./openclaw-gmail-mapping.json", import.meta.url);
const mapping = JSON.parse(await readFile(templateUrl, "utf8"));

for (const entry of mapping) {
  if (typeof entry.messageTemplate === "string") {
    entry.messageTemplate = entry.messageTemplate.replaceAll("__GMAIL_ACCOUNT__", account);
  }
}

console.log(JSON.stringify(mapping, null, 2));
