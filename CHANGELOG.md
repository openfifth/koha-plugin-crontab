# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Uninstalling the plugin no longer removes its jobs from the crontab.** Uninstall (and so a re-install) used to strip every plugin-managed job, silently stopping the library's scheduled work. The jobs now stay in the crontab as ordinary cron entries. A final backup is taken first.
- **Crontab backups survive uninstalling the plugin.** Koha deletes a plugin's whole directory on uninstall, which used to take the backups with it. They are now kept in `koha-crontab-plugin/` under `backupdir` from `koha-conf.xml` when the Koha user can write there, else in `.crontab_backups/` in the instance's directory (the parent of `upload_path`, `/var/lib/koha/<instance>` on package installs), and only failing both in the plugin's own directory. Backups already in the plugin directory are still listed and can be restored; new ones go to the new location. The Versions tab warns about the fallback and has a **Download current crontab** button.

## [1.8.0] - 2026-11-24

### Added

- **Versions tab: browse, compare and restore earlier versions of the crontab.** Every change the plugin makes keeps the crontab as it was before and after as a backup; these are now listed as versions (newest first, with job counts), can be compared with the current crontab as a line diff, and can be restored. A restore replaces the whole crontab, so it is held to the same rules as adding or enabling a job: a version containing a plugin-managed job that could not be saved today (script no longer in the policy, unsupported shell syntax, missing required option, non-repeatable duplicate, a job-level environment variable that no longer exists) is refused, with the reasons shown. The current crontab is backed up first, so a restore can itself be undone. Restores are written to the action log when logging is enabled. New endpoints: `GET /backups`, `GET /backups/{name}`, `POST /backups/{name}/restore`.

### Fixed

- A failed change never actually rolled back: restoring the pre-modification backup ignored the backup's path and re-wrote the current file.
- Two backups taken in the same second overwrote each other, losing the "before" state, and each change left two identical backups. Backup names are now unique and consecutive duplicates are shown as one version.
- A job name or description containing `=` read back empty (Config::Crontab parses such a comment as a commented-out environment variable) and was lost the next time the job was saved. It also made a bogus environment variable appear on the job.
- A commented-out `#KOHA_CRON_PATH=...` line was treated as a real setting.

### Changed

- **The Configure page's per-script options are now one compact table.** Each selected script used to get its own card with a grid of checkboxes for every option, so the page grew quickly with the number of allowed scripts. It is now a scrolling table with a row per script (non-repeatable, allowed hours, required options). Scripts that declare their own options with `Koha::Script->describe_options` show the options they require as read-only badges and no option picker, since the script enforces them already; plain `GetOptions` scripts, which give no such signal, get a compact multi-select. Options set by the server administrator are marked, and directory entries get a single explanatory row.
- `GET /scripts/details` now reports `uses_describe_options` and, per option, `declared_required` (what the script itself requires, separate from `required`, which also includes policy-added options).
- **With a server policy file, the Configure page's script picker only offers what the server permits.** It used to list every script under `KOHA_CRON_PATH` and let administrators choose (or type) ones the server would then ignore. Now only the scripts the server file permits, and its directory entries, can be selected; free typing is off; and a saved selection the server no longer permits is flagged as ignored.
- **Library policy entries inside a server directory entry now work.** The tier merge only accepted a library path identical to a server path, so a server policy of `batch/` silently discarded a library selection of `batch/nightly.pl`. A library entry is now covered by an identical server entry or by a server directory that contains it, and the covering server entry's `non_repeatable`, `allowed_hours` and `required_options` apply to it.
- Tests no longer depend on a server policy file configured in the instance's `koha-conf.xml`, and `install()`'s decision not to seed a library policy when a server file exists is now covered.
- `runreport.pl` is back in the default script policy seeded on a fresh install: it is the script librarians most often want to control. It can email or SFTP any saved report's output, so the README's note on what the script policy does and does not limit still applies. Existing installations keep the policy they already have (the seed only happens once).

## [1.7.2] - 2026-11-24

### Security

- The Configure page's save read `enable_logging` and `user_allowlist` in list context inside a hash constructor, so a request repeating one of those parameters could inject extra keys into the stored plugin settings (CGI parameter injection). Exploiting it needs an authenticated administrator's POST carrying a valid CSRF token, so the impact is low, but the values are now read in scalar context and a test covers it.

