# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Koha plugin (`Koha::Plugin::Com::OpenFifth::Crontab`) that lets staff manage the Koha instance's system crontab from the staff UI — creating, editing, enabling/disabling, and deleting scheduled jobs — instead of editing crontab files by hand over SSH.

This repo is one of several sibling Koha plugin packages under `~/Projects/koha/plugins/`; see `~/Projects/koha/CLAUDE.md` for the overall monorepo layout and the `kd` worktree/KTD workflow used for spinning up a Koha dev instance to test against.

## Core architecture concept

**The crontab file itself is the datastore.** There is no database table for jobs. Each plugin-managed job is a `Config::Crontab::Block` containing:

- Comment lines encoding metadata as `# @key: value` (e.g. `# @crontab-manager-id: <uuid>`, `# @name:`, `# @description:`, `# @created:`, `# @updated:`, `# @managed-by: koha-crontab-plugin`)
- Optional `Config::Crontab::Env` lines for job-specific environment variables
- One `Config::Crontab::Event` line (the actual `schedule command` cron entry); "disabled" jobs are events with `active(0)` (commented out), not deleted

A block is only considered plugin-managed if its comments include `@crontab-manager-id`. `@managed-by: koha-crontab-plugin` further distinguishes plugin-created jobs from pre-existing system cron entries that are also shown (read-only) in the "all entries" view.

Every mutation goes through `Cron::File->safely_modify_crontab($callback)`, which: acquires a flock-based lock (`/tmp/koha-crontab-plugin.lock`), takes a pre-modification backup, reads+validates the crontab, runs the callback against the live `Config::Crontab` object, dry-run validates the result by dumping and re-parsing it, writes atomically, takes a post-modification backup, and on any failure restores from the pre-modification backup. Never bypass this method to write the crontab directly.

## Module layout

- `Koha/Plugin/Com/OpenFifth/Crontab.pm` — plugin entrypoint (`Koha::Plugins::Base` subclass). Handles `admin` (main UI), `configure` (settings page), `install`/`enable`/`disable`/`uninstall` lifecycle hooks, and wires up `api_routes`/`api_namespace` for the REST API.
- `Cron/File.pm` — crontab file I/O: locking, backup/restore, validation, `safely_modify_crontab`. Backup retention is configurable (plugin setting `backup_retention`, default 10); old backups are pruned automatically.
- `Cron/Job.pm` — job CRUD logic operating on a `Config::Crontab` object: parsing `@key: value` metadata from comment blocks, building new blocks (`create_job_block`), finding/updating blocks by UUID, listing plugin-managed jobs vs. all crontab entries, reading global (non-block) environment variables.
- `Cron/Script.pm` — discovers runnable scripts under `$KOHA_CRON_PATH` (read from the crontab's env lines), filters them against the configurable `script_allowlist`, extracts POD documentation (`Pod::Usage`) and parses `GetOptions`/`@ARGV` usage via regex to drive the UI's parameter-builder form. `validate_command` is the server-side gate ensuring a submitted job command actually matches an approved script — this is a security boundary, not just a UI convenience.
- `REST/V1/Cron/Jobs.pm`, `REST/V1/Cron/Scripts.pm` — Mojolicious API controllers behind `api/openapi.json` (top-level path-map format, not `$ref`-based). Every action calls `_check_user_allowlist($c)` first (superlibrarians always pass; otherwise checks the plugin's `user_allowlist` setting) — any new endpoint must do the same. Job-mutating endpoints also `logaction()` to Koha's action log when the `enable_logging` setting is on.
- `crontab.tt` — the admin UI: vanilla JS/jQuery + Bootstrap 5 (Koha staff interface conventions), calling the REST endpoints under `/api/v1/contrib/crontab/...`. No frontend build step/bundler.
- `configure.tt` — plugin settings page (user allowlist via patron picker, script allowlist, logging toggle, backup retention).
- `lib/Config/Crontab.pm` — bundled copy of the CPAN `Config::Crontab` module (loaded only if not already available in the Koha environment; see the `BEGIN` block and the `$SIG{__WARN__}` filter in `Crontab.pm` that suppresses its redefinition warnings, which occur when `install_plugins.pl` reloads plugins with `nocache => 1`).

## Security model

Two independent allowlists, each configurable via plugin settings (staff-editable, gated by the `plugins_tool_configure` permission) or via `koha-conf.xml`:

- **User allowlist** — restricts *who* can access the plugin at all (checked in both `admin()` and every REST controller's `_check_user_allowlist`).
- **Script allowlist** — restricts *which* scripts under `$KOHA_CRON_PATH` can be scheduled (checked server-side in `Cron::Script::validate_command`, called from the `add`/`update` REST actions — never trust the UI alone to enforce this).

When touching job creation/update or script discovery, preserve these checks; this plugin executes arbitrary shell commands with the Koha instance's privileges, so allowlist bypasses are security regressions.

## Versioning and releases

`package.json` is the source of truth for the version (`version`/`previous_version` fields, plus `plugin.pm_path` pointing at the main module).

- `npm run version:patch|minor|major` → runs `increment_version.js`, which bumps `package.json` and rewrites `our $VERSION` and `date_updated` in `Crontab.pm` in place.
- `npm run release:patch|minor|major` → does the above, commits (`chore: bump version`), tags `vX.Y.Z`, and pushes with `--follow-tags`. Pushing a `v*.*.*` tag triggers the GitHub Actions release job, which builds and attaches a `.kpz` artifact.
- Update `CHANGELOG.md` (Keep a Changelog format) under `[Unreleased]` for notable changes before cutting a release.
- Commit messages follow Conventional Commits style (`fix:`, `feat:`, `chore:`, `docs:`) — check `git log` for examples.

## Testing

There is a single Perl test, `t/00-load.t`, which loads the plugin module, instantiates it, and checks `$plugin->{metadata}->{version}` matches `package.json`. It expects `KOHA_PLUGIN_DIR` to point at the plugin directory (defaults to `.`).

CI (`.github/workflows/main.yml`) runs this against `main`, `stable`, and `oldstable` Koha versions inside `koha-testing-docker`, copying the repo into the container's plugin directory and running `prove`. Locally, use the `koha-prove` skill (or `prove t` inside a running KTD container with `KOHA_PLUGIN_DIR` set) against a KTD instance — see `~/Projects/koha/CLAUDE.md` for spinning one up via `kd up`.

There is no separate lint/build step for this plugin; `npm ci` is only used by the release job to run `increment_version.js`/packaging tooling.
