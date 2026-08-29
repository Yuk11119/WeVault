import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import OSS from "ali-oss";
import type { Config } from "./config.js";
import { errors } from "./errors.js";

const require = createRequire(import.meta.url);
const RPCClient = require("@alicloud/pop-core") as new (options: Record<string, string>) => { request(action: string, params: Record<string, unknown>, options: Record<string, unknown>): Promise<Record<string, string>> };

type EcsCredential = { AccessKeyId: string; AccessKeySecret: string; SecurityToken: string; Expiration: string };
export type TemporaryCredentials = { accessKeyId: string; accessKeySecret: string; securityToken: string; expiration: string; endpoint: string; bucket: string; region: string; objectKey: string };
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

export const createAliyunObjectStore = (config: Config): ObjectStore => ({
  async issue(operation, objectKey) {
    const source = await metadataCredential(config.ECS_RAM_ROLE_NAME);
    const client = new RPCClient({ accessKeyId: source.AccessKeyId, accessKeySecret: source.AccessKeySecret, securityToken: source.SecurityToken, endpoint: "https://sts.aliyuncs.com", apiVersion: "2015-04-01" });
    const data = await client.request("AssumeRole", { RoleArn: operation === "upload" ? config.OSS_UPLOAD_ROLE_ARN : config.OSS_DOWNLOAD_ROLE_ARN, RoleSessionName: `wevault-${operation}-${randomUUID()}`, DurationSeconds: 900, Policy: policyFor(config.OSS_BUCKET, objectKey, operation) }, { method: "POST" });
    const embedded = data.Credentials as unknown;
    const credentials = typeof embedded === "string" ? JSON.parse(embedded) as EcsCredential : (embedded ?? data) as EcsCredential;
    return { accessKeyId: credentials.AccessKeyId, accessKeySecret: credentials.AccessKeySecret, securityToken: credentials.SecurityToken, expiration: credentials.Expiration, endpoint: config.OSS_ENDPOINT, bucket: config.OSS_BUCKET, region: config.OSS_REGION, objectKey };
  },
  async head(objectKey) {
    // P2A intentionally verifies with a server-side role. The deployment adapter uses an
    // authenticated OSS HEAD request; this boundary keeps the API testable without OSS.
    const source = await metadataCredential(config.ECS_RAM_ROLE_NAME);
    const client = new OSS({ region: config.OSS_REGION, bucket: config.OSS_BUCKET, endpoint: config.OSS_ENDPOINT, accessKeyId: source.AccessKeyId, accessKeySecret: source.AccessKeySecret, stsToken: source.SecurityToken });
    let result: { res?: { headers?: Record<string, string | string[] | undefined> } };
    try { result = await client.head(objectKey); } catch { throw errors.cloud("OSS HEAD failed"); }
    const headers = result.res?.headers ?? {};
    const size = Number(headers["content-length"]);
    if (!Number.isSafeInteger(size) || size < 0) throw errors.cloud("OSS did not return a valid Content-Length");
    const metadata = headers["x-oss-meta-sha256"];
    return { sizeBytes: size, sha256: typeof metadata === "string" ? metadata : undefined };
  }
});
