import "dotenv/config";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { mkdir, rm, stat } from "node:fs/promises";
import { promisify } from "node:util";
import { join } from "node:path";
import OSS from "ali-oss";

const execFileAsync = promisify(execFile);
const require = createRequire(import.meta.url);
const RPCClient = require("@alicloud/pop-core") as new (options: Record<string, string>) => {
  request(action: string, params: Record<string, unknown>, options: Record<string, unknown>): Promise<Record<string, unknown>>;
};

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const timestamp = () => new Date().toISOString().replace(/[:.]/g, "-");

const main = async () => {
  const databaseURL = required("BACKUP_DATABASE_URL");
  const bucket = required("OSS_BUCKET");
  const region = required("OSS_REGION");
  const endpoint = required("OSS_ENDPOINT");
  const runtimeRole = required("ECS_RAM_ROLE_NAME");
  const backupRoleArn = required("BACKUP_OSS_ROLE_ARN");
  const backupDirectory = process.env.BACKUP_DIRECTORY ?? "/var/backups/wevault-postgresql";
  await mkdir(backupDirectory, { recursive: true, mode: 0o700 });

  const filename = `wevault_staging-${timestamp()}.dump`;
  const localPath = join(backupDirectory, filename);
  try {
    // Debian/Ubuntu packages place pg_dump in /usr/bin; relying on PATH also
    // works for versioned installations without baking a host-specific path.
    await execFileAsync("pg_dump", ["--dbname", databaseURL, "--format=custom", "--file", localPath], { timeout: 10 * 60_000 });
  } catch (error) {
    // pg_dump can leave a zero-byte partial target after authentication or
    // connection errors. It is not a recoverable backup and must not survive
    // long enough to be selected by a restore drill.
    await rm(localPath, { force: true });
    throw error;
  }
  const backupSize = (await stat(localPath)).size;
  if (backupSize < 1) {
    await rm(localPath, { force: true });
    throw new Error("pg_dump created an empty backup");
  }

  const metadataURL = `http://100.100.100.200/latest/meta-data/ram/security-credentials/${encodeURIComponent(runtimeRole)}`;
  const sourceResponse = await fetch(metadataURL, { signal: AbortSignal.timeout(1500) });
  if (!sourceResponse.ok) throw new Error("ECS RAM credentials are unavailable");
  const source = await sourceResponse.json() as { AccessKeyId: string; AccessKeySecret: string; SecurityToken: string };
  const objectKey = `backups/postgresql/${filename}`;
  const sessionPolicy = JSON.stringify({ Version: "1", Statement: [{ Effect: "Allow", Action: ["oss:PutObject"], Resource: [`acs:oss:*:*:${bucket}/${objectKey}`] }] });
  const sts = new RPCClient({ accessKeyId: source.AccessKeyId, accessKeySecret: source.AccessKeySecret, securityToken: source.SecurityToken, endpoint: "https://sts.aliyuncs.com", apiVersion: "2015-04-01" });
  const response = await sts.request("AssumeRole", { RoleArn: backupRoleArn, RoleSessionName: `wevault-backup-${Date.now()}`, DurationSeconds: 900, Policy: sessionPolicy }, { method: "POST" });
  const credentials = (typeof response.Credentials === "string" ? JSON.parse(response.Credentials) : response.Credentials ?? response) as { AccessKeyId: string; AccessKeySecret: string; SecurityToken: string };
  const client = new OSS({ region, bucket, endpoint, accessKeyId: credentials.AccessKeyId, accessKeySecret: credentials.AccessKeySecret, stsToken: credentials.SecurityToken });
  await client.put(objectKey, localPath, { headers: { "x-oss-meta-backup-size": String(backupSize) } });
  process.stdout.write(`backup uploaded: ${objectKey} (${backupSize} bytes)\n`);
};

main().catch(error => { process.stderr.write(`backup failed: ${error instanceof Error ? error.message : "unknown error"}\n`); process.exitCode = 1; });