### Changed

- Relicensed from GPL-3.0 to **AGPL-3.0-or-later**, matching the other Open Fifth plugins and the plugin template. Added the licence text (`LICENSE`), an `SPDX-License-Identifier` header on every first-party source file, and the licence in the plugin metadata. The bundled `Config::Crontab` keeps its own (Perl) licence.
- The main Crontab admin page now uses core's `wrapper-staff-tool-plugin.inc` like the Configure page: standard page title, breadcrumbs, sidebar and messages, instead of a hand-built page skeleton.
- The page's inline script and style carry Koha's Content-Security-Policy nonce, and DataTables is loaded after jQuery, so the page keeps working if an administrator sets `csp_mode` to `enabled`.
- Requests from the page to the REST API now send Koha's CSRF token (`CSRF-TOKEN` header) on POST, PUT and DELETE, as core's own fetch client does.

## [1.7.1] - 2026-11-24

### Security

- **The Configure page could be changed by a cross-site request.** Settings were saved whenever `save=1` appeared in the request, whatever the HTTP method, and the form submitted with GET and no CSRF token. Koha's CSRF protection covers POST requests only, so a link or redirect opened by an administrator could change the user allowlist, the script policy, logging and backup retention (including replacing the script policy with the attacker's choice) with no token and no interaction beyond the page load. Confirmed against 1.7.0: a bare `GET` with `save=1` changed the saved settings. The form now submits by POST with a CSRF token and `op=cud-save`, and the server only saves a POST carrying `op=cud-save`; any other request just renders the form. Installations should upgrade.

### Changed

- **Requires Koha 25.05 or later** (was 22.11). Needed for `csrf-token.inc` and the current staff plugin wrapper.
- The Configure page and the access-denied page now use core's `wrapper-staff-tool-plugin.inc`: standard page title, breadcrumbs, sidebar and messages, instead of a hand-built page skeleton.
- The Configure page's inline script and style carry Koha's Content-Security-Policy nonce, and its libraries (select2) are loaded after jQuery, so the page keeps working if an administrator sets `csp_mode` to `enabled`.
- The Cancel link and hidden form fields on the Configure page no longer hard-code or leave unescaped the plugin class and method.

## [1.7.0] - 2026-11-24

### Security

- **The server policy file was not an effective ceiling.** An empty effective policy was treated as "no policy, allow every script", so with a server policy file configured, a library policy that was unset, cleared, or listed only scripts the server file did not include offered **every script under `KOHA_CRON_PATH`** (and `validate_command` accepted them). The server file now holds: whenever a server or library policy exists, only scripts the effective policy allows can be scheduled, and an empty result means none. A server policy with an unset or cleared library policy is simply the server policy. Installations that rely on a server policy file should upgrade.
- **Jobs can no longer set environment variables.** In a crontab an environment line is not scoped to the job beside it: it stays in effect for every later entry in the file, managed by this plugin or not (verified against Debian cron, both `/etc/cron.d` and user crontabs). A "per-job" `MAILTO` or `TZ` silently changed every job after it, and `KOHA_CRON_PATH` (expanded in the command the plugin writes), `KOHA_CONF`, `PERL5OPT`, `LD_PRELOAD`, `PATH` and similar let an approved script load or run something else. The add, update and migrate endpoints now reject any new environment variable (`Cron::Job::check_environment_change`). Set variables once in the crontab header instead.
- A job that already carries environment variables keeps working and can have them removed from its edit form, but none can be added or changed. Existing environment lines still leak into the jobs after them until removed, so installations should audit for jobs that set them, in particular `KOHA_CRON_PATH`.

### Added

- `default-policy.yaml`, a commented example of the script policy schema, shipped in the plugin. README gains "Policy files" and "Environment variables" sections, and a "What the script policy does and does not limit" note: the policy restricts which scripts run, not their argument values, so allowlisting a script grants whatever it can do (for example `runreport.pl` emailing any saved report, `cleanup_database.pl` purging logs).

### Changed

