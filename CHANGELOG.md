# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
