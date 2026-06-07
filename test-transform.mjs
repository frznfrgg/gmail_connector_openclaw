import assert from "node:assert/strict";
import transform, {
  extractEmailAddress,
  isAllowedSender,
  loadAllowedSenders,
  parseAllowedSenders,
  parseDotEnv,
} from "./gmail-allowlist.mjs";

const allowedSenders = "allowed.user@example.com, trusted.sender@example.org";
const testOptions = { env: { GMAIL_ALLOWED_SENDERS: allowedSenders } };

assert.equal(extractEmailAddress("allowed.user@example.com"), "allowed.user@example.com");
assert.equal(
  extractEmailAddress('"Allowed User" <ALLOWED.USER@example.com>'),
  "allowed.user@example.com",
);
assert.equal(extractEmailAddress("bad input"), undefined);

assert.deepEqual(parseDotEnv('GMAIL_ALLOWED_SENDERS="a@example.com,b@example.com"\n# ignored'), {
  GMAIL_ALLOWED_SENDERS: "a@example.com,b@example.com",
});
assert.deepEqual(
  [...parseAllowedSenders("A@example.com; b@example.com\nc@example.com")],
  ["a@example.com", "b@example.com", "c@example.com"],
);
assert.deepEqual([...loadAllowedSenders(testOptions)], [
  "allowed.user@example.com",
  "trusted.sender@example.org",
]);

assert.equal(isAllowedSender("trusted.sender@example.org", testOptions), true);
assert.equal(isAllowedSender('"Allowed" <ALLOWED.USER@EXAMPLE.COM>', testOptions), true);
assert.equal(isAllowedSender("blocked@example.com", testOptions), false);

process.env.GMAIL_ALLOWED_SENDERS = allowedSenders;
try {
  assert.deepEqual(
    transform({
      payload: { messages: [{ from: '"Allowed" <allowed.user@example.com>' }] },
    }),
    {},
  );
  assert.equal(
    transform({
      payload: { messages: [{ from: "blocked@example.com" }] },
    }),
    null,
  );
  assert.equal(transform({ payload: { messages: [{}] } }), null);
} finally {
  delete process.env.GMAIL_ALLOWED_SENDERS;
}

console.log("gmail-allowlist transform tests passed");
