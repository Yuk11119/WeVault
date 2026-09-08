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

`Scripts/build-app.sh release` produces an optimized development bundle; distribution
signing and notarization are not included. `swift run WeVault` starts a bare executable
and is not sufficient to register the scheme.

See [P5 implementation and isolated acceptance](Documentation/P5.md) for fixture-only
smoke testing, recovery guarantees, completed P5 acceptance and compatibility limits.

## Automatic archive and release

P4 connects managed-cloud scans, verification, policy-based isolation and quarantine
expiry. Defaults are daily runs, a 7-day cooling period and 7-day quarantine retention.
Automatic release does not download an extra restore-test copy. Pause stops new work;
resuming rechecks actual files and preserves already verified bindings.

See [P4 behavior and isolated acceptance](Documentation/P4.md) for batching, recovery
journals, current settings and verification results. Real WeChat acceptance remains P6.
