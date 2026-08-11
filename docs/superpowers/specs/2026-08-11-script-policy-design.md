# Script Policy: non-repeatable & restricted-hours constraints for cron scripts

Status: Approved for planning
Date: 2026-08-11
Author: Martin Renvoize (design captured via Claude Code brainstorming session)

## Background

The plugin already gates *which* scripts can be scheduled via a `script_allowlist`
plugin setting (a plain-text, one-pattern-per-line list, editable through a select2
picker on the settings page). It does not currently let an administrator constrain
*how* an allowed script may be scheduled.

This feature adds two script-level scheduling constraints:

- **non-repeatable** — a script may only appear in the crontab once (one schedule,
  one set of parameters), regardless of how many times someone might otherwise try
  to add it.
- **allowed hours** — a script may only be scheduled to run within a specific
  window of hours in the day (e.g. only overnight, 1am-5am).

This is the first of two related enhancements. A follow-up (not covered here) will
let a "system" (non-plugin-managed) crontab entry be migrated into a plugin-managed
job, potentially picking up these same policy constraints; that is intentionally
out of scope for this spec.

## Goals

- Let a server administrator (filesystem/koha-conf.xml access) pin a hard ceiling
  on which scripts may ever be scheduled through the plugin, and mandatory minimum
  policy for those scripts, for security/operational reasons that must not be
  overridable from the staff UI.
- Let a library administrator (staff UI, gated by `plugins_tool_configure`) select
  a subset of that ceiling and layer additional (never looser) policy on top,
  exactly as they already choose the allowlist today.
- Enforce `non_repeatable` and `allowed_hours` server-side at job add/update time.
- Never retroactively break an already-saved job when policy changes after the
  fact — surface a warning in the UI instead.
- Do it all within the plugin's existing "crontab file is the datastore" model and
  its zero-new-external-dependency posture (this design introduces no new CPAN
  dependency; `YAML::XS` is already a hard Koha core dependency).

## Non-goals

- Migrating system crontab entries into plugin-managed jobs (separate spec).
- Any change to the `user_allowlist` setting or its enforcement.
- Enforcing minute/day/month/weekday constraints — only the hour field is
  constrained by `allowed_hours`.
- Guaranteed detection of every possible way a system-managed crontab entry could
  invoke a given script (see Limitations).

## Data model

### Renamed setting: `script_allowlist` → `script_policy`

Since the on-disk/in-DB format is changing anyway, the plugin setting is renamed
from `script_allowlist` to `script_policy` (cleaner name reflecting its expanded
purpose). This is handled by the migration described below — no manually-run step
is required by admins.

### Shared YAML schema

Both the server-pinned file and the library-admin DB setting use the same shape:

```yaml
scripts:
  - path: batch/report.pl
    non_repeatable: true
    allowed_hours: "1-5"
  - path: finegen.pl
    non_repeatable: true
  - path: batch/            # directory prefix — no policy fields; ignored if present
```

- `path` — matches today's allowlist pattern semantics: either an exact script
  relative path (e.g. `batch/report.pl`) or a directory prefix (e.g. `batch/`,
  matched by `index($rel_path, $pattern) == 0` as today).
- `non_repeatable` (boolean, optional, default `false`) — **only meaningful on an
  exact path entry.** Ignored (with no error, just inert) on a prefix entry.
- `allowed_hours` (string, optional) — comma-separated list of single hours
  (`0`-`23`) and/or inclusive ranges (`H1-H2`). A range where `H1 > H2` wraps past
  midnight (e.g. `22-2` = `{22,23,0,1,2}`). **Only meaningful on an exact path
  entry.**
- An empty/absent `scripts` list (or absent file, for the server tier) means "no
  policy from this tier" — identical to today's "empty allowlist = allow
  everything under `$KOHA_CRON_PATH`" behavior for the library tier.

### Two tiers, ceiling semantics

1. **Server file** (new, optional): a YAML file on disk. Its path is given by a
   new koha-conf.xml entry, `koha_plugin_crontab_script_policy`, following the
   existing precedent of `koha_plugin_crontab_cronfile` (a koha-conf.xml entry
   pointing at an external file, read via `C4::Context->config(...)`).
2. **Library setting** (renamed from `script_allowlist`): the existing
   `script_policy` plugin setting, DB-backed via `retrieve_data`/`store_data`,
   edited through the staff configure page.

If the server file is present and its `scripts` list is non-empty, it is the
**maximum universe**:

- Only scripts/prefixes it lists may ever be selectable, regardless of what the
  library setting contains. A library-tier entry for a script/prefix the server
  tier doesn't cover is dropped when computing the effective policy.
