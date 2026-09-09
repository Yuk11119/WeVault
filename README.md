# WeVault

WeVault helps reduce WeChat storage usage by moving large files and high-quality media to the cloud, while keeping everyday chats easy to browse.

## Why WeVault

WeChat can quietly take up a lot of space over time, especially from large files, original photos, and high-quality videos.

WeVault is designed to keep the things you use every day available locally, while moving the heavy originals into cloud storage so they can be restored when needed.

## What You Can Expect

- Free up local storage used by WeChat.
- Keep normal chat browsing, image viewing, and video playback usable.
- Restore archived originals when you need them.
- Avoid risky one-click deletion.
- Keep you in control before anything is moved.

## Status

WeVault is currently in early product development.

## macOS development app and restore links

```sh
Scripts/build-app.sh debug
open .build/app/WeVault.app
```

This builds a development `.app` that registers `wevault://restore/<binding_id>`.
Open **恢复中心** from the menu bar or status center to find archived records without
rescanning. Opening a link selects the record; restoration requires a separate click.
Ordinary files default to Downloads; media layers can be restored to their verified
WeChat path after confirmation. Existing non-matching files are never overwritten.

`Scripts/build-app.sh release` produces an optimized development bundle.
P7 adds `Scripts/package-beta.sh prepare` for a universal engineering preview and
`preflight` / `notarize` modes for a separately configured Developer ID release. `swift run WeVault` starts a bare executable
and is not sufficient to register the scheme.

See [P5 implementation and isolated acceptance](Documentation/P5.md) for fixture-only
smoke testing, recovery guarantees, completed P5 acceptance and compatibility limits.

## Automatic archive and release

P4 connects managed-cloud scans, verification, policy-based isolation and quarantine
expiry. Defaults are daily runs, a 7-day cooling period and 7-day quarantine retention.
Automatic release does not download an extra restore-test copy. Pause stops new work;
resuming rechecks actual files and preserves already verified bindings.

See [P4 behavior and isolated acceptance](Documentation/P4.md) for batching, recovery
journals, current settings and verification results.

See [P6 real WeChat acceptance](Documentation/P6.md) for the completed PDF, image and
Raw-video round trips, scanner and recovery-link fixes, and remaining Beta coverage
limits. Original files are restored; independent backups remain and automation stays paused.

## Beta stabilization (P7)

Manual scanning and upload now use bounded batches and paged results. The app includes
Chinese recovery guidance, explicit archive-risk acknowledgement, redacted JSONL
log export, email feedback drafts and on-demand update checks with manual installation.
Existing settings retain their values; automatic execution waits for acknowledgement
of the current risk notice. Content is not encrypted on the client before upload.

P7 is **engineering preparation complete**. All seven engineering requirements have
implementation and verification evidence. On 2026-09-09, the user confirmed all five
settings-panel checks passed using the agreed manual fallback for the UI tool failure.
The current workspace passes 135 Swift tests (resource benchmark skipped by default)
and 6 packaging tests; prior resource measurements and native export checks are retained.

Developer ID signing, notarization and native distribution integration checks are
separate distribution requirements, not engineering-completion blockers. Application tests cover
version/OS decisions, offline retry, and mail/browser launch failures.
`Scripts/prepare-smoke-app.sh` builds an ad-hoc signed Debug bundle that retains fixture
isolation across relaunches; the five manual settings checks are in the P7 record.
See [P7 implementation, measurements and release runbook](Documentation/P7.md).

### Public website and unnotarized Beta

On 2026-09-09, the separately authorized public test build **0.7.1 (8)** was
published at [wevault.online](https://wevault.online/). The
[download page](https://wevault.online/download/) includes the universal macOS ZIP,
SHA-256, installation limits, privacy information and public feedback email.
The HTTPS update feed is deployed and matches the archive. Cloud accounts remain
invitation-only; downloading does not create an account.

This build is ad-hoc signed and **not Apple notarized**. Clean-machine Gatekeeper,
existing-installation upgrades and native mail/update integration remain separate
checks. The original engineering preview remains marked NOT-FOR-DISTRIBUTION.
See [website build, deployment and verification](Website/README.md).

### macOS repeatedly asks for the Keychain password

Local builds default to ad-hoc signing. Their designated requirement is tied to
that build's code hash, so rebuilding can invalidate earlier “Always Allow”
authorizations. Use the same code-signing certificate for successive builds:

```sh
security find-identity -v -p codesigning
WEVAULT_SIGN_IDENTITY='Your code-signing certificate name' Scripts/build-app.sh
```

The certificate and its private key must already be available in your Keychain;
for automatic local builds, save its 40-character SHA-1 certificate fingerprint
to `~/.config/wevault/signing-identity`. The build script reads this file unless
`WEVAULT_SIGN_IDENTITY` is explicitly set. A configured but unavailable certificate
causes signing to fail rather than silently changing back to ad-hoc signing.
if no identities are listed, install an Apple Development / Developer ID
certificate, or create a persistent local code-signing identity in Keychain
Access for local development. Local certificates do not replace Developer ID
signing and notarization for distribution. The first launch after changing the
signing identity may still require approval for each existing Keychain item.
The manifest key is reused in memory after a successful read for the lifetime
of the process, so opening additional database connections does not ask again.
Do not delete `com.wevault.manifest.master-key`: it is needed to decrypt the
existing archive index.
