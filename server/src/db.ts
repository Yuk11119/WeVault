import { Pool, type PoolClient } from "pg";
export type Database = Pool;
export type DatabaseConfig = { DATABASE_URL: string; NODE_ENV?: "development" | "test" | "production"; DATABASE_SSL?: "true" | "false" };
export const createDatabase = (config: DatabaseConfig): Database => new Pool({
  connectionString: config.DATABASE_URL,
  max: 10,
  ssl: config.NODE_ENV === "production" && config.DATABASE_SSL !== "false" ? { rejectUnauthorized: true } : undefined
});
export const transaction = async <T>(db: Database, task: (client: PoolClient) => Promise<T>): Promise<T> => {
  const client = await db.connect();
  try { await client.query("BEGIN"); const result = await task(client); await client.query("COMMIT"); return result; }
  catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
};
export const audit = async (db: Database, action: string, detail: Record<string, unknown>, userID?: string, deviceID?: string) => {
  await db.query("INSERT INTO authorization_audits (user_id, device_id, action, detail) VALUES ($1, $2, $3, $4)", [userID ?? null, deviceID ?? null, action, JSON.stringify(detail)]);
};
