import "dotenv/config";
import { z } from "zod";

const schema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  HOST: z.string().default("127.0.0.1"),
  PORT: z.coerce.number().int().positive().default(31061),
  DATABASE_URL: z.string().min(1),
  // The staging database is isolated on the same host at 127.0.0.1:5433.
  // Remote/RDS deployments retain TLS by default and must opt out explicitly.
  DATABASE_SSL: z.enum(["true", "false"]).default("true"),
  MIGRATION_DATABASE_URL: z.string().min(1).optional(),
  JWT_SECRET: z.string().min(32),
  REFRESH_TOKEN_PEPPER: z.string().min(32),
  INITIAL_INVITE_ADMIN_SECRET: z.string().min(32),
  API_BASE_URL: z.url(),
  ALLOWED_ORIGINS: z.string().min(1).refine(value => !value.split(",").includes("*"), "Wildcard CORS is forbidden"),
  MAIL_HOST: z.string().min(1), MAIL_PORT: z.coerce.number().int().positive().default(465),
  MAIL_USER: z.string().min(1), MAIL_PASSWORD: z.string().min(1), MAIL_FROM: z.string().min(3),
  OSS_BUCKET: z.string().min(3), OSS_REGION: z.string().min(1), OSS_ENDPOINT: z.url(),
  ECS_RAM_ROLE_NAME: z.string().min(1), OSS_UPLOAD_ROLE_ARN: z.string().min(1), OSS_DOWNLOAD_ROLE_ARN: z.string().min(1),
  MANAGED_CLOUD_PROVIDER: z.enum(["aliyun-oss", "tencent-cos"]).default("aliyun-oss"),
  COS_SECRET_ID: z.string().min(1).optional(), COS_SECRET_KEY: z.string().min(1).optional(),
  COS_ROLE_ARN: z.string().min(1).optional(), COS_BUCKET: z.string().min(3).optional(),
  COS_REGION: z.string().min(1).optional(), COS_ENDPOINT: z.url().optional(), COS_RESOURCE_PREFIX: z.string().min(1).optional()
});

export type Config = z.infer<typeof schema>;
export const loadConfig = (): Config => schema.parse(process.env);

/**
 * Migrations intentionally need only the privileged migration connection.
 * Keeping this separate means schema deployment never needs production SMTP,
 * OSS, or application-token secrets in its environment.
 */
export const loadMigrationDatabaseUrl = (): string => z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  DATABASE_URL: z.string().min(1),
  MIGRATION_DATABASE_URL: z.string().min(1).optional()
}).parse(process.env).MIGRATION_DATABASE_URL ?? z.object({ DATABASE_URL: z.string().min(1) }).parse(process.env).DATABASE_URL;
