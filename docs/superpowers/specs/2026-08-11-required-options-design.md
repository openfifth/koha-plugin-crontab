# Script Policy: explicit required-options, replacing Getopt::Long-inferred "required"

Status: Approved for planning
Date: 2026-08-11
Author: Martin Renvoize (design captured via Claude Code brainstorming session)

## Background

Fixes GitHub issues #21 ("Enforce required values in commands") and #22 ("Some
script parameters marked as required incorrectly"), which share one root cause.

`Cron::Script::_parse_option_spec` currently derives an option's `required` flag
from whether its Getopt::Long spec uses `=` vs `:` (e.g. `hours|h=i`). This is a
misreading of Getopt::Long semantics: `=`/`:` only say whether a *value* is
required *if the flag is passed* — they say nothing about whether the flag itself
must be passed for the script to run correctly. Two concrete symptoms:

- `longoverdue.pl`'s `--maxdays`, `--category`, `--library`, `--itemtype`, etc. all
  use `=s`/`=s%` and are flagged `required` today, despite being genuinely optional
  (the script's own SYNOPSIS documents them bracketed/optional; only `--lost|-l` is
  truly mandatory). This is issue #22.
- `cart_to_shelf.pl`'s `-h|--hours=s` *is* genuinely mandatory (the script `die`s
  without it) and is correctly flagged `required` today, but the UI only ever
  renders a red asterisk — nothing stops the job from being saved with that field
  blank, so the cron then fails at runtime. This is issue #21.

Getopt::Long specs alone cannot express "this flag is mandatory" — that's decided
by each script's own post-`GetOptions` validation logic (a `die`/`pod2usage` if a
variable is unset), which isn't reliably introspectable by static analysis across
the ~100+ scripts under `$KOHA_CRON_PATH`. The fix is to stop guessing and make
required-ness an explicit, administrator-curated policy field, using the two-tier
`script_policy` mechanism already built for [[non_repeatable and allowed_hours]].

A longer-term idea — standardizing how Koha core cronjob scripts themselves
declare mandatory options (e.g. via a `Koha::Script` convention) — was raised
during design but is Koha-core work, out of scope for this plugin repo.

## Goals

- Stop misclassifying purely value-taking (`=`) options as mandatory.
- Let administrators (server-file and/or library/staff-UI tiers, same ceiling
  semantics as `non_repeatable`/`allowed_hours`) explicitly declare which options
  a script's command must supply a value for.
- Enforce required options server-side at job `add`/`update`/`migrate` time —
  never trust client-side validation alone, consistent with this plugin's
  existing security model.
- Give a responsive client-side check too, so a missing required field is caught
  before the round-trip to the server.
- Keep the change additive to the existing `script_policy` YAML schema and its
  merge/ceiling logic — no new config surface, no new dependency.

## Non-goals

- Any static-analysis heuristic (POD `SYNOPSIS` bracket-parsing or similar) to
  auto-detect required-ness. Rejected as unreliable given inconsistent POD
  formatting across Koha's cronjob scripts; explicit policy is more reliable and
  fits the existing mechanism.
- Changing Koha core scripts or introducing a `Koha::Script` mandatory-option
  convention. Noted as a future idea, not attempted here.
- Validating that a required option's *value* is well-formed (e.g. numeric range
  checks) — only that the flag is present in the command.

## Data model

### Extended YAML schema

`required_options` (array of strings, optional, default `[]`) is added alongside
`non_repeatable` and `allowed_hours`, at both tiers:

```yaml
scripts:
  - path: misc/cronjobs/longoverdue.pl
    required_options: ["lost"]
  - path: misc/cronjobs/cart_to_shelf.pl
    required_options: ["hours"]
  - path: batch/report.pl
    non_repeatable: true
    allowed_hours: "1-5"
    required_options: ["report-id"]
```

- Entries are long option names (the primary name from the script's Getopt::Long
  spec, e.g. `hours` for `h|hours=s`), not short aliases. The plugin resolves a
  required long name to its parsed option (matching `name`) when rendering and
  when validating a submitted command.
- Only meaningful on an exact path entry, same as `non_repeatable`/`allowed_hours`
  — ignored (inert) on a directory-prefix entry.
- An absent/empty `required_options` means "no additional mandatory options from
  this tier," identical in spirit to the other two fields' absent-value behavior.

### Merge semantics: union

`effective.required_options = server.required_options ∪ library.required_options`
for a given path. This mirrors `non_repeatable`'s "library can only turn it on"
rule: the library tier may add further mandatory options on top of whatever the
server tier already requires, but can never drop a server-required option. In the
staff UI, a server-required option's checkbox renders checked and disabled, same
treatment as a server-locked `non_repeatable`.

## Parsing & merge logic (`Cron::Script.pm`)

- **`_parse_option_spec`**: drop the `required` key entirely from its return
  value. `_parse_getoptions_block`/`parse_script_options` no longer produce a
  `required` field from raw script parsing — required-ness now comes exclusively
  from policy, attached downstream (see `Scripts.pm#get` below).
- **`_load_policy_source`**: extend the per-entry hashref with
  `required_options => $raw->{required_options} || []` (array, defensively
  flattened/deduped from whatever the YAML provides).
- **`_merge_policy_tiers`**: extend each merged entry with `required_options`
  computed as the deduplicated union of the server and library entries' lists for
  that path.
- **`get_available_scripts`**: the `policy` hashref attached to each matched exact
  script gains `required_options => $exact_entry->{required_options} || []`,
  alongside the existing `non_repeatable`/`allowed_hours` keys.