- **Script policy paths now name a script or a directory, not a string prefix.** Matching was `index($path, $pattern) == 0`, so an entry `cleanup` also permitted `cleanup_database.pl` and `cleanup_anything_else.pl`, and `batch` permitted `batch_evil.pl`. An entry now matches only a script's relative path (`holds/holds_reminder.pl`), its file name (`runreport.pl`), or a directory containing it, written `batch/` or `batch` (nested subdirectories included). Case-sensitive. **Policies that relied on a bare prefix (for example `cleanup` to mean `cleanup_database.pl`) stop matching; list the script or directory explicitly.** Server policy files that name exact scripts are unaffected. The README documents the path rules.
- **An empty script policy now means no scripts, not every script.** Previously, with no server policy file and an unset or cleared library policy, every script under `KOHA_CRON_PATH` could be scheduled ("leave empty to allow all"). That is now refused: nothing can be scheduled until the policy lists scripts. **Upgrading installations whose library policy is empty or was never configured lose the ability to add jobs, enable existing ones, or change their commands until an administrator chooses scripts under Configure > Script Policy or sets a server policy file.** Existing crontab entries are untouched. The job list shows a warning when nothing is permitted, and the error message says what to do.
- The default script policy seeded on a fresh install is trimmed to routine scheduled jobs: `longoverdue.pl`, `update_patrons_category.pl`, `process_message_queue.pl` and `holds/holds_reminder.pl`. `runreport.pl`, `cleanup_database.pl` and `gather_print_notices.pl` are no longer seeded, because of how much they can do with the wrong arguments; add them from the Configure page if wanted.
- When a server policy file is configured, install no longer seeds the default library policy, which would silently narrow the server policy to the shipped defaults.
- README gains a "Server-managed policy (for administrators)" section: the file, how it combines with the library policy, and an Ansible sketch.
- The default script policy seeded on a fresh install now comes from `default-policy.yaml` instead of a list in code. Install refuses to seed an unrestricted policy if that file is missing.
- The job edit form lists a job's existing environment variables read-only (removable) and no longer offers to add one.

## [1.6.8] - 2026-11-24

### Security

- **Script allowlist bypass via shell syntax in the command.** `validate_command` only compared the first word of a command with the approved script list, so `approved.pl; anything`, `approved.pl $(anything)`, a pipe, `&&`, backticks, or a newline (which starts a second crontab line) were all accepted and then run with the Koha instance's privileges. Commands are now tokenized (`Cron::Script::parse_command`) and only plain words, quoting, simple `$NAME` references and file redirections (`>/dev/null 2>&1`) are accepted.
- **Crontab line injection through other free-text fields.** A newline in a job's `name`, `description`, `schedule`, or an environment variable name or value was written into the crontab verbatim and became a new, attacker-controlled crontab line. All of these are now validated as single-line (`Cron::Job::validate_job_fields`), environment variable names must be plain identifiers, and `Cron::Job::create_job_block` -- the single write path for add, update and migrate -- refuses unsafe data as a last line of defence.
- **Environment variables that load code.** `PERL5OPT`, `PERL5LIB`, `LD_*`, `PATH`, `BASH_ENV`, `PYTHON*`, `NODE_OPTIONS` and similar can no longer be set on a job: they let an approved script load arbitrary code.
- **Enabling a job skipped all validation.** Enabling a disabled job now re-validates its command against the approved list, its script's declared requirements, and its script policy (non-repeatable, allowed hours, required options), exactly as adding it would.

Anyone who can use the plugin (superlibrarians, or the configured user allowlist) could previously run arbitrary shell commands as the Koha user, defeating both allowlists. Upgrading is recommended for all installations.

### Added

- Server-side enforcement of required positional arguments: a job whose command supplies fewer bare arguments than its script's `args => { min => N }` declaration is rejected on add, update and enable, with the same wording core uses (`At least 1 output_directory argument required (got 0)`). Option values, `--`, `--opt=value`, `--no-opt`, short and legacy single-dash aliases, Getopt::Long's optional-value rule, and redirections are all accounted for when counting.
- Parsed script options now include `aliases` and `optional_value`.

### Changed

- Commands containing shell syntax other than quoting, `$NAME` references and redirections are now rejected, including when migrating an existing system cron entry (for example one that pipes into another command). Such entries need to be wrapped in a script.
- Migrated job descriptions built from multi-line crontab comments are now joined with spaces onto a single line.
- The OpenAPI spec now documents the `400` response of `POST /jobs/{job_id}/enable`.

### Changed