- Any policy the server tier sets is a **floor**: the library tier may set the
  same or a *stricter* value, never looser.
  - `non_repeatable`: effective value is `server.non_repeatable OR
    library.non_repeatable` (library can only turn it on, never off).
  - `allowed_hours`: effective set is the **intersection** of the server's
    expanded hour set and the library's expanded hour set, when both are present;
    if only one tier sets it, that tier's set applies.

If the server file is absent, or present with an empty `scripts` list, behavior is
unchanged from today: the library setting alone governs, and an empty library
setting means "allow every script under `$KOHA_CRON_PATH`, no policy."

### Storage/encoding

- The server file is genuine YAML on disk, hand-edited by whoever controls the
  server.
- The DB-held `script_policy` setting is also genuine YAML **at rest** (so a
  single `YAML::XS::Load` code path in `Cron::Script.pm` reads both tiers, and an
  admin inspecting the DB row or fetching it via any future API sees the same
  format as the server file).
- The staff settings *form*, however, is a plain HTML `method="get"` form (as
  today), not a JSON API call. To avoid needing a YAML serializer in the
  browser, the JS picker builds a plain JS object (`{ scripts: [...] }`),
  `JSON.stringify`s it into the existing hidden field (renamed to
  `script_policy`), and `configure()`'s save path transcodes
  `YAML::XS::Dump(decode_json($cgi->param('script_policy')))` before calling
  `store_data`. Loading the settings page reverses this (YAML → `encode_json` →
  template param) so the JS picker can rehydrate its state.

### Migration

`Crontab.pm` currently has no `upgrade()` lifecycle hook. One is added:

- Runs once, gated on the plugin's version-tracking (`$args->{old_version}`,
  supplied by `Koha::Plugins::Base`), the first time a Koha instance upgrades past
  the version that introduces this feature.
- Reads the old `script_allowlist` DB value (plain newline-separated patterns, no
  policy).
- Converts it to the new schema: `{ scripts: [{path: line1}, {path: line2}, ...] }`
  with no policy fields (there was none to migrate).
- Serializes with `YAML::XS::Dump` and writes it to the new `script_policy` key.
- Clears the old `script_allowlist` key so no stale duplicate setting lingers.
- If `script_allowlist` was never set (fresh install or already-migrated instance),
  this is a no-op.

## Parsing & merge logic (`Cron::Script.pm`)

New/changed methods:

- **`_load_policy_source($yaml_text)`** — parses YAML text via `YAML::XS::Load`
  into a normalized arrayref of `{ path, is_prefix, non_repeatable, allowed_hours
  }` entries. `is_prefix` is derived the same way existing allowlist matching
  works today (does the pattern look like a directory prefix vs. an exact known
  script path). Used for both tiers.
- **`_effective_policy()`** — loads the server file (if
  `koha_plugin_crontab_script_policy` resolves to an existing, readable file) and
  the library `script_policy` setting, applies the ceiling/merge rules above, and
  returns the merged, effective list of policy entries. Replaces today's ad hoc
  allowlist-filtering block embedded in `get_available_scripts`.
- **`get_available_scripts`** filters against the effective list exactly as it
  filters against the allowlist today (same prefix/exact matching semantics), and
  additionally attaches `policy => { non_repeatable, allowed_hours }` to each
  returned script hashref when it matched an *exact* (non-prefix) effective entry.
  No policy key is attached for scripts that only matched via a prefix entry.
- **`validate_command`** (already resolves a submitted command to its matched
  script from `get_available_scripts`) now returns that script's `policy`
  alongside the matched script, so REST callers get it without a second lookup.
- **`_expand_cron_hour_field($field)`** — expands a cron schedule's hour field
  (`*`, single values, comma lists, ranges, and `*/n` steps, including combined
  forms like `1-10/2`) into a concrete set of integers 0-23.
- **`_expand_allowed_hours($spec)`** — expands an `allowed_hours` spec string
  (comma list of single hours and/or ranges, with midnight-wraparound ranges) into
  a concrete set of integers 0-23.

## Enforcement (`REST::V1::Cron::Jobs`)

In both `add` and `update`, after `validate_command` succeeds and yields a
`policy`:

- **`non_repeatable`**: call `get_all_crontab_entries()` (managed *and* system —
  confirmed in scope, since the real risk is duplicating a script another tool
  already scheduled) and check whether any *other* entry's command references the
  same script. Matching is a best-effort textual check: does the entry's command
  contain the script's `$KOHA_CRON_PATH/...`-relative form, or its raw resolved
  absolute path, as a substring? On `update`, the job's own existing block is
  excluded from the scan by its `crontab-manager-id`. A match → `400` with an
  error naming the conflicting entry's schedule.
- **`allowed_hours`**: expand the submitted schedule's hour field
  (`_expand_cron_hour_field`) and the policy's `allowed_hours`
  (`_expand_allowed_hours`); if the former is not a subset of the latter → `400`
  naming the disallowed hour(s) and the permitted spec.
