# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `GET /scripts/details` returning a 500 for any script without a script policy attached, breaking the script picker's parameter builder for most scripts

### Added
- Script policy: mark individual allowed scripts as non-repeatable (only one scheduled instance at a time) or restricted to specific hours of the day
- Optional server-administrator-controlled script policy file (`koha_plugin_crontab_script_policy` koha-conf.xml entry) that acts as a ceiling/floor on the library's own script policy settings
- Warning badge on the Managed Jobs table for jobs that currently violate script policy (existing jobs are never blocked or altered, only flagged)

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


