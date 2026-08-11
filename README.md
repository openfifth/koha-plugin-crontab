# Crontab

This is a plugin for [Koha](http://koha-community.org) that simplifies the management of a koha instances local crontab.

We put the power in the hands of the user by exposing the local crontab to them as an administration tool plugin, allowing them to edit
existing lines, schedules and environment as well as adding new jobs all from within the staff UI.

# Configuration

## Configuration Page

The plugin provides a configuration page accessible via the "Configure" action in the Koha plugins interface. This page allows administrators to:

- **User Allowlist**: Restrict access to the plugin by specifying a comma-separated list of borrowernumbers using the build in user search picker
- **Script Policy**: Define which subset of KOHA_CRON commands/scripts are permitted to run, and optionally mark individual scripts as non-repeatable (only one scheduled instance at a time) or restricted to specific hours of the day (recommended for security)

Both allowlists can also be configured via the koha-conf.xml file (see below).

## koha-conf.xml Settings

This plugin can accept some settings stored in the koha configuration file, inside the `config` block.

### koha_plugin_crontab_cronfile

`<koha_plugin_crontab_cronfile>/etc/cron.d/koha-mylibrary</koha_plugin_crontab_cronfile>`
By default the plugin will use the Koha user's crontab. If this option is set, it will use this file instead.

### koha_plugin_crontab_script_policy

`<koha_plugin_crontab_script_policy>/etc/koha/plugins/crontab-script-policy.yaml</koha_plugin_crontab_script_policy>`
If set, points to a YAML file defining a server-enforced ceiling on which scripts may be scheduled and what scheduling constraints apply to them. The library's own Script Policy setting (configured via the Configure page) can only select a subset of what this file allows, and can only tighten (never loosen) any `non_repeatable`/`allowed_hours` it sets. See the plugin's Configure page for the schema. If this option is not set, the library's Script Policy setting alone governs, as before.

### koha_plugin_crontab_user_allowlist

`<koha_plugin_crontab_user_allowlist>1,2,3</koha_plugin_crontab_user_allowlist>`
This option, if set, will allow only the users whose borrowernumbers are listed to access the plugin
even if the patron has the admin plugins permission.

## Security Considerations

**IMPORTANT**: This plugin executes shell commands with instance-level permissions. Please observe the following security best practices:

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

The latest releases of this plugin can be obtained from the [release page](https://github.com/ptfs-europe/koha-plugin-crontab/releases) where you can download the relevant \*.kpz file
