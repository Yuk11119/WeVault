# WeVault API (P2A)

This is an isolated service for the WeVault beta. The current staging deployment shares an ECS with other projects, but uses its own Linux user, API domain, PM2 process, PostgreSQL cluster/data directory, OSS bucket and RAM roles. It does not use the macOS application's database or direct object-storage credentials.

## Local commands

```sh
cp .env.example .env # fill only local-development values; never commit it
npm install
npm run build
npm run test
npm run migrate
npm start
```

`POST /v1/auth/register` requires an invite; there is deliberately no public registration endpoint. Create test invites only after deployment:

```sh
npm run create-invite -- "$INITIAL_INVITE_ADMIN_SECRET" 1
```

Do not expose that command through HTTP or an automated CI log.

## API contract

All application APIs are versioned under `/v1`; errors are `{ "error": { "code", "message" } }`. Access tokens are JWTs valid for 15 minutes; refresh tokens are opaque, single-use and valid for 30 days.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/auth/register` | Invite-gated account creation and verification email |
| POST | `/auth/verify-email`, `/auth/resend-verification` | Consume or resend one 6-digit email code |
| POST | `/auth/login`, `/auth/refresh`, `/auth/logout` | Session lifecycle |
| POST | `/devices` | Register or update a client device |
| POST | `/objects/upload-authorizations` | Return an exact-object, 15-minute OSS or COS upload STS credential |
| POST | `/objects/:authorizationId/complete` | Server HEAD/metadata verification and object-index write |
| POST | `/objects/:objectId/download-authorizations` | Return an exact-object, 15-minute OSS or COS download STS credential |
| GET | `/objects?deviceId=&sha256=` | Verified-object query for manifest fallback |

The client must write `x-oss-meta-sha256` on upload. `complete` compares it and `Content-Length` against the immutable authorization. It never reports `VERIFIED` otherwise.

Set `MANAGED_CLOUD_PROVIDER=aliyun-oss` for the existing RAM-backed OSS deployment, or `tencent-cos` with the `COS_*` variables for a COS deployment. COS server credentials can only assume the configured role; every resulting session policy is limited to the exact user/device/SHA object key and a 15-minute lifetime. COS uploads must write `x-cos-meta-sha256`.

## Deployment runbook

1. Current staging uses Alibaba Linux on the existing ECS, isolated as Linux user `wevault`, PM2 service `pm2-wevault`, API port `127.0.0.1:31061`, and PostgreSQL port `127.0.0.1:5433`. Do not alter existing applications, their ports, PM2 processes, or databases. Allow public TCP 80/443 only; restrict SSH to the operator IP.
2. Point `api.wevault.online` to the ECS, install the dedicated Nginx vhost, obtain a Let’s Encrypt certificate, and confirm `curl https://api.wevault.online/healthz` returns `{"status":"ok"}`. The matching example runtime configuration and certificate paths already use this hostname. Do not expose 31061 or 5433.
3. The local PostgreSQL cluster uses database `wevault_staging`, application role `wevault_app`, and migration role `wevault_migrator`; both are loopback-only and least-privilege. Use `DATABASE_SSL=false` only for this isolated local staging cluster; RDS deployments retain TLS.
4. Create a private OSS test bucket. Disable public ACLs, enable server-side encryption and lifecycle/audit logging. Do not put an AccessKey in this repository or on the macOS client.
5. Attach an ECS RAM role able only to `sts:AssumeRole` for the two listed upload/download role ARNs and server-side OSS `GetObject`/`HeadObject` for the bucket prefix. Attach the uploaded/downloaded custom policies to their respective roles; keep the trust policy restricted to this ECS role. The API creates a stricter per-request session policy for exactly one key.
6. Configure Direct Mail: verify the sending domain, publish SPF and DKIM, approve the sender, and put runtime secrets only in `/etc/wevault-api/runtime.env` with mode `0600`. Do not put `MIGRATION_DATABASE_URL` in that file.
7. Install Node 20, PM2, Nginx and Certbot. Release source under `/opt/wevault-api/current`, run `npm install && npm run build`, then load `/etc/wevault-api/runtime.env` and `/etc/wevault-api/migration.env` in the shell before running `npm run migrate`; finally run `npm prune --omit=dev`, `pm2 start ecosystem.config.cjs`, and `pm2 save`. After the first successful dependency installation, commit the generated `package-lock.json`; future releases should use `npm ci`.
8. Install the Nginx site, run `nginx -t`, request the certificate with `certbot --nginx -d api.wevault.online`, reload Nginx, then run `./deploy/staging-acceptance.sh`. Do not pass tokens on a shell command line; export them only in the current operator shell when authenticated checks are needed.

## Operations and recovery

- The local staging database is backed up daily to private OSS and retained locally for 14 days. Apply an OSS lifecycle rule to `backups/postgresql/` only, expiring objects after 30 days; never apply it to `users/`.
- Restore drills use a new temporary PostgreSQL database on port 5433. The systemd backup unit writes dumps as root with mode `0600`, so run `pg_restore --no-owner --exit-on-error` as root while the migration connection is loaded from the restricted migration environment file. Verify `schema_migrations` and `SELECT 1`, then drop only that temporary database. Never restore over `wevault_staging`; do not print the connection string in shell history or logs.
- Rotate `JWT_SECRET`, `REFRESH_TOKEN_PEPPER`, Direct Mail credentials and RAM role access according to your security policy. Rotation of either token secret invalidates active sessions intentionally.
- Use `pm2 status`, `pm2 logs wevault-api-staging --lines 100`, `systemctl status nginx`, and `/healthz` for diagnosis. Logs redact passwords, tokens and verification codes.
- Object authorization, login, verification and cloud-verification failures are retained in `authorization_audits` without secrets, object locations or email verification codes.

## Staging acceptance

`deploy/staging-acceptance.sh` is safe to run from an operator machine after DNS and HTTPS are live. It always checks health, HTTPS redirection, security headers, error envelopes and unauthenticated API protection. If `WEVAULT_ACCESS_TOKEN` and `WEVAULT_DEVICE_ID` are exported in the current shell, it also checks that an authenticated object query is accepted without exposing an object location. The script never creates users, uploads objects, releases local files, or prints a supplied token.

## Browser restore bridge

`GET /restore` and `GET /restore.js` serve the PDF reader compatibility page. The link is `https://api.wevault.online/restore#binding-…`: the identifier stays in the fragment, never in the HTTP request. The page validates a 32/64-hex binding ID, offers an explicit native-app link and copy fallback, and makes no storage/authentication requests. Opening a link only selects a local record; restoration remains an explicit app operation. CSP, no-referrer, nosniff and no-store headers apply.

The September 8 deployment changed only `src/app.ts`, `src/restore-page.ts` and their built JavaScript, then restarted `wevault-api-staging`. Previous app source and JavaScript are saved at `/opt/wevault-api/backups/restore-link-20260908/`; rollback restores these two app files and restarts that one PM2 process. No migration or credential change is required.
