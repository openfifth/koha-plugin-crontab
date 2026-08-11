# Migrate system crontab entries to plugin-managed jobs

Status: Approved for planning
Date: 2026-08-11
Author: Martin Renvoize (design captured via Claude Code brainstorming session)

## Background

The plugin already displays "system" crontab entries — blocks with no
`@crontab-manager-id` metadata, or with `@managed-by` set to something other
than this plugin — read-only, in the System Jobs tab, purely so admins can
see what else is scheduled and avoid conflicts. There is currently no way to
bring one of those entries under the plugin's management (editable,
enable/disable, deletable via the UI) without hand-editing the crontab file
and adding the plugin's metadata comments manually.

This was flagged as a follow-up when the script-policy feature
(`docs/superpowers/specs/2026-08-11-script-policy-design.md`, on this same
`planning` branch) was designed, and is now being built as its own feature.

## Goals

- Let an admin convert an existing unmanaged (system) crontab entry into a
  plugin-managed job, in one click, without retyping its schedule or command.
- Preserve the entry's current schedule, command, and enabled/disabled state
  exactly — migration adds management metadata, it does not change what
  actually runs.
- Reuse the existing job-creation validation rules (script allowlist,
  `non_repeatable`, `allowed_hours`) so a migrated job is held to the same
  standard a brand-new job would be, not a special weaker one.
- Handle the case where a system crontab block groups multiple schedule
  lines under one shared comment header (e.g. an Ansible-templated block) —
  migrating one line out of such a group must not disturb the others.

## Non-goals

- Bulk/multi-select migration (one entry at a time only).
- Migrating an entry whose command doesn't match an approved script (see
  Decisions below) — that entry simply isn't eligible; no workaround or
  override path is provided.
- Any change to how the System Jobs tab identifies or displays entries
  before migration.

## Decisions

- **Command must pass the existing script allowlist validation.** Migration
  calls the same `validate_command` gate `add` uses. A system entry whose
  command doesn't match an approved script cannot be migrated — the point is
  to bring known-good, already-approved scripts under management, not to
  create a backdoor around the allowlist for arbitrary system commands.
- **`non_repeatable`/`allowed_hours` are enforced exactly as they would be
  for a new job**, treating the entry as if it doesn't exist yet for the
  purposes of its own duplicate/hours check (it's excluded from the scan of
  itself). A migration that would violate policy today is rejected the same
  way creating that job fresh would be.
- **No confirmation dialog.** Clicking "Migrate" submits immediately. On
  success, the Edit Job modal opens automatically, pre-filled with the new
  job, so the admin can review/adjust right away — this replaces the need
  for a "review before submitting" step.
- **Identification is by content match**, not a positional index: the
  migrate request sends back the exact `schedule`, `command`, and `comments`
  the System Jobs row displayed; the server re-scans the live crontab for an
  unmanaged entry matching all three exactly. If the crontab changed since
  the page was loaded (single-admin tool, expected to be rare), the request
  simply 404s rather than risking migrating the wrong entry.
- **Defaults on migration:** `name` defaults to the matched script's
  filename (e.g. `advance_notices.pl`); `description` defaults to the
  entry's original comment text (joined, `#`-prefixes stripped), or blank if
  there were no comments. Both are immediately editable in the auto-opened
  Edit Job modal.

## Data model / mechanics

No new persisted state — this operates entirely on the crontab file itself,
consistent with the plugin's existing "the crontab file is the datastore"
architecture (see `CLAUDE.md`).

### Locating the target entry

New method on `Cron::Job`:

```
find_unmanaged_entry($ct, $schedule, $command, $comments)
```

Scans `$ct->blocks`, skips any block that's already plugin-managed (same
`managed-by` check `get_all_crontab_entries` already uses), and within the
remaining blocks looks for an event whose `datetime` and `command` match
`$schedule`/`$command` exactly, in a block whose joined comment text
(`map { $_->data } $block->select(-type => 'comment')`) matches `$comments`
exactly (same array, same order). Returns the matching `{block, event}` pair,
or `undef` if no match is found.

### Splitting a shared block

New method on `Cron::Job`:

