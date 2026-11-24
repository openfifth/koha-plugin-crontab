# Crontab

This is a plugin for [Koha](http://koha-community.org) that simplifies the management of a koha instances local crontab.

We put the power in the hands of the user by exposing the local crontab to them as an administration tool plugin, allowing them to edit
existing lines, schedules and environment as well as adding new jobs all from within the staff UI. Existing, unmanaged system crontab
entries are shown for reference and can be migrated into plugin management with a single click.

# Configuration

## Configuration Page

The plugin provides a configuration page accessible via the "Configure" action in the Koha plugins interface. This page allows administrators to:

- **User Allowlist**: Restrict access to the plugin by specifying a comma-separated list of borrowernumbers using the build in user search picker
- **Script Policy**: Define which subset of KOHA_CRON commands/scripts are permitted to run, and optionally mark individual scripts as non-repeatable (only one scheduled instance at a time), restricted to specific hours of the day, or as requiring specific command-line options to have a value before a job can be saved (recommended for security)
- **Logging**: Toggle whether job add/edit/delete/enable/disable actions are recorded to Koha's action log
- **Backup Retention**: How many crontab backups to keep before older ones are pruned (default: 10)

Both allowlists can also be configured via the koha-conf.xml file (see below).

**An empty script policy means no scripts can be scheduled.** Nothing is permitted until the policy lists scripts (on the Configure page, or in a server policy file; see below). On a fresh install the plugin seeds a short list of routine scheduled jobs (`longoverdue.pl`, `update_patrons_category.pl`, `process_message_queue.pl`, `holds/holds_reminder.pl`) from [`default-policy.yaml`](Koha/Plugin/Com/OpenFifth/Crontab/default-policy.yaml) inside the plugin. Scripts that can do a lot of damage with the wrong arguments (`runreport.pl`, `cleanup_database.pl`, `gather_print_notices.pl`) are deliberately left out; add them yourself if you want them. The seed happens once, at install time: it can be freely edited from the Configure page afterwards, and upgrading never overwrites a policy you've already configured. If a server policy file is configured, nothing is seeded, because the server policy applies as written.

## Policy files

The script policy is a YAML document. The same schema is used by the server policy file (see `koha_plugin_crontab_script_policy` below) and is what the Configure page stores for the library policy. The shipped [`default-policy.yaml`](Koha/Plugin/Com/OpenFifth/Crontab/default-policy.yaml) is a complete, commented example.

```yaml
# Which scripts under $KOHA_CRON_PATH may be scheduled. A script not listed here
# cannot be added to the crontab through the plugin.
scripts:
  - path: runreport.pl
  - path: cleanup_database.pl
    non_repeatable: true          # only one scheduled instance at a time
    allowed_hours: "0-5,22-23"    # only run overnight
  - path: longoverdue.pl
    required_options: [lost, charge]   # must be present in the command
  - path: holds/holds_reminder.pl
```

`path` is relative to `KOHA_CRON_PATH` and names either a script or a directory:

- a script: `runreport.pl`, `holds/holds_reminder.pl`, or just the file name (`nightly.pl` covers `batch/nightly.pl`);
- a directory, with or without a trailing slash: `batch/` or `batch` covers everything under it, including subdirectories.

A path is **not** a string prefix: `cleanup` does not cover `cleanup_database.pl`, and `batch` does not cover `batch_evil.pl`. Matching is case-sensitive.

`allowed_hours` takes hours and ranges (`"2"`, `"0-5"`, `"0-5,22-23"`).

## Server-managed policy (for administrators)

If you run Koha for several libraries, or manage it with configuration management such as Ansible, you can set the script policy from a file on the server instead of leaving it to staff on the Configure page. The file uses the same schema as above and is the **policy of record**: staff can narrow it but never widen it.

1. Write the policy file somewhere the Koha instance user can read, but not write (so staff cannot alter it through the plugin):

   ```yaml
   # /etc/koha/plugins/crontab-script-policy.yaml
   scripts:
     - path: process_message_queue.pl
     - path: holds/holds_reminder.pl
     - path: cleanup_database.pl
       non_repeatable: true
       allowed_hours: "0-5"
       required_options: [sessions]
   ```

2. Point the plugin at it in the instance's `koha-conf.xml`, inside the `<config>` block, and restart Plack:

   ```xml
   <koha_plugin_crontab_script_policy>/etc/koha/plugins/crontab-script-policy.yaml</koha_plugin_crontab_script_policy>
   ```

How it combines with the library policy edited on the Configure page:

- **Scripts:** only scripts the server file lists can be scheduled. A script it doesn't list is refused no matter what the library policy says, and an empty or unconfigured library policy does *not* unlock everything (nor does it lock everything out: it inherits the server file). The library policy can only select a subset.
- **Unconfigured or empty library policy:** the server file applies as written. On install the plugin does not seed its own default list when a server file is configured, so there is nothing to narrow it.
- **Constraints:** `non_repeatable` and `required_options` set by the server file always apply, and the library policy can only add to them. `allowed_hours` can only be narrowed, to the hours both allow.
- **Directories:** an entry naming a directory (for example `batch/`) offers every script under it. Entries name scripts or directories, never a bare string prefix.
- **No restart needed for edits:** the file is read on every request, so changing it (an Ansible run, for instance) takes effect immediately. Only changing the `koha-conf.xml` setting needs a restart.

An Ansible sketch:

```yaml
- name: Crontab plugin script policy
  ansible.builtin.copy:
    dest: /etc/koha/plugins/crontab-script-policy.yaml
    owner: root
    group: "{{ koha_instance }}-koha"
    mode: "0640"
    content: |
      scripts:
      {% for script in crontab_plugin_scripts %}
        - path: {{ script.path }}
      {% if script.non_repeatable | default(false) %}
          non_repeatable: true
      {% endif %}
      {% endfor %}

- name: Point the plugin at it
  community.general.xml:
    path: "/etc/koha/sites/{{ koha_instance }}/koha-conf.xml"
    xpath: /yazgfs/config/koha_plugin_crontab_script_policy
    value: /etc/koha/plugins/crontab-script-policy.yaml
  notify: restart plack
```

## Environment variables

Jobs cannot set environment variables. In a crontab an environment line is not scoped to the job next to it: it stays in effect for every entry that follows it in the file, managed by this plugin or not, until it is set again. A "per-job" `MAILTO=` would silently redirect the output of every later job, and a `KOHA_CRON_PATH` or `PERL5OPT` could redirect or hijack every script that follows.

Set variables once, in the crontab header, where they are explicit. They are shown read-only on the plugin's page.

A job that already carries environment variables (from an older version, or a hand-edited crontab) keeps working, and the variables can be removed from the job's edit form, but none can be added or changed.

## koha-conf.xml Settings

This plugin can accept some settings stored in the koha configuration file, inside the `config` block.

### koha_plugin_crontab_cronfile

`<koha_plugin_crontab_cronfile>/etc/cron.d/koha-mylibrary</koha_plugin_crontab_cronfile>`
By default the plugin will use the Koha user's crontab. If this option is set, it will use this file instead.

### koha_plugin_crontab_script_policy

`<koha_plugin_crontab_script_policy>/etc/koha/plugins/crontab-script-policy.yaml</koha_plugin_crontab_script_policy>`
If set, points to a YAML file defining a server-enforced ceiling on which scripts may be scheduled and what scheduling constraints apply to them. The library's own Script Policy setting (configured via the Configure page) can only select a subset of what this file allows, can only tighten (never loosen) any `non_repeatable`/`allowed_hours` it sets, and can only add to (never remove from) any `required_options` it sets. If this option is not set, the library's Script Policy setting alone governs, as before.

### koha_plugin_crontab_user_allowlist

`<koha_plugin_crontab_user_allowlist>1,2,3</koha_plugin_crontab_user_allowlist>`
This option, if set, will allow only the users whose borrowernumbers are listed to access the plugin
even if the patron has the admin plugins permission.

## Security Considerations

**IMPORTANT**: This plugin executes shell commands with instance-level permissions. Please observe the following security best practices:

### What the script policy does and does not limit

The script policy limits **which scripts** can be scheduled, and can require options (`required_options`), restrict hours and prevent duplicate instances. It does **not** restrict the values of a script's arguments, and it is not a sandbox: an allowlisted script can do anything it can do, with any arguments, as the Koha user. Treat access to the plugin as equivalent to running the allowlisted scripts yourself. In particular, among the scripts you might add:

- `runreport.pl` runs any saved report and can email or SFTP its output (`--to`, `--from`, `--sftp-dest-id`), so it can read whatever a saved report can read.
- `cleanup_database.pl` deletes data by age, including Koha's action logs (`--logs`) and sessions. A job with a short retention shortens the audit trail, including the entries this plugin writes when logging is enabled.
- `gather_print_notices.pl` writes files to whatever directory it is given, anywhere the Koha user can write.

Remove any script from the policy that the people who can use the plugin shouldn't be able to use this way, and keep the user allowlist (below) tight.

### Permission Management

- **Configure Plugins Permission** (`plugins_tool_configure`): Users with this permission can:
  - Modify the user allowlist (controlling who can use the plugin)
  - Modify the command allowlist (controlling which scripts can be executed)
  - **Recommendation**: Severely restrict this permission to only the most trusted administrators

- **Use Administrative Plugins Permission** (`plugins_tool_admin`): Users need only this permission to:
  - Create, edit, enable/disable, and delete scheduled jobs
  - Use the plugin's core functionality
  - **Recommendation**: Grant this permission to staff who need to manage cron jobs

### Additional Security Measures

- **Always configure the user allowlist** to restrict access to trusted staff only
- **Use the command allowlist** to define which scripts and commands are permitted to run
- **Use absolute paths** for all commands (e.g., `/usr/bin/perl /path/to/script.pl`)
- **Regular audits**: Review configured jobs periodically to ensure no unauthorized commands are present
- **Monitor logs**: Check `cron_manager.log` for suspicious activity

# Installation

## Enable the plugin system

To set up the Koha plugin system you must first make some changes to your install.

- Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
- Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
- Add the pluginsdir to your apache PERL5LIB paths and koha-plack startup scripts PERL5LIB
- Restart your webserver

Once set up is complete you will need to alter your UseKohaPlugins system preference.

## Dependencies

This plugin has **no external dependencies**. All required modules (Config::Crontab, UUID) are either bundled with the plugin or already available in Koha core.

## Download and install the plugin

The latest releases of this plugin can be obtained from the [release page](https://github.com/openfifth/koha-plugin-crontab/releases) where you can download the relevant \*.kpz file
