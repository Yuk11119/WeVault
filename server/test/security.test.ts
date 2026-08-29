import test from "node:test";
import assert from "node:assert/strict";
import { digest, hashPassword, sameDigest, verifyPassword } from "../src/security.ts";
import { objectKeyFor, policyFor } from "../src/oss.ts";

test("passwords use Argon2id and verify", async () => {
  const hash = await hashPassword("a sufficiently long beta password");
  assert.match(hash, /^\$argon2id\$/); assert.equal(await verifyPassword(hash, "a sufficiently long beta password"), true); assert.equal(await verifyPassword(hash, "wrong password value"), false);
});
test("object key hides filename and isolates user/device", () => {
  const sha = "a".repeat(64); const key = objectKeyFor("user-1", "device-1", sha);
  assert.equal(key, `users/user-1/devices/device-1/objects/sha256/aa/aa/${sha}`); assert.doesNotMatch(key, /invoice|\.zip/);
  const policy = policyFor("bucket", key, "upload"); assert.match(policy, /PutObject/); assert.doesNotMatch(policy, /GetObject/);
});
test("opaque values are peppered before persistence", () => {
  const stored = digest("secret", "pepper"); assert.notEqual(stored, "secret"); assert.equal(sameDigest(stored, digest("secret", "pepper")), true);
});
