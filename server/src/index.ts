import "dotenv/config";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createDatabase } from "./db.js";
import { createMailer } from "./mail.js";
import { createAliyunObjectStore } from "./oss.js";

const config = loadConfig();
const db = createDatabase(config);
const app = await createApp({ config, db, mailer: createMailer(config), objectStore: createAliyunObjectStore(config) });
const stop = async () => { await app.close(); await db.end(); process.exit(0); };
process.once("SIGINT", stop); process.once("SIGTERM", stop);
await app.listen({ host: config.HOST, port: config.PORT });