- **New `check_required_options($required_options, $command)`**: mirrors
  `check_non_repeatable`/`check_allowed_hours`'s shape.
  - Returns `{ valid => 1 }` immediately if `$required_options` is empty/undef.
  - Tokenizes `$command` with `Text::ParseWords::shellwords` (handles quoting the
    same way a shell would, consistent with how commands are actually built and
    executed).
  - For each required long name, resolves it against the script's parsed options
    (`parse_script_options` on the already-known script path) to find its
    `short_name`, then checks whether a `--name`, `--name=...`, or `-shortname`
    token is present anywhere in the tokenized command.
  - Collects any missing required names and returns
    `{ valid => 0, error => "Required option(s) missing: --name1, --name2" }` if
    any are absent, naming all of them at once (not just the first).

## Enforcement (`REST::V1::Cron::Jobs`)

In `add`, `update`, and `migrate`, after the existing `non_repeatable` and
`allowed_hours` policy checks, add a third block of the same shape:

```perl
if ( $policy->{required_options} && @{ $policy->{required_options} } ) {
    my $check = $script_model->check_required_options(
        $policy->{required_options}, $body->{command}
    );
    unless ( $check->{valid} ) {
        return $c->render( status => 400, openapi => { error => $check->{error} } );
    }
}
```

Authoritative and server-side, exactly like the two existing checks; no change to
`safely_modify_crontab` or logging behavior.

## UI changes

### `crontab.tt` job add/edit modal

- No change to how options render: `Scripts.pm#get` now computes each option's
  `required` boolean by checking whether its long `name` appears in
  `policy.required_options`, before returning the options array — so the
  existing `option.required ? '<span class="text-danger">*</span>' : ''`
  template code in the JS renderer needs no changes at all.
- `buildCommandFromParams()` gains a pre-flight check: before assembling
  `fullCommand`, scan `currentScriptData.options` for entries with
  `required: true` whose corresponding input(s) are empty (scalar field blank,
  or — for repeatable/hash destinations — zero entries present). If any are
  missing, call `showMessage('Missing required option(s): ...', 'error')` and
  return without setting `#job-command`, instead of silently building an
  incomplete command.

### `configure.tt` (Security Settings, script policy editor)

- `renderPolicyPanels()` is extended: for each exact selected script, fetch its
  parsed options via `GET /api/v1/contrib/crontab/scripts/details?name=<name>&
  bypass_filter=1` (cached per path in a client-side map, fetched once per
  session per script) and render a checkbox per non-boolean detected option
  (`--name`), labelled with its name.
  - A server-required option's checkbox is checked and disabled, with the same
    "(set by server administrator)" note used for locked `non_repeatable`.
  - Library-tier checked options are stored in
    `libraryPolicyState[path].required_options` (array of names).
- On submit, `required_options` is included per-script in the JSON payload that
  gets YAML-encoded into the `script_policy` setting, alongside the existing
  `non_repeatable`/`allowed_hours` fields.
- On load, existing `required_options` values (union already resolved by
  `_effective_policy`/raw library tier, as appropriate for what's editable) are
  used to pre-check the relevant boxes once that script's options have loaded.

## API changes

- `GET /api/v1/contrib/crontab/scripts` — each script's optional `policy` object
  gains `required_options` (array of strings, possibly empty).
- `GET /api/v1/contrib/crontab/scripts/details` (`Scripts.pm#get`):
  - Gains an optional `bypass_filter` query param, same semantics as `list`'s,
    so the `configure.tt` policy editor can fetch option details for a script
    that isn't policy-listed yet (needed while an admin is defining policy for
    it for the first time).
  - Each returned option's `required` boolean now reflects policy membership,
    not the raw Getopt::Long spec.
- `POST /api/v1/contrib/crontab/jobs`, `PUT
  /api/v1/contrib/crontab/jobs/{job_id}`, and `POST
  /api/v1/contrib/crontab/jobs/migrate` — may now additionally respond `400`
  with a descriptive `error` message for a missing required option, alongside
  the existing script-allowlist/`non_repeatable`/`allowed_hours` validation
  errors.
- `api/openapi.json` is updated for all of the above.

## Behavior change on upgrade

Every option that previously showed a red asterisk purely because its Getopt::Long
spec used `=` will render as optional (no asterisk, no enforcement) until an
administrator explicitly adds it to that script's `required_options` in either
policy tier. This is the intended correctness fix, but is a visible behavior
change immediately after upgrading with no policy yet configured — worth calling
out in the changelog.

## Testing

- `t/02-script-policy-parsing.t`: extend for `required_options` parsing (per-tier)
  and union-merge semantics (server ∪ library, server-required entries can't be
  dropped by library).
- `t/03-script-policy-enforcement.t`: new `check_required_options` unit cases
  (missing option, present via long name, present via short alias, present via
  `--name=value` form, quoted-value command via `shellwords`), plus `add`/`update`
  enforcement cases (400 on missing, 201/200 on present).
- `t/04-script-policy-migration.t`: `migrate` enforcement case for a missing
  required option.
- A regression case confirming `_parse_option_spec` no longer returns a `required`
  key derived from `=`/`:` for any spec.
- No JS test harness exists in this repo; `buildCommandFromParams()` and the
  `configure.tt` checkbox editor are verified manually against a KTD instance, per
  this repo's existing testing conventions.

## Changelog

A `CHANGELOG.md` entry under `[Unreleased]` will be added once implemented,
following this repo's Keep a Changelog convention, and will call out the
behavior change noted above.
