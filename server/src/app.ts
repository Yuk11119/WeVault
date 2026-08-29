import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Config } from "./config.js";
import type { Database } from "./db.js";
import { audit, transaction } from "./db.js";
import { ApiError, errors, fail } from "./errors.js";
import type { Mailer } from "./mail.js";
import type { ObjectStore } from "./oss.js";
import { objectKeyFor } from "./oss.js";
import { digest, hashPassword, issueAccess, opaqueToken, sameDigest, verificationCode, verifyAccess, verifyPassword } from "./security.js";

const email = z.string().trim().toLowerCase().email().max(254);
const password = z.string().min(12).max(256);
const sha256 = z.string().regex(/^[a-f0-9]{64}$/);
const uuid = z.string().uuid();
const bearer = (request: FastifyRequest) => request.headers.authorization?.match(/^Bearer (.+)$/i)?.[1];
type Auth = { userID: string; sessionID: string };

const auth = (config: Config, request: FastifyRequest): Auth => {
  const token = bearer(request); if (!token) throw errors.unauthorized();
  try { const claims = verifyAccess(config, token); return { userID: claims.sub, sessionID: claims.sid }; }
  catch { throw errors.unauthorized(); }
};
const ownDevice = async (db: Database, userID: string, deviceID: string) => {
  const found = await db.query("SELECT id FROM devices WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL", [deviceID, userID]);
  if (!found.rowCount) throw errors.forbidden();
};
const tokenPair = async (db: Database, config: Config, userID: string) => transaction(db, async client => {
  const sessionID = randomUUID(); const refreshToken = opaqueToken();
  await client.query("INSERT INTO sessions (id,user_id,refresh_token_hash,expires_at) VALUES ($1,$2,$3,now() + interval '30 days')", [sessionID, userID, digest(refreshToken, config.REFRESH_TOKEN_PEPPER)]);
  return { accessToken: issueAccess(config, userID, sessionID), refreshToken, expiresIn: 900 };
});

