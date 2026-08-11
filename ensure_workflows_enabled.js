#!/usr/bin/env node
//
// ensure_workflows_enabled.js
//
// Make sure this repository's GitHub Actions workflows are enabled *before* a
// release tag is pushed.
//
// GitHub automatically disables scheduled workflows after 60 days of repository
// inactivity (workflow state "disabled_inactivity"). While a workflow is
// disabled, push and tag events do NOT trigger it -- so a release tag pushed in
// that window silently fails to run CI or publish a release. This script checks
// the repository's workflows via the GitHub API and re-enables any that have
// been disabled, so the subsequent tag push behaves as expected.
//
// It uses the `gh` CLI purely for authentication (no token juggling) and is
// intentionally NON-FATAL: if gh is unavailable, unauthenticated, or an API
// call fails, it prints a warning and exits 0 so a release is never blocked by
// this safety check.

const { execFileSync } = require("child_process");

function gh(args) {
    return execFileSync("gh", args, { encoding: "utf8" });
}

function warn(message) {
    console.warn(`⚠ ${message}`);
}

function main() {
    // gh present and authenticated?
    try {
        execFileSync("gh", ["auth", "status"], { stdio: "ignore" });
    } catch (e) {
        warn("gh CLI not available or not authenticated; skipping workflow enable check.");
        warn("  Install https://cli.github.com/ and run `gh auth login` to enable this check.");
        return;
    }

    // Derive owner/repo from the origin remote (handles SSH and HTTPS forms).
    let slug;
    try {
        const url = execFileSync("git", ["remote", "get-url", "origin"], {
            encoding: "utf8",
        }).trim();
        const m = url.match(/github\.com[:/]([^/]+)\/(.+?)(?:\.git)?$/);
        if (!m) throw new Error(`could not parse GitHub owner/repo from origin URL: ${url}`);
        slug = `${m[1]}/${m[2]}`;
    } catch (e) {
        warn(`${e.message}; skipping workflow enable check.`);
        return;
    }

    // Repository-level Actions toggle. If Actions are disabled for the whole
    // repo, workflow-level enabling won't help, so surface it clearly.
    try {
        const perms = JSON.parse(gh(["api", `repos/${slug}/actions/permissions`]));
        if (perms.enabled === false) {
            warn(`GitHub Actions are DISABLED for ${slug} at the repository level.`);
            warn("  Enable them under Settings > Actions > General before releasing.");
        }
    } catch (e) {
        // Non-fatal: fall through to the workflow-level check.
    }

    // Workflow-level states.
    let workflows;
    try {
        workflows = JSON.parse(gh(["api", `repos/${slug}/actions/workflows`])).workflows || [];
    } catch (e) {
        warn(`could not list workflows for ${slug}; skipping. (${e.message})`);
        return;
    }

    const disabled = workflows.filter(
        (w) => w.state === "disabled_inactivity" || w.state === "disabled_manually"
    );

    if (disabled.length === 0) {
        console.log(`✓ GitHub Actions workflows for ${slug} are active.`);
        return;
    }

    for (const w of disabled) {
        process.stdout.write(`↻ Re-enabling workflow "${w.name}" (was ${w.state})... `);
        try {
            gh(["api", "-X", "PUT", `repos/${slug}/actions/workflows/${w.id}/enable`]);
            console.log("done.");
        } catch (e) {
            console.log("failed.");
            warn(`  ${e.message}`);
        }
    }
}

main();