```
extract_event_from_block($block, $event)
```

- If `$event` is the block's only event: removes the entire block from the
  crontab (`$ct->remove($block)`) — nothing is left behind, since the block
  existed solely to hold this one entry (plus, in the general case, its own
  comments — which become the migrated job's description default, per the
  Decisions above, so nothing is lost).
- If the block has sibling events: filters `$event` out of the block's
  `lines` (via `$block->lines([...])`, matching the pattern `update_job_block`
  already uses to rewrite a block's lines), leaving the block, its original
  comments, and every other event untouched.

### Building the new managed block

Reuses the existing `create_job_block` unchanged, with:

```
{
    id          => <fresh UUID, via generate_job_id>,
    name        => <matched script's basename, from validate_command's `script` result>,
    description => <joined original comments, or ''>,
    schedule    => <unchanged from the original event>,
    command     => <unchanged from the original event>,
    enabled     => <unchanged from the original event's active flag>,
    created     => <now>,
    updated     => <now>,
}
```

## API changes

**New endpoint: `POST /api/v1/contrib/crontab/jobs/migrate`**, in
`REST::V1::Cron::Jobs`, structured like `add`:

- Request body: `{ schedule, command, comments: [...] }`.
- `_check_user_allowlist($c)` gate, same as every other action.
- `validate_command($body->{command})`; `400` with the same error `add`
  would give if it fails.
- If the matched script carries a policy: `check_non_repeatable` (against
  `get_all_crontab_entries()` with the entry-being-migrated excluded from
  the scan by the same schedule/command/comments match) and
  `check_allowed_hours` against the unchanged schedule; `400` on either
  failure, mirroring `add`'s error shape exactly.
- Inside `safely_modify_crontab`:
  - `find_unmanaged_entry` — `404` (`"Entry not found"`) if no match.
  - `extract_event_from_block`, then `create_job_block` + append
    (`$ct->last($block)`), exactly like `add`'s mutation callback.
- Success: `201`, same response shape as `add` (`id`, `name`, `description`,
  `schedule`, `command`, `enabled`, `environment`, `created_at`, `updated_at`).
- `logaction('SYSTEMPREFERENCE', 'ADD', $job_id, "CrontabPlugin: Migrated
  system job to managed job '$name'")` when `enable_logging` is on, matching
  the convention of every other mutating action.
- `api/openapi.json` gains this path, modeled on `/jobs`'s existing `post`.

## UI changes

`crontab.tt`, System Jobs tab:

- Each row gains a "Migrate" action button (the tab exclusively lists
  unmanaged entries, so no additional gating is needed on which rows show
  it).
- Click handler sends `{schedule, command, comments}` — exactly the data
  already rendered for that row — to the new endpoint. No confirmation
  modal.
- On success: reload both the Managed Jobs and System Jobs tables (the entry
  disappears from one, appears in the other), switch the active tab to
  Managed Jobs, and open the existing Edit Job modal pre-filled with the
  returned job, reusing the current edit-job code path unchanged.
- On failure (`400`/`404`): surfaced via the existing `showMessage(...)`
  pattern, same as every other action in this file.

## Testing

- `find_unmanaged_entry` and `extract_event_from_block` are pure-ish logic
  operating on a `Config::Crontab` object (no DB, no HTTP) — they get real
  automated Perl tests: constructing a small in-memory crontab with a
  single-event block and a multi-event shared block, and verifying matching
  and splitting behave as designed in both cases (including the "no match
  found" and "sibling events preserved" cases).
- The REST endpoint and UI changes have no existing automated test harness
  in this repo (same posture as the script-policy feature) — verified
  manually against a KTD instance: migrating a single-event system entry,
  migrating one line out of a multi-event shared block (confirming siblings
  survive), migrating a command that fails the allowlist (rejected),
  migrating a schedule that would violate an active `non_repeatable`/
  `allowed_hours` policy (rejected), and the full UI round-trip (tab
  switch + auto-opened Edit modal pre-filled correctly).

## Changelog

A `CHANGELOG.md` entry under `[Unreleased]` will be added once implemented,
following this repo's Keep a Changelog convention.
