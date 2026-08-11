const fs = require('fs');
const path = require('path');

console.log('Starting version increment...');

// Read package.json
const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
console.log(`Current version in package.json: ${packageJson.version}`);

// Get the version bump type from command line
const bumpType = process.argv[2];
if (!['major', 'minor', 'patch'].includes(bumpType)) {
    console.error('Please specify version bump type: major, minor, or patch');
    process.exit(1);
}
console.log(`Bump type: ${bumpType}`);

// Parse current version
let [major, minor, patch] = packageJson.version.split('.').map(Number);
console.log(`Current version parts: major=${major}, minor=${minor}, patch=${patch}`);

// Bump version based on type
switch (bumpType) {
    case 'major':
        major++;
        minor = 0;
        patch = 0;
        console.log('Major version bump: incrementing major, resetting minor and patch');
        break;
    case 'minor':
        minor++;
        patch = 0;
        console.log('Minor version bump: incrementing minor, resetting patch');
        break;
    case 'patch':
        patch++;
        console.log('Patch version bump: incrementing patch');
        break;
}

const newVersion = `${major}.${minor}.${patch}`;
console.log(`New version will be: ${newVersion}`);

// Update package.json
console.log('Updating package.json...');
packageJson.previous_version = packageJson.version;
packageJson.version = newVersion;
fs.writeFileSync('package.json', JSON.stringify(packageJson, null, 2) + '\n');
console.log('package.json updated successfully');

// Update plugin file
console.log(`Updating plugin file: ${packageJson.plugin.pm_path}`);
const pluginFile = packageJson.plugin.pm_path;
let pluginContent = fs.readFileSync(pluginFile, 'utf8');
const oldVersionMatch = pluginContent.match(/our \$VERSION\s+=\s+["'](\d+\.\d+\.\d+)["'];/);
if (oldVersionMatch) {
    console.log(`Found current version in plugin file: ${oldVersionMatch[1]}`);
} else {
    console.log('Warning: Could not find version in plugin file');
}

// Get today's date in YYYY-MM-DD format
const today = new Date().toISOString().split('T')[0];
console.log(`Today's date: ${today}`);

// Update version (preserve original whitespace formatting)
pluginContent = pluginContent.replace(
    /our \$VERSION\s+=\s+["']\d+\.\d+\.\d+["'];/,
    `our $VERSION         = '${newVersion}';`
);

// Update date_updated
const oldDateMatch = pluginContent.match(/date_updated\s*=>\s*["']([^"']+)["']/);
if (oldDateMatch) {
    console.log(`Found current date_updated in plugin file: ${oldDateMatch[1]}`);
} else {
    console.log('Warning: Could not find date_updated in plugin file');
}

pluginContent = pluginContent.replace(
    /date_updated\s*=>\s*["'][^"']+["']/,
    `date_updated    => '${today}'`
);

fs.writeFileSync(pluginFile, pluginContent);
console.log('Plugin file updated successfully');

// Update CHANGELOG.md: promote [Unreleased] to the new version, refresh links
updateChangelog(packageJson.previous_version, newVersion, today);

console.log(`\nVersion bump complete!`);
console.log(`Previous version: ${packageJson.previous_version}`);
console.log(`New version: ${newVersion}`);
console.log(`Date updated: ${today}`);

function updateChangelog(oldVersion, newVersion, today) {
    const changelogPath = 'CHANGELOG.md';
    if (!fs.existsSync(changelogPath)) {
        console.log('No CHANGELOG.md found — skipping changelog update');
        return;
    }

    let changelog = fs.readFileSync(changelogPath, 'utf8');

    const unreleasedHeader = '## [Unreleased]';
    if (!changelog.includes(unreleasedHeader)) {
        console.log('Warning: CHANGELOG.md has no [Unreleased] section — skipping');
        return;
    }

    // Promote [Unreleased] to a dated version section, leaving a fresh empty
    // [Unreleased] above it so the next release can accumulate entries.
    changelog = changelog.replace(
        unreleasedHeader,
        `${unreleasedHeader}\n\n## [${newVersion}] - ${today}`
    );

    // Refresh the comparison links at the bottom of the file:
    //   [Unreleased]: .../compare/vOLD...HEAD  →  vNEW...HEAD
    //   insert       [NEW]: .../compare/vOLD...vNEW   above the previous one
    const linkRegex = /^\[Unreleased\]:\s*(.+?)\/compare\/v[\d.]+\.\.\.HEAD\s*$/m;
    const linkMatch = changelog.match(linkRegex);
    if (linkMatch) {
        const repoBase = linkMatch[1];
        const replacement =
            `[Unreleased]: ${repoBase}/compare/v${newVersion}...HEAD\n` +
            `[${newVersion}]: ${repoBase}/compare/v${oldVersion}...v${newVersion}`;
        changelog = changelog.replace(linkRegex, replacement);
    } else {
        console.log('Warning: Could not find [Unreleased] compare link — links not updated');
    }

    fs.writeFileSync(changelogPath, changelog);
    console.log(`CHANGELOG.md: promoted [Unreleased] → [${newVersion}] (${today})`);
}