export const createApp = async (deps: { config: Config; db: Database; mailer: Mailer; objectStore: ObjectStore }): Promise<FastifyInstance> => {
  const { config, db, mailer, objectStore } = deps;
  const app = Fastify({ logger: { redact: ["req.headers.authorization", "req.body.password", "req.body.refreshToken", "req.body.code", "res.body.accessToken", "res.body.refreshToken"] } });
  await app.register(cors, { origin: config.ALLOWED_ORIGINS.split(",").map(value => value.trim()), credentials: false });
  await app.register(rateLimit, {
    global: true,
    max: 120,
    timeWindow: "1 minute"
  });
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) return fail(reply, error);
    if ((error as { code?: string; statusCode?: number }).code === "FST_ERR_RATE_LIMIT" || (error as { statusCode?: number }).statusCode === 429) {
      return fail(reply, new ApiError("RATE_LIMITED", 429, "Too many requests"));
    }
    if (error instanceof z.ZodError) return fail(reply, errors.invalidInput());
    request.log.error({ err: error, requestId: request.id }, "Unhandled API error");
    return reply.status(500).send({ error: { code: "INTERNAL_ERROR", message: "Internal server error" } });
  });
  app.get("/healthz", async () => { await db.query("SELECT 1"); return { status: "ok" }; });

  app.post("/v1/auth/register", { config: { rateLimit: { max: 5, timeWindow: "1 hour" } } }, async (request, reply) => {
    const body = z.object({ email, password, invitationCode: z.string().min(12).max(128) }).parse(request.body);
    const invitationHash = digest(body.invitationCode, config.REFRESH_TOKEN_PEPPER); const userID = randomUUID(); const code = verificationCode();
    await transaction(db, async client => {
      const invite = await client.query("UPDATE invitations SET used_count=used_count+1 WHERE code_hash=$1 AND revoked_at IS NULL AND used_count < max_uses AND (expires_at IS NULL OR expires_at > now()) RETURNING id", [invitationHash]);
      if (!invite.rowCount) throw errors.invitation();
      try { await client.query("INSERT INTO users (id,email,password_hash) VALUES ($1,$2,$3)", [userID, body.email, await hashPassword(body.password)]); }
      catch (error: unknown) { await client.query("UPDATE invitations SET used_count=used_count-1 WHERE id=$1", [invite.rows[0]!.id]); throw errors.conflict("Email is already registered"); }
      await client.query("INSERT INTO email_verifications (id,user_id,code_hash,expires_at) VALUES ($1,$2,$3,now() + interval '15 minutes')", [randomUUID(), userID, digest(code, config.REFRESH_TOKEN_PEPPER)]);
    });
    await mailer.sendVerification(body.email, code); await audit(db, "REGISTERED", { email: body.email }, userID);
    return reply.status(202).send({ status: "VERIFICATION_REQUIRED" });
  });
  app.post("/v1/auth/verify-email", { config: { rateLimit: { max: 8, timeWindow: "15 minutes" } } }, async request => {
    const body = z.object({ email, code: z.string().regex(/^\d{6}$/) }).parse(request.body);
    const result = await db.query("UPDATE users SET email_verified_at=now() WHERE email=$1 AND EXISTS (SELECT 1 FROM email_verifications v WHERE v.user_id=users.id AND v.code_hash=$2 AND v.expires_at > now() AND v.consumed_at IS NULL) RETURNING id", [body.email, digest(body.code, config.REFRESH_TOKEN_PEPPER)]);
    if (!result.rowCount) throw errors.verification();
    await db.query("UPDATE email_verifications SET consumed_at=now() WHERE user_id=$1 AND consumed_at IS NULL", [result.rows[0]!.id]);
    await audit(db, "EMAIL_VERIFIED", {}, result.rows[0]!.id); return { status: "VERIFIED" };
  });
  app.post("/v1/auth/resend-verification", { config: { rateLimit: { max: 3, timeWindow: "15 minutes" } } }, async request => {
    const body = z.object({ email }).parse(request.body);
    const user = await db.query("SELECT id,email_verified_at FROM users WHERE email=$1 AND disabled_at IS NULL", [body.email]);
    // Keep the response invariant so this endpoint cannot be used to enumerate accounts.
    if (!user.rowCount || user.rows[0]!.email_verified_at) return { status: "VERIFICATION_REQUIRED" };
    const code = verificationCode();
    await transaction(db, async client => {
      await client.query("UPDATE email_verifications SET consumed_at=now() WHERE user_id=$1 AND consumed_at IS NULL", [user.rows[0]!.id]);
      await client.query("INSERT INTO email_verifications (id,user_id,code_hash,expires_at) VALUES ($1,$2,$3,now() + interval '15 minutes')", [randomUUID(), user.rows[0]!.id, digest(code, config.REFRESH_TOKEN_PEPPER)]);
    });
    await mailer.sendVerification(body.email, code);
    await audit(db, "EMAIL_VERIFICATION_RESENT", {}, user.rows[0]!.id);
    return { status: "VERIFICATION_REQUIRED" };
  });
  app.post("/v1/auth/login", { config: { rateLimit: { max: 10, timeWindow: "15 minutes" } } }, async request => {
    const body = z.object({ email, password }).parse(request.body); const result = await db.query("SELECT id,password_hash,email_verified_at FROM users WHERE email=$1 AND disabled_at IS NULL", [body.email]);
    const user = result.rows[0] as { id: string; password_hash: string; email_verified_at: Date | null } | undefined;
    if (!user || !(await verifyPassword(user.password_hash, body.password))) throw errors.invalidCredentials();
    if (!user.email_verified_at) throw new ApiError("EMAIL_NOT_VERIFIED", 403, "Email verification is required");
    const pair = await tokenPair(db, config, user.id); await audit(db, "LOGIN", {}, user.id); return pair;
  });
  app.post("/v1/auth/refresh", { config: { rateLimit: { max: 20, timeWindow: "15 minutes" } } }, async request => {
    const body = z.object({ refreshToken: z.string().min(32) }).parse(request.body); const oldHash = digest(body.refreshToken, config.REFRESH_TOKEN_PEPPER);
    const session = await db.query("SELECT id,user_id,refresh_token_hash FROM sessions WHERE refresh_token_hash=$1 AND revoked_at IS NULL AND expires_at>now()", [oldHash]);
    if (!session.rowCount || !sameDigest(session.rows[0]!.refresh_token_hash, oldHash)) throw errors.unauthorized();
    await db.query("UPDATE sessions SET revoked_at=now() WHERE id=$1", [session.rows[0]!.id]); const pair = await tokenPair(db, config, session.rows[0]!.user_id);
    await db.query("UPDATE sessions SET replaced_by=(SELECT id FROM sessions WHERE refresh_token_hash=$1) WHERE id=$2", [digest(pair.refreshToken, config.REFRESH_TOKEN_PEPPER), session.rows[0]!.id]); return pair;
  });
  app.post("/v1/auth/logout", async request => { const identity = auth(config, request); await db.query("UPDATE sessions SET revoked_at=now() WHERE id=$1 AND user_id=$2", [identity.sessionID, identity.userID]); return { status: "LOGGED_OUT" }; });

  app.post("/v1/devices", async request => { const identity = auth(config, request); const body = z.object({ clientDeviceId: z.string().min(8).max(128), displayName: z.string().trim().min(1).max(128) }).parse(request.body); const existing = await db.query("SELECT id FROM devices WHERE user_id=$1 AND client_device_id=$2", [identity.userID, body.clientDeviceId]); const deviceID = existing.rows[0]?.id ?? randomUUID(); if (existing.rowCount) await db.query("UPDATE devices SET display_name=$1,last_seen_at=now(),revoked_at=NULL WHERE id=$2", [body.displayName, deviceID]); else await db.query("INSERT INTO devices (id,user_id,client_device_id,display_name) VALUES ($1,$2,$3,$4)", [deviceID, identity.userID, body.clientDeviceId, body.displayName]); return { deviceId: deviceID }; });

  app.post("/v1/objects/upload-authorizations", async request => { const identity = auth(config, request); const body = z.object({ deviceId: uuid, sha256, sizeBytes: z.number().int().nonnegative().max(1_099_511_627_776) }).parse(request.body); await ownDevice(db, identity.userID, body.deviceId); const objectKey = objectKeyFor(identity.userID, body.deviceId, body.sha256); const authorizationID = randomUUID(); await db.query("INSERT INTO object_authorizations (id,user_id,device_id,operation,object_key,expected_sha256,expected_size_bytes,expires_at) VALUES ($1,$2,$3,'UPLOAD',$4,$5,$6,now()+interval '15 minutes')", [authorizationID, identity.userID, body.deviceId, objectKey, body.sha256, body.sizeBytes]); const credentials = await objectStore.issue("upload", objectKey); await audit(db, "UPLOAD_AUTHORIZED", { sha256: body.sha256, sizeBytes: body.sizeBytes }, identity.userID, body.deviceId); return { authorizationId: authorizationID, credentials }; });
  app.post("/v1/objects/:authorizationId/complete", async request => { const identity = auth(config, request); const params = z.object({ authorizationId: uuid }).parse(request.params); const authz = await db.query("SELECT * FROM object_authorizations WHERE id=$1 AND user_id=$2 AND operation='UPLOAD' AND consumed_at IS NULL AND expires_at>now()", [params.authorizationId, identity.userID]); if (!authz.rowCount) throw errors.notFound(); const row = authz.rows[0]!; await ownDevice(db, identity.userID, row.device_id); const head = await objectStore.head(row.object_key); if (head.sizeBytes !== Number(row.expected_size_bytes) || head.sha256 !== row.expected_sha256) throw errors.cloud("Remote object metadata does not match the authorized object"); const objectID = randomUUID(); await transaction(db, async client => { const saved = await client.query("INSERT INTO archive_objects (id,user_id,device_id,sha256,size_bytes,object_key,status,verified_at) VALUES ($1,$2,$3,$4,$5,$6,'VERIFIED',now()) ON CONFLICT (user_id,device_id,sha256) DO UPDATE SET status='VERIFIED',verified_at=now() RETURNING id", [objectID, identity.userID, row.device_id, row.expected_sha256, row.expected_size_bytes, row.object_key]); await client.query("UPDATE object_authorizations SET consumed_at=now(),archive_object_id=$1 WHERE id=$2", [saved.rows[0]!.id, row.id]); }); await audit(db, "OBJECT_VERIFIED", { sha256: row.expected_sha256 }, identity.userID, row.device_id); return { status: "VERIFIED" }; });
  app.post("/v1/objects/:objectId/download-authorizations", async request => { const identity = auth(config, request); const params = z.object({ objectId: uuid }).parse(request.params); const body = z.object({ deviceId: uuid }).parse(request.body); await ownDevice(db, identity.userID, body.deviceId); const object = await db.query("SELECT * FROM archive_objects WHERE id=$1 AND user_id=$2 AND device_id=$3 AND status='VERIFIED'", [params.objectId, identity.userID, body.deviceId]); if (!object.rowCount) throw errors.notFound(); const row = object.rows[0]!; const authorizationID = randomUUID(); await db.query("INSERT INTO object_authorizations (id,user_id,device_id,archive_object_id,operation,object_key,expected_sha256,expected_size_bytes,expires_at) VALUES ($1,$2,$3,$4,'DOWNLOAD',$5,$6,$7,now()+interval '15 minutes')", [authorizationID, identity.userID, body.deviceId, row.id, row.object_key, row.sha256, row.size_bytes]); return { authorizationId: authorizationID, credentials: await objectStore.issue("download", row.object_key) }; });
  app.get("/v1/objects", async request => { const identity = auth(config, request); const query = z.object({ deviceId: uuid, sha256 }).parse(request.query); await ownDevice(db, identity.userID, query.deviceId); const object = await db.query("SELECT id,sha256,size_bytes,object_key,verified_at FROM archive_objects WHERE user_id=$1 AND device_id=$2 AND sha256=$3 AND status='VERIFIED'", [identity.userID, query.deviceId, query.sha256]); return { objects: object.rows.map(row => ({ objectId: row.id, sha256: row.sha256, sizeBytes: Number(row.size_bytes), verifiedAt: row.verified_at })) }; });
  return app;
};
