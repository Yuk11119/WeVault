import test from "node:test";
import assert from "node:assert/strict";
import type { Config } from "../src/config.ts";
import { createApp } from "../src/app.ts";
import { issueAccess } from "../src/security.ts";

const config: Config = {
  NODE_ENV: "test", HOST: "127.0.0.1", PORT: 31061,
  DATABASE_URL: "postgres://unused", DATABASE_SSL: "false",
  JWT_SECRET: "j".repeat(32), REFRESH_TOKEN_PEPPER: "p".repeat(32), INITIAL_INVITE_ADMIN_SECRET: "i".repeat(32),
  API_BASE_URL: "https://api.example.test", ALLOWED_ORIGINS: "https://app.example.test",
  MAIL_HOST: "smtp.example.test", MAIL_PORT: 465, MAIL_USER: "user", MAIL_PASSWORD: "password", MAIL_FROM: "no-reply@example.test",
  OSS_BUCKET: "private-bucket", OSS_REGION: "cn-hangzhou", OSS_ENDPOINT: "https://oss.example.test",
  ECS_RAM_ROLE_NAME: "test-role", OSS_UPLOAD_ROLE_ARN: "acs:ram::1:role/upload", OSS_DOWNLOAD_ROLE_ARN: "acs:ram::1:role/download"
};

const emptyDB = {
  async query() { return { rowCount: 0, rows: [] }; },
  async connect() { throw new Error("database must not be reached by this contract test"); }
};
const mailer = { async sendVerification() {} };
const objectStore = {
  async issue() { throw new Error("object store must not be reached by this contract test"); },
  async head() { throw new Error("object store must not be reached by this contract test"); }
};

const appForTest = () => createApp({ config, db: emptyDB as never, mailer, objectStore });

test("HTTP contract returns stable validation and authentication errors", async () => {
  const app = await appForTest();
  try {
    const registration = await app.inject({ method: "POST", url: "/v1/auth/register", payload: { email: "not-an-email" } });
    assert.equal(registration.statusCode, 400); assert.deepEqual(registration.json(), { error: { code: "INVALID_INPUT", message: "Invalid request" } });
    const device = await app.inject({ method: "POST", url: "/v1/devices", payload: {} });
    assert.equal(device.statusCode, 401); assert.equal(device.json().error.code, "AUTH_UNAUTHORIZED");
    const token = issueAccess(config, "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002");
    const object = await app.inject({ method: "POST", url: "/v1/objects/upload-authorizations", headers: { authorization: `Bearer ${token}` }, payload: {} });
    assert.equal(object.statusCode, 400); assert.equal(object.json().error.code, "INVALID_INPUT");
  } finally { await app.close(); }
});

test("verification endpoint is limited with a stable error code", async () => {
  const app = await appForTest();
  try {
    for (let index = 0; index < 8; index += 1) {
      const response = await app.inject({ method: "POST", url: "/v1/auth/verify-email", payload: { email: "bad", code: "no" } });
      assert.equal(response.statusCode, 400);
      assert.equal(response.json().error.code, "INVALID_INPUT");
    }
    const limited = await app.inject({ method: "POST", url: "/v1/auth/verify-email", payload: { email: "bad", code: "no" } });
    assert.equal(limited.statusCode, 429); assert.equal(limited.json().error.code, "RATE_LIMITED");
  } finally { await app.close(); }
});
