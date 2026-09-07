import { createRequire } from "node:module";
import { createHash, createHmac, randomUUID } from "node:crypto";
import OSS from "ali-oss";
import type { Config } from "./config.js";
import { errors } from "./errors.js";

const require = createRequire(import.meta.url);
const RPCClient = require("@alicloud/pop-core") as new (options: Record<string, string>) => { request(action: string, params: Record<string, unknown>, options: Record<string, unknown>): Promise<Record<string, string>> };

type EcsCredential = { AccessKeyId: string; AccessKeySecret: string; SecurityToken: string; Expiration: string };
export type CloudProvider = "aliyun-oss" | "tencent-cos";
export type TemporaryCredentials = { provider: CloudProvider; accessKeyId: string; accessKeySecret: string; securityToken: string; expiration: string; endpoint: string; bucket: string; region: string; objectKey: string };
export type ObjectHead = { sizeBytes: number; sha256?: string };
export interface ObjectStore { issue(operation: "upload" | "download", objectKey: string): Promise<TemporaryCredentials>; head(objectKey: string): Promise<ObjectHead>; }

const metadataCredential = async (roleName: string): Promise<EcsCredential> => {
  const response = await fetch(`http://100.100.100.200/latest/meta-data/ram/security-credentials/${encodeURIComponent(roleName)}`, { signal: AbortSignal.timeout(1500) });
  if (!response.ok) throw errors.cloud("ECS RAM role credentials are unavailable");
  const data = await response.json() as EcsCredential;
  if (!data.AccessKeyId || !data.AccessKeySecret || !data.SecurityToken) throw errors.cloud("ECS RAM role returned incomplete credentials");
  return data;
};

export const objectKeyFor = (userID: string, deviceID: string, sha256: string) => `users/${userID}/devices/${deviceID}/objects/sha256/${sha256.slice(0, 2)}/${sha256.slice(2, 4)}/${sha256}`;
export const policyFor = (bucket: string, objectKey: string, operation: "upload" | "download") => JSON.stringify({ Version: "1", Statement: [{ Effect: "Allow", Action: operation === "upload" ? ["oss:PutObject", "oss:AbortMultipartUpload", "oss:ListParts"] : ["oss:GetObject"], Resource: [`acs:oss:*:*:${bucket}/${objectKey}`] }] });

const assumeAliyunObjectRole = async (config: Config, operation: "upload" | "download", objectKey: string): Promise<EcsCredential> => {
  const source = await metadataCredential(config.ECS_RAM_ROLE_NAME);
  const client = new RPCClient({ accessKeyId: source.AccessKeyId, accessKeySecret: source.AccessKeySecret, securityToken: source.SecurityToken, endpoint: "https://sts.aliyuncs.com", apiVersion: "2015-04-01" });
  const data = await client.request("AssumeRole", {
    RoleArn: operation === "upload" ? config.OSS_UPLOAD_ROLE_ARN : config.OSS_DOWNLOAD_ROLE_ARN,
    RoleSessionName: `wevault-${operation}-${randomUUID()}`,
    DurationSeconds: 900,
    Policy: policyFor(config.OSS_BUCKET, objectKey, operation)
  }, { method: "POST" });
  const embedded = data.Credentials as unknown;
  return (typeof embedded === "string" ? JSON.parse(embedded) : embedded ?? data) as EcsCredential;
};

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");
const hmacHex = (key: string | Buffer, value: string) => createHmac("sha256", key).update(value).digest("hex");
const hmacBuffer = (key: string | Buffer, value: string) => createHmac("sha256", key).update(value).digest();
const requireCos = (config: Config, key: "COS_SECRET_ID" | "COS_SECRET_KEY" | "COS_ROLE_ARN" | "COS_BUCKET" | "COS_REGION" | "COS_ENDPOINT" | "COS_RESOURCE_PREFIX") => {
  const value = config[key];
  if (!value) throw errors.cloud(`Tencent COS configuration ${key} is unavailable`);
  return value;
};
export const cosPolicyFor = (resourcePrefix: string, objectKey: string, operation: "upload" | "download") => JSON.stringify({
  version: "2.0",
  statement: [{ effect: "allow", action: operation === "upload" ? ["name/cos:PutObject", "name/cos:AbortMultipartUpload", "name/cos:ListParts"] : ["name/cos:GetObject"], resource: [`${resourcePrefix.replace(/\/$/, "")}/${objectKey}`] }]
});

const cosRequest = async (config: Config, action: string, payload: Record<string, unknown>) => {
  const secretID = requireCos(config, "COS_SECRET_ID");
  const secretKey = requireCos(config, "COS_SECRET_KEY");
  const host = "sts.tencentcloudapi.com";
  const timestamp = Math.floor(Date.now() / 1000);
  const date = new Date(timestamp * 1000).toISOString().slice(0, 10);
  const body = JSON.stringify(payload);
  const canonicalHeaders = `content-type:application/json; charset=utf-8\nhost:${host}\n`;
  const signedHeaders = "content-type;host";
  const canonicalRequest = ["POST", "/", "", canonicalHeaders, signedHeaders, sha256(body)].join("\n");
  const credentialScope = `${date}/sts/tc3_request`;
  const stringToSign = ["TC3-HMAC-SHA256", String(timestamp), credentialScope, sha256(canonicalRequest)].join("\n");
  const secretDate = hmacBuffer(`TC3${secretKey}`, date);
  const secretService = hmacBuffer(secretDate, "sts");
  const secretSigning = hmacBuffer(secretService, "tc3_request");
  const signature = hmacHex(secretSigning, stringToSign);
  const authorization = `TC3-HMAC-SHA256 Credential=${secretID}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const response = await fetch(`https://${host}`, { method: "POST", headers: { Authorization: authorization, "Content-Type": "application/json; charset=utf-8", Host: host, "X-TC-Action": action, "X-TC-Version": "2018-08-13", "X-TC-Timestamp": String(timestamp) }, body, signal: AbortSignal.timeout(5000) });
  const data = await response.json() as { Response?: { Credentials?: { Token: string; TmpSecretId: string; TmpSecretKey: string; ExpiredTime: number }; Error?: { Message?: string } } };
  if (!response.ok || data.Response?.Error || !data.Response?.Credentials) throw errors.cloud(`Tencent COS STS ${action} failed`);
  return data.Response.Credentials;
};

