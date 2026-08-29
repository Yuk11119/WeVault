import argon2 from "argon2";
import jwt from "jsonwebtoken";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { Config } from "./config.js";

export type Claims = { sub: string; sid: string; typ: "access" };
export const opaqueToken = () => randomBytes(48).toString("base64url");
export const verificationCode = () => String(Math.floor(100000 + Math.random() * 900000));
export const digest = (value: string, pepper: string) => createHash("sha256").update(`${pepper}:${value}`).digest("hex");
export const sameDigest = (left: string, right: string) => timingSafeEqual(Buffer.from(left), Buffer.from(right));
export const hashPassword = (password: string) => argon2.hash(password, { type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 });
export const verifyPassword = (hash: string, password: string) => argon2.verify(hash, password);
export const issueAccess = (config: Config, userID: string, sessionID: string) => jwt.sign({ sub: userID, sid: sessionID, typ: "access" }, config.JWT_SECRET, { algorithm: "HS256", expiresIn: "15m", issuer: "wevault-api", audience: "wevault-macos" });
export const verifyAccess = (config: Config, token: string) => jwt.verify(token, config.JWT_SECRET, { algorithms: ["HS256"], issuer: "wevault-api", audience: "wevault-macos" }) as Claims;
