import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { createDatabase } from "../db.js";
import { loadMigrationDatabaseUrl } from "../config.js";

const db = createDatabase({ DATABASE_URL: loadMigrationDatabaseUrl() });
const directory = fileURLToPath(new URL("../../migrations/", import.meta.url));
await db.query("CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())");
for (const file of (await readdir(directory)).filter(name => name.endsWith(".sql")).sort()) {
  if ((await db.query("SELECT 1 FROM schema_migrations WHERE version=$1", [file])).rowCount) continue;
  const client = await db.connect();
  try { await client.query("BEGIN"); await client.query(await readFile(join(directory, file), "utf8")); await client.query("INSERT INTO schema_migrations(version) VALUES($1)", [file]); await client.query("COMMIT"); console.log(`Applied ${file}`); }
  catch (error) { await client.query("ROLLBACK"); throw error; } finally { client.release(); }
}
await db.end();
