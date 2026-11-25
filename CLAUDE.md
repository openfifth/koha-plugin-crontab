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

- `Koha/Plugin/Com/OpenFifth/Crontab.pm` — plugin entrypoint (`Koha::Plugins::Base` subclass). Handles `admin` (main UI), `configure` (settings page), `install`/`enable`/`disable`/`uninstall` lifecycle hooks (`uninstall` deliberately leaves the crontab untouched), and wires up `api_routes`/`api_namespace` for the REST API.
- `Cron/File.pm` — crontab file I/O: locking, backup/restore, validation, `safely_modify_crontab`. Backup retention is configurable (plugin setting `backup_retention`, default 10); old backups are pruned automatically.
- `Cron/Job.pm` — job CRUD logic operating on a `Config::Crontab` object: parsing `@key: value` metadata from comment blocks, building new blocks (`create_job_block`), finding/updating blocks by UUID, listing plugin-managed jobs vs. all crontab entries, reading global (non-block) environment variables. `validate_job_fields` rejects newlines (a newline written into the crontab starts a new, attacker-controlled line) and is re-run inside `create_job_block`, the single write path; `check_environment_change` enforces that jobs cannot set environment variables.
- `Cron/Script.pm` — discovers runnable scripts under `$KOHA_CRON_PATH` (read from the crontab's env lines), filters them against the script policy (below), extracts POD documentation (`Pod::Usage`) and parses `GetOptions` / `Koha::Script->describe_options` (required options, positional `args`) / `@ARGV` usage via regex to drive the UI's parameter-builder form. `parse_command` tokenizes a command and accepts only plain words, quoting, `$NAME` and redirections; `validate_command` is the server-side gate ensuring a submitted job command is a single safe command line that matches an approved script; `check_positional_args` enforces a script's declared minimum bare arguments. These are security boundaries, not UI conveniences.
- `Cron/Backup.pm` — versions of the crontab (from `Cron::File` backups), their content, and restoring one. `restore_errors` holds a restore to the same rules as add/enable (fields, environment, command, script policy) for every plugin-managed job in the candidate; restoring must never be a way round the policy.
- `REST/V1/Cron/Jobs.pm`, `REST/V1/Cron/Backups.pm`, `REST/V1/Cron/Scripts.pm` — Mojolicious API controllers behind `api/openapi.json` (top-level path-map format, not `$ref`-based). Every action calls `_check_user_allowlist($c)` first (superlibrarians always pass; otherwise checks the plugin's `user_allowlist` setting) — any new endpoint must do the same. Job-mutating endpoints also `logaction()` to Koha's action log when the `enable_logging` setting is on.
- `crontab.tt` — the admin UI: vanilla JS/jQuery + Bootstrap 5 (Koha staff interface conventions), calling the REST endpoints under `/api/v1/contrib/crontab/...` (sending the `CSRF-TOKEN` header on unsafe methods). No frontend build step/bundler.
- `configure.tt` — plugin settings page (user allowlist via patron picker, script policy, logging toggle, backup retention).
- `access_denied.tt` — shown to users outside the user allowlist.
- `default-policy.yaml` — commented example of the script policy schema; its `scripts` list seeds the library policy on a fresh install (unless a server policy file is configured).

**Template conventions** (enforced by `t/19-template-conventions.t`): every template wraps its content in `[% WRAPPER 'wrapper-staff-tool-plugin.inc' %]` after setting `method` and `plugin_title`, and does not hand-build the page skeleton or define `jsinclude` (the wrapper replaces it). The wrapper loads jQuery at the bottom of the page, so page scripts are inline `<script nonce="[% Koha.CSPNonce | $raw %]">` blocks that wait for `DOMContentLoaded`, load any libraries they need (select2, DataTables) after jQuery, then run. Every inline `<script>`/`<style>` needs the CSP nonce, and there are no inline event handlers. Forms that change state POST with `[% INCLUDE 'csrf-token.inc' %]` and an `op` starting `cud-`.
- `lib/Config/Crontab.pm` — bundled copy of the CPAN `Config::Crontab` module (loaded only if not already available in the Koha environment; see the `BEGIN` block and the `$SIG{__WARN__}` filter in `Crontab.pm` that suppresses its redefinition warnings, which occur when `install_plugins.pl` reloads plugins with `nocache => 1`).

## Security model

This plugin executes shell commands with the Koha instance's privileges, so anything that widens what can run is a security regression. Invariants to preserve:

- **User allowlist** — restricts *who* can access the plugin at all (checked in `admin()` and every REST controller's `_check_user_allowlist`; superlibrarians always pass).
- **Script policy** — restricts *which* scripts under `$KOHA_CRON_PATH` can be scheduled, and per script `non_repeatable`, `allowed_hours` and `required_options`. Two tiers: an optional server policy file (`koha_plugin_crontab_script_policy` in `koha-conf.xml`) is a ceiling that the library policy (Configure page, stored in the `script_policy` setting) can only narrow; an unset or empty library policy inherits the server policy. **An empty policy means no scripts, never all scripts.** Policy paths name a script or a directory, not a string prefix. Enforced server-side through `Cron::Script::get_available_scripts` / `validate_command`, called from the add/update/migrate/enable REST actions — never trust the UI alone.
- **Commands** are validated by `parse_command`: no `;`, `|`, `&`, backticks, `$(...)`, newlines or other shell syntax beyond quoting, `$NAME` and redirections. Checking only the first word against the policy is an allowlist bypass.
- **Free-text fields** (name, description, schedule, command, environment) must be single-line (`Cron::Job::validate_job_fields`); a newline injects a crontab line.
- **No job-level environment variables.** In a crontab an environment line stays in effect for every later entry, so a "per-job" variable changes other jobs (and `KOHA_CRON_PATH`, `PERL5OPT`, etc. would redirect or hijack scripts). Existing variables may be kept or removed but never added or changed (`check_environment_change`). Variables belong in the crontab header.
- **Restoring a version** is validated by `Cron::Backup::restore_errors` exactly like adding or enabling its jobs; a version that fails is refused.
- **Enabling a job** re-validates its command, script requirements and policy exactly as adding it does.
- **State-changing requests must not be GET.** The Configure page saves only a POST carrying `op=cud-save` and a CSRF token; Koha's CSRF protection does not cover GET.

Allowlisting a script grants whatever it can do with any arguments; the README documents this under "What the script policy does and does not limit".

## Versioning and releases

`package.json` is the source of truth for the version (`version`/`previous_version` fields, plus `plugin.pm_path` pointing at the main module).

- `npm run version:patch|minor|major` → runs `increment_version.js`, which bumps `package.json` and rewrites `our $VERSION` and `date_updated` in `Crontab.pm` in place.
- `npm run release:patch|minor|major` → first runs `check_release_ready.js` (must be on `main`, clean working tree *including untracked files*, not behind `origin/main`; aborts before changing anything otherwise), then does the above, commits (`chore: bump version`), tags `vX.Y.Z`, and pushes with `--follow-tags`. Pushing a `v*.*.*` tag triggers the GitHub Actions release job, which builds and attaches a `.kpz` artifact. See `DEVELOPMENT.md` for the full workflow.
- Update `CHANGELOG.md` (Keep a Changelog format) under `[Unreleased]` for notable changes before cutting a release.
- Commit messages follow Conventional Commits style (`fix:`, `feat:`, `chore:`, `docs:`) — check `git log` for examples.

## Testing

`t/` holds the Perl tests (about twenty files: command parsing, policy tiers, job-field validation, positional args, install seeding, template conventions, ...). They load Koha modules, so they run inside a KTD container with the plugin mounted, not on the host. They expect `KOHA_PLUGIN_DIR` to point at the plugin directory (defaults to `.`):

```bash
ktd --name <instance> --shell --run 'cd /kohadevbox/plugins/koha-plugin-crontab && prove -I. -Ilib t/'
```

Start an instance with the plugin mounted using `kd up <name> --plugin <path>` (see `~/Projects/koha/CLAUDE.md`), or use the `koha-prove` skill. `DEVELOPMENT.md` has the details, including two gotchas: `t/08` clears the instance's `script_policy` when it finishes (re-seed it before trying the UI against the same instance), and some tests write untracked crontab backups under `Koha/Plugin/Com/OpenFifth/Crontab/backups/`.

CI (`.github/workflows/main.yml`) runs the suite against `main`, `stable`, and `oldstable` Koha inside `koha-testing-docker`, copying the repo into the container's plugin directory and running `prove`.

There is no lint or build step; `npm ci` is only used for the version/release tooling. UI changes should also be checked in a real browser against a KTD instance (the REST API and the page scripts are not covered by the unit tests).