- Both checks are authoritative and server-side; `safely_modify_crontab` itself is
  unchanged. Neither check produces a Koha action-log entry, matching today's
  behavior for validation failures (nothing is saved).

### Limitations (documented, not solved here)

Textual matching against arbitrary system-managed crontab commands cannot catch
every possible invocation style (symlinks, wrapper scripts, unusual quoting,
`sudo`/`flock` wrappers that obscure the script path entirely). This is a
best-effort safety net for the common cases (direct invocation, optionally via
`$KOHA_CRON_PATH`), not a guarantee.

### Grandfathering existing jobs

`Jobs::list` computes, for each already-saved managed job, whether it currently
violates the effective policy (duplicate script found elsewhere in the crontab, or
its own schedule's hours fall outside `allowed_hours`), and includes a
`policy_violations: []` array (empty if compliant) in each job's response.
Nothing is blocked, altered, or auto-fixed by this computation — policy is only
enforced going forward, at add/update time, per the earlier decision to leave
already-saved jobs alone and just flag them.

## UI changes

### `configure.tt` (Security Settings)

- The existing script picker (select2, tags-enabled) keeps its current job of
  picking scripts/prefixes. Each *exact* selected script (not prefixes) gains an
  inline policy panel: a "Non-repeatable" checkbox and an "Allowed hours" text
  input (placeholder `e.g. 1-5 or 22-2`).
- If the server file pins policy for a given script, that script's panel renders
  the server values pre-set and **disabled** (can't be unchecked/cleared), with a
  short note such as "Set by server administrator." If the server tier lists a
  script the library setting hasn't selected, there's simply nothing to show yet
  for it (nothing pre-selected in the picker).
- On submit, JS serializes `{ scripts: [{path, non_repeatable, allowed_hours},
  ...] }` as JSON into the (renamed) `script_policy` hidden field; `configure()`
  transcodes to YAML before persisting, per Storage/encoding above.
- On load, `configure()` transcodes the stored YAML to JSON for the template so
  the JS picker can rehydrate both its script selections and each one's policy
  panel.

### `crontab.tt` job add/edit modal

- When a script is picked via the existing script browser, the already-fetched
  script metadata (from `/api/v1/contrib/crontab/scripts`) now includes `policy`.
  If present, a hint line appears under the Schedule field, e.g. *"This script may
  only be scheduled once across the crontab, and only between 1:00-5:00."*
  Informational only — actual enforcement is server-side at save time, and any
  `400` response (duplicate or hours violation) surfaces through the existing
  `showMessage(...)` error path with no new UI plumbing required.

### Managed Jobs table

- Rendering of each row checks `policy_violations`; if non-empty, a small warning
  icon/badge appears (e.g. in the Status column) with a tooltip listing which
  constraint(s) are currently violated. Purely informational — no action buttons
  change as a result.

## API changes

- `GET /api/v1/contrib/crontab/scripts` — each script object gains an optional
  `policy` object (`{ non_repeatable, allowed_hours }`), present only when the
  script matched an exact effective policy entry.
- `GET /api/v1/contrib/crontab/jobs` — each job object gains a `policy_violations`
  array (empty when compliant).
- `POST /api/v1/contrib/crontab/jobs` and `PUT
  /api/v1/contrib/crontab/jobs/{job_id}` — may now additionally respond `400`
  with a descriptive `error` message for a `non_repeatable` or `allowed_hours`
  violation, alongside the existing script-allowlist validation error.
- `api/openapi.json` (top-level path-map format) is updated for all of the above
  response/request shape additions.
- A new koha-conf.xml entry, `koha_plugin_crontab_script_policy`, is documented
  (README/CHANGELOG) as the server-file path, read via
  `C4::Context->config('koha_plugin_crontab_script_policy')`.

## Testing

- `t/00-load.t` is unaffected.
- No existing automated coverage exercises REST/UI behavior in this repo (per
  `CLAUDE.md`, testing today is a single load test plus manual `koha-prove`/KTD
  verification) — this feature will be verified manually against a KTD instance:
  - Server-file ceiling narrows what the library-tier picker can select and
    tightens/locks policy panels as described.
  - `non_repeatable` rejects a second job for the same script, both against
    another plugin-managed job and against a synthetic system-crontab entry using
    the same script.
  - `allowed_hours` rejects/accepts schedules correctly across simple ranges,
    comma lists, `*/n` steps, and a midnight-wraparound range.
  - The `upgrade()` migration correctly converts a pre-existing plain-line
    `script_allowlist` value into `script_policy` and clears the old key.
  - The violation badge appears for a job that becomes non-compliant after policy
    is tightened, without altering or blocking that job.

## Changelog

A `CHANGELOG.md` entry under `[Unreleased]` will be added once implemented,
following this repo's Keep a Changelog convention.
