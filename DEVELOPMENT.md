# Development

Setup, testing, version management and the release workflow for this plugin.
For what the plugin does and how to configure it, see `README.md`.

## Prerequisites

- Node.js and npm (version management and releases only)
- A Koha development environment to run the tests against. See the Koha
  monorepo's `AGENTS.md` for the `kd` workflow (`kd up <name> --plugin <path>`
  boots a koha-testing-docker instance with this plugin mounted).

```bash
npm ci
```

## Testing

The tests run inside a Koha container, because the plugin loads Koha modules.
Against a KTD instance with the plugin mounted at `/kohadevbox/plugins/koha-plugin-crontab`:

```bash
ktd --name <instance> --shell --run \
  'cd /kohadevbox/plugins/koha-plugin-crontab && prove -I. -Ilib t/'
```

Notes:

- `t/08-install-default-script-policy.t` clears the instance's `script_policy`
  setting when it finishes. With an empty policy no scripts can be scheduled, so
  re-seed it (call `install`, or save the policy on the Configure page) before
  trying the UI against the same instance.
- Some tests write crontab backups under
  `Koha/Plugin/Com/OpenFifth/Crontab/backups/`; those files are not tracked.
- `t/19-template-conventions.t` checks that every template uses core's plugin
  wrapper, carries a CSP nonce on inline scripts and styles, and that the
  Configure form posts with a CSRF token. Keep that true when editing templates.

## Version management

`package.json` is the source of truth for the version.

```bash
npm run version:patch   # 1.0.0 -> 1.0.1
npm run version:minor   # 1.0.0 -> 1.1.0
npm run version:major   # 1.0.0 -> 2.0.0
```

This increments the version, updates `version` and `previous_version` in
`package.json`, rewrites `our $VERSION` and `date_updated` in
`Koha/Plugin/Com/OpenFifth/Crontab.pm`, and promotes the `[Unreleased]` section
of `CHANGELOG.md` to a dated `[X.Y.Z]` section with a fresh empty `[Unreleased]`
heading.

Add notable changes to `CHANGELOG.md` under `[Unreleased]` as you make them
([Keep a Changelog](https://keepachangelog.com/) format).

## Releases

```bash
npm run release:patch   # or release:minor / release:major
```

Before touching any files, the script checks that you are on `main`, that the
working tree is clean (untracked files count), and that local `main` is not
behind `origin/main`. If any check fails it aborts before bumping anything, so a
failed push never leaves a stray local commit or tag behind. Otherwise it bumps
the version, commits (`chore: bump version`), tags `vX.Y.Z`, and pushes with
`--follow-tags`.

Pushing the tag starts the GitHub Actions workflow, which:

1. Runs the tests against Koha `main`, `stable` and `oldstable` in
   koha-testing-docker.
2. Builds the `.kpz` package.
3. Creates a GitHub release with the `.kpz` and `CHANGELOG.md`.

The release commit and its tag are pushed together, and GitHub fires a push
event for each. A `guard` job skips the branch-push copy of the test matrix when
the commit already carries a release tag, so each release runs the matrix once.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
(`fix:`, `feat:`, `chore:`, `docs:`).

## Perl dependencies

The plugin has no external dependencies: `Config::Crontab` is bundled under
`Koha/Plugin/Com/OpenFifth/Crontab/lib`. If a CPAN module is ever needed, list it
in a `cpanfile` at the repository root (`requires 'Some::Module';`); the CI
workflow installs it with `cpanm --installdeps` before running the tests.

## Maintenance

The `release` job pins `bywatersolutions/github-action-koha-plugin-create-kpz`
to a tagged release (currently `@v3`) rather than a floating branch, so a release
build only picks up a new version of that action when you deliberately bump the
pin. Check [its releases](https://github.com/bywatersolutions/github-action-koha-plugin-create-kpz/releases)
occasionally and update the `uses:` line in `.github/workflows/main.yml` when a
new major version ships.

Values from GitHub expressions (`${{ ... }}`) are passed to shell steps through
`env:` rather than interpolated into the script, so they cannot inject shell
syntax. Keep it that way when editing the workflow.