const cosAuthorization = (secretID: string, secretKey: string, method: string, host: string, path: string) => {
  const now = Math.floor(Date.now() / 1000); const keyTime = `${now};${now + 900}`;
  const signKey = createHmac("sha1", secretKey).update(keyTime).digest("hex");
  const httpString = `${method.toLowerCase()}\n${path}\n\nhost=${encodeURIComponent(host)}\n`;
  const stringToSign = `sha1\n${keyTime}\n${createHash("sha1").update(httpString).digest("hex")}\n`;
  const signature = createHmac("sha1", signKey).update(stringToSign).digest("hex");
  return `q-sign-algorithm=sha1&q-ak=${encodeURIComponent(secretID)}&q-sign-time=${keyTime}&q-key-time=${keyTime}&q-header-list=host&q-url-param-list=&q-signature=${signature}`;
};

export const createAliyunObjectStore = (config: Config): ObjectStore => ({
  async issue(operation, objectKey) {
    const credentials = await assumeAliyunObjectRole(config, operation, objectKey);
    return { provider: "aliyun-oss", accessKeyId: credentials.AccessKeyId, accessKeySecret: credentials.AccessKeySecret, securityToken: credentials.SecurityToken, expiration: credentials.Expiration, endpoint: config.OSS_ENDPOINT, bucket: config.OSS_BUCKET, region: config.OSS_REGION, objectKey };
  },
  async head(objectKey) {
    // Verification stays server-side, but uses a short-lived, object-scoped read role.
    // The ECS runtime role only needs permission to assume this role; it never receives
    // broad direct read access to the archive bucket.
    const credentials = await assumeAliyunObjectRole(config, "download", objectKey);
    const client = new OSS({ region: config.OSS_REGION, bucket: config.OSS_BUCKET, endpoint: config.OSS_ENDPOINT, accessKeyId: credentials.AccessKeyId, accessKeySecret: credentials.AccessKeySecret, stsToken: credentials.SecurityToken });
    let result: { res?: { headers?: Record<string, string | string[] | undefined> } };
    try { result = await client.head(objectKey); } catch { throw errors.cloud("OSS HEAD failed"); }
    const headers = result.res?.headers ?? {};
    const size = Number(headers["content-length"]);
    if (!Number.isSafeInteger(size) || size < 0) throw errors.cloud("OSS did not return a valid Content-Length");
    const metadata = headers["x-oss-meta-sha256"];
    return { sizeBytes: size, sha256: typeof metadata === "string" ? metadata : undefined };
  }
});

export const createTencentCosObjectStore = (config: Config): ObjectStore => ({
  async issue(operation, objectKey) {
    const credentials = await cosRequest(config, "AssumeRole", { RoleArn: requireCos(config, "COS_ROLE_ARN"), RoleSessionName: `wevault-${operation}-${randomUUID()}`, DurationSeconds: 900, Policy: cosPolicyFor(requireCos(config, "COS_RESOURCE_PREFIX"), objectKey, operation) });
    return { provider: "tencent-cos", accessKeyId: credentials.TmpSecretId, accessKeySecret: credentials.TmpSecretKey, securityToken: credentials.Token, expiration: new Date(credentials.ExpiredTime * 1000).toISOString(), endpoint: requireCos(config, "COS_ENDPOINT"), bucket: requireCos(config, "COS_BUCKET"), region: requireCos(config, "COS_REGION"), objectKey };
  },
  async head(objectKey) {
    const endpoint = new URL(requireCos(config, "COS_ENDPOINT"));
    const path = `/${objectKey.split("/").map(encodeURIComponent).join("/")}`;
    const host = endpoint.host;
    const response = await fetch(new URL(path, endpoint), { method: "HEAD", headers: { Host: host, Authorization: cosAuthorization(requireCos(config, "COS_SECRET_ID"), requireCos(config, "COS_SECRET_KEY"), "HEAD", host, path) }, signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw errors.cloud("COS HEAD failed");
    const size = Number(response.headers.get("content-length"));
    if (!Number.isSafeInteger(size) || size < 0) throw errors.cloud("COS did not return a valid Content-Length");
    return { sizeBytes: size, sha256: response.headers.get("x-cos-meta-sha256") ?? undefined };
  }
});

export const createManagedObjectStore = (config: Config): ObjectStore => config.MANAGED_CLOUD_PROVIDER === "tencent-cos" ? createTencentCosObjectStore(config) : createAliyunObjectStore(config);