- `describe_options` detection is now anchored to a real `Koha::Script->describe_options(` call in executable code. Comments, POD, text after `__END__`, and `describe_options` on other classes no longer divert a plain-`GetOptions` script onto the describe_options parser (which would have dropped its options). Verified against the nine core cron scripts converted so far.

## [1.6.7] - 2026-09-22

### Added

- `Cron::Script`'s option parser now recognizes scripts converted to Koha core's new `Koha::Script->describe_options` convention (Koha bug 43546), reading their declared `required` options and required positional arguments as a genuine static signal, rather than the unreliable inference that was removed from plain-Getopt::Long parsing in v1.6.0.
- Script-declared required options (and required positional arguments) are now surfaced end-to-end: the script picker marks them required (union with any admin-curated `required_options` policy) with the same asterisk and client-side pre-flight check named options already had, and jobs are rejected server-side if a script-declared required option is missing -- even when no policy entry has been configured for that script at all, since this is a floor policy can only add to, not something an admin has to opt into first.
- Client-side validation for required positional arguments (previously nonexistent for any script), enforcing a script-declared minimum argument count before a job can be built/saved.

### Not yet done

- Positional-argument requirements are enforced client-side only; there is no server-side check yet for the number of bare arguments in a saved command (unlike named required options, which are enforced both client- and server-side).

## [1.6.6] - 2026-09-16

### Changed

- Fresh installs now seed the Script Policy with a curated default allowlist of commonly-used scripts (`runreport.pl`, `cleanup_database.pl`, `longoverdue.pl`, `update_patrons_category.pl`, `process_message_queue.pl`, `gather_print_notices.pl`, `holds/holds_reminder.pl`) instead of shipping wide open with every script under `KOHA_CRON_PATH` schedulable. Only applies at install time; never overwrites an already-configured policy on upgrade

### Fixed

- README release-page link still pointed at the old `ptfs-europe` GitHub org; documented the previously-undocumented Logging and Backup Retention settings
- Configure page's "Non-repeatable" script policy checkbox always rendered checked, regardless of the stored value: the GET path round-tripped the library-tier policy through a bare `YAML::XS::Load` + `encode_json`, which serializes `non_repeatable` as the JSON string `"0"`/`"1"` instead of a real JSON number — both truthy in JavaScript. Now routed through `Cron::Script`'s existing normalizing `get_library_policy`, matching how the server-tier policy was already handled

## [1.6.5] - 2026-08-13

### Fixed

- `Cron/Job.pm` and `Cron/File.pm` both `use Config::Crontab;` directly but relied on the main plugin module's `BEGIN` block having already added the bundled copy to `@INC` as a side effect of load order — this only held when the main module was loaded first in the same process, and broke under the plugin store's per-file isolated `perl -c` syntax check. Extracted the bootstrap into `Cron::VendorLib`, `use`d by every file that needs `Config::Crontab`, so each is independently loadable

## [1.6.4] - 2026-08-12

## [1.6.3] - 2026-08-12

### Fixed

- Plugin metadata was missing a `license` field and declared `minimum_version` as a 4-part string (`22.11.00.000`) that doesn't match any real Koha release tag; both blocked the plugin store's automated checks
- Bundled `Config::Crontab`'s `write()`/`remove_tab()` shelled out via backticks with the crontab owner interpolated directly into the command string (a latent shell-injection risk, though unreachable via this plugin's own usage, which always writes the crontab file directly); switched to argv-based `open(..., '-|', @cmd)` calls
- Replaced 14 `return undef;` statements (which return a one-element list in list context, not an empty list) with bare `return;`

## [1.6.2] - 2026-08-12

### Fixed

- Editing a migrated job (command referencing a script by its raw absolute path) failed to auto-detect the underlying script, since the script picker's auto-match only compared against the `$KOHA_CRON_PATH`-relative form and never the absolute path — this left the parameter builder empty and required manually re-browsing for the script
- Re-selecting a script from the "Browse Scripts" picker (including reselecting the same script already in use) always discarded any parameters already present on the command line, instead of pre-filling the builder from them
- Saving a job after editing parameters in the builder could silently drop all of them, because the command line was only synced from the builder's fields when the separate "Build Command" button was clicked; Save now builds the command from the builder automatically whenever it's in use
- Boolean option checkboxes (parameter builder, and script-policy checkboxes on the configure page) rendered as a flat sliver instead of a proper checkbox, because Koha's `staff-global.css` sets `input[type=checkbox] { height: unset }` with higher specificity than Bootstrap 5's `.form-check-input` rule

