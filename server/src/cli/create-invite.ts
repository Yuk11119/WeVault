import { randomBytes, randomUUID } from "node:crypto";
import { createDatabase } from "../db.js";
import { loadConfig } from "../config.js";
import { digest } from "../security.js";

const config = loadConfig();
if (process.argv[2] !== config.INITIAL_INVITE_ADMIN_SECRET) throw new Error("Pass INITIAL_INVITE_ADMIN_SECRET as the first argument.");
const uses = Number(process.argv[3] ?? "1"); if (!Number.isInteger(uses) || uses < 1 || uses > 100) throw new Error("Uses must be an integer from 1 to 100");
const code = `wv_${randomBytes(24).toString("base64url")}`; const db = createDatabase(config);
await db.query("INSERT INTO invitations(id,code_hash,max_uses,created_by) VALUES($1,$2,$3,'bootstrap-cli')", [randomUUID(), digest(code, config.REFRESH_TOKEN_PEPPER), uses]);
await db.end(); console.log(`Invite code (show once): ${code}`);