## [1.6.1] - 2026-08-11

### Fixed

- Creating or updating a job with a schedule using a 3-letter day-of-week or month name (e.g. `Mon`, `Jan` — valid, standard cron syntax) failed with a 500 error, because the crontab writer's own post-write validation was stricter than the underlying crontab parser it was double-checking
- Migrating a system (unmanaged) crontab entry whose command referenced a script by its raw absolute path (rather than the plugin's `$KOHA_CRON_PATH`-relative form) always failed with "Command must use a script from the approved list", even with no script policy configured, since command validation only ever matched the relative form

## [1.6.0] - 2026-08-11

### Fixed

- `GET /scripts/details` returning a 500 for any script without a script policy attached, breaking the script picker's parameter builder for most scripts
- Script options were marked "required" based on Getopt::Long's `=`/`:` syntax, which only indicates whether a value is needed _if_ the flag is used, not whether the flag itself is mandatory — this produced both false positives (options flagged required that scripts treat as optional) and an unenforced true positive (a genuinely mandatory option could still be saved blank). Required-ness is now driven entirely by an explicit `required_options` script policy field, curated by administrators and enforced both client- and server-side.

### Added

- Script policy: mark individual allowed scripts as non-repeatable (only one scheduled instance at a time), restricted to specific hours of the day, or as requiring specific command-line options to have a value before a job can be saved
- Optional server-administrator-controlled script policy file (`koha_plugin_crontab_script_policy` koha-conf.xml entry) that acts as a ceiling/floor on the library's own script policy settings
- Warning badge on the Managed Jobs table for jobs that currently violate script policy (existing jobs are never blocked or altered, only flagged)
- Migrate a system (unmanaged) crontab entry into a plugin-managed job directly from the System Jobs tab, preserving its schedule, command, and enabled state

### Changed

- Replaced Data::UUID with UUID module to eliminate external dependencies
- Updated README to clarify plugin has zero external dependencies
- Renamed the `script_allowlist` plugin setting to `script_policy` and switched its storage format from plain text lines to YAML; existing installations are migrated automatically on upgrade

### Removed

- Data::UUID dependency (replaced with UUID from Koha core)

## [1.2.2] - 2025-10-17

### Fixed

- Added missing package-lock.json file

## [1.2.1] - 2024-XX-XX

### Fixed

- Fixed package definition issues

## [1.2.0] - 2024-XX-XX

### Added

- Script allowlist with visual picker for administrator control
- Configurable backup retention system (default: 10 backups)
- Improved backup workflow with better organization

### Changed

- Enhanced backup system with configurable retention settings

## [1.1.0] - 2024-XX-XX

### Added

- Crontab template creation on installation
- Simplified to use user crontab by default
- Bundled Config::Crontab dependency into plugin

### Changed

- Rebranded from PTFS Europe to Open Fifth
- Updated build system to match plugin template
- Refactored REST controllers to REST/V1/Cron namespace
- Refactored Model classes to lib/Koha/Cron namespace
- Split Manager into focused Model layer classes
- Split Controller into REST::V1::Jobs and Scripts

### Fixed

- Suppressed subroutine redefinition warnings from bundled dependencies
- Removed unnecessary Config::Crontab availability checks

## [1.0.0] - 2024-XX-XX

### Added

- Initial stable release
- Script picker with parameter builder and POD viewer
- Select2 patron picker for allowlist management
- User allowlist configuration in plugin settings
- Predefined schedules and commands
- Loading spinners for better UX
- Crontab management through web interface
- Bootstrap 5 compatibility
- Ability to limit plugin access to specific users (#2)
- Logging of changes to Koha action logs (#3)
- Option to point to specific cron file via plugin config (#11)
- Environment variable management
- Backup/restore functionality
- Admin plugin type implementation

### Changed

- Converted from tool to admin plugin type
- Extracted crontab management into Manager.pm infrastructure
- Tidied Crontab.pm and Controller.pm code

### Fixed

- Semantic issue with patron allowlist check (#2)
- Typo in README.md
