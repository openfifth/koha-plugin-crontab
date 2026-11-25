# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright 2023-2026 Open Fifth and contributors
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

use utf8;

package Koha::Plugin::Com::OpenFifth::Crontab;

use Modern::Perl;

use Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;
use Config::Crontab;

use base qw(Koha::Plugins::Base);

use POSIX qw(strftime);
use JSON qw(encode_json decode_json);
use YAML::XS qw(Dump);

use C4::Context;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script;

our $VERSION         = '1.8.0';
our $MINIMUM_VERSION = "25.05.00";

our $metadata = {
    name            => 'Crontab',
    author          => 'Martin Renvoize',
    # Koha's plugin management screen only renders the fields above and below,
    # not 'license', so the licence is also stated in the description.
    description     => 'Script scheduling. Licensed under AGPL-3.0-or-later.',
    date_authored   => '2023-04-25',
    date_updated    => '2026-11-24',
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    license         => 'AGPL-3.0-or-later',
    license_url     => 'https://www.gnu.org/licenses/agpl-3.0.html',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);

    return $self;
}

sub admin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    # Check user authorization
    my $userenv = C4::Context->userenv;
    my $is_superlibrarian = $userenv->{flags} && $userenv->{flags} == 1;

    unless ($is_superlibrarian) {
        if ( my $user_allowlist = $self->retrieve_data('user_allowlist') ) {
            my @borrowernumbers = split( /\s*,\s*/, $user_allowlist );
            my $bn              = $userenv->{number};
            unless ( grep( /^$bn$/, @borrowernumbers ) ) {
                my $t = $self->get_template( { file => 'access_denied.tt' } );
                $self->output_html( $t->output() );
                exit 0;
            }
        }
    }

    # Show the modern job management interface
    my $template = $self->get_template( { file => 'crontab.tt' } );

    # Tell the admin up front if nothing can be scheduled yet, rather than
    # leaving them with an empty script browser and an unexplained error.
    my $crontab      = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $self } );
    my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $crontab } );
    $template->param( no_scripts_permitted => scalar @{ $script_model->get_available_scripts() } ? 0 : 1 );

    $self->output_html( $template->output() );
}

sub api_routes {
    my ($self) = @_;

    my $spec_str = $self->mbf_read('api/openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'crontab';
}

=head2 configure

  Configuration routine

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    # Only a POST carrying op=cud-save changes anything. Koha's CSRF protection
    # covers POST requests (and requires the form's csrf_token); it does not stop
    # a state-changing GET, so a save request that arrives any other way, e.g.
    # a link with save=1 in the query string, just renders the form.
    my $is_save = ( $cgi->request_method // '' ) eq 'POST' && ( scalar( $cgi->param('op') ) // '' ) eq 'cud-save';

    unless ($is_save) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $crontab      = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $self } );
        my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $crontab } );
        my $server_policy = $script_model->get_server_policy();

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_logging   => $self->retrieve_data('enable_logging'),
            user_allowlist   => $self->retrieve_data('user_allowlist'),
            script_policy    => $self->_library_policy_json($script_model),
            server_policy    => encode_json( { scripts => $server_policy } ),
            backup_retention => $self->retrieve_data('backup_retention') || 10,
        );

        $self->output_html( $template->output() );
    } else {
        my $backup_retention = $cgi->param('backup_retention');
        # Validate backup_retention is between 1 and 100
        $backup_retention = 10 unless ($backup_retention && $backup_retention >= 1 && $backup_retention <= 100);

        my $policy_json = $cgi->param('script_policy') || '{"scripts":[]}';
        my $policy_data = eval { decode_json($policy_json) } || { scripts => [] };

        # Normalize JSON booleans to plain scalars before YAML serialization
        # This prevents !!perl/scalar:JSON::PP::Boolean tags in the YAML output
        for my $script ( @{ $policy_data->{scripts} || [] } ) {
            $script->{non_repeatable} = $script->{non_repeatable} ? 1 : 0;
            $script->{allowed_hours}  = $script->{allowed_hours} // '';
        }

        my $policy_yaml = Dump($policy_data);

        $self->store_data(
            {
                # scalar(): in a hash constructor param() would run in list context,
                # so a repeated parameter could inject extra keys into the stored settings.
                enable_logging   => scalar $cgi->param('enable_logging'),
                user_allowlist   => scalar $cgi->param('user_allowlist'),
                script_policy    => $policy_yaml,
                backup_retention => $backup_retention,
            }
        );
        $self->go_home();
    }
}

=head2 upgrade

Plugin upgrade routine, run automatically by Koha::Plugins::Base when the
installed version is behind the current one. Migrates the legacy
plain-line 'script_allowlist' setting to the structured YAML
'script_policy' setting.

=cut

sub upgrade {
    my ($self) = @_;

    my $legacy = $self->retrieve_data('script_allowlist');

    if ( defined $legacy && $legacy =~ /\S/ ) {
        my $yaml_text = $self->_convert_legacy_allowlist_text($legacy);
        $self->store_data( { script_policy => $yaml_text } );
    }

    $self->store_data( { script_allowlist => undef } );

    return 1;
}

=head2 _convert_legacy_allowlist_text

Convert the legacy newline-separated script_allowlist text into the new
YAML script_policy document shape. The legacy format never carried policy
fields, so converted entries have none.

    my $yaml_text = $plugin->_convert_legacy_allowlist_text($legacy_text);

=cut

sub _convert_legacy_allowlist_text {
    my ( $self, $legacy_text ) = @_;

    my @patterns = grep { /\S/ } split( /\r?\n/, $legacy_text // '' );

    my @scripts = map {
        my $path = $_;
        $path =~ s/^\s+|\s+$//g;
        { path => $path };
    } @patterns;

    return Dump( { scripts => \@scripts } );
}

=head2 _library_policy_json

Build the JSON the configure.tt script-policy editor renders from, via
C<Cron::Script>'s normalizing C<get_library_policy> rather than a bare
YAML::XS::Load of the stored setting -- a bare Load leaves non_repeatable
as a plain string, which encode_json then serializes as the JSON string
"0"/"1" (both truthy in JS), making the Non-repeatable checkbox always
render checked regardless of the stored value.

    my $json = $plugin->_library_policy_json($script_model);

=cut

sub _library_policy_json {
    my ( $self, $script_model ) = @_;

    return encode_json( { scripts => $script_model->get_library_policy() } );
}

sub install() {
    my ( $self, $args ) = @_;

    # Ensure backup directory exists
    my $backup_dir = $self->mbf_dir . '/backups';
    unless (-d $backup_dir) {
        require File::Path;
        File::Path::make_path($backup_dir) or do {
            warn "Failed to create backup directory: $!";
            return 0;
        };
    }

    # Check if crontab file exists, create template if not
    my $ct = Config::Crontab->new();
    my $cron_file = C4::Context->config('koha_plugin_crontab_cronfile') || undef;
    $ct->file($cron_file) if $cron_file;

    # Try to read existing crontab
    my $existing;
    $ct->read or do {
        $existing = 0;
    };

    unless ( $existing ) {
        warn "No crontab found, installing default";

        # Create template content
        my $header_block = Config::Crontab::Block->new();
        my $header_comment = qq{# Koha Example Crontab File
#
# This is an example of a crontab file for Debian.  It may not work
# in other versions of crontab, like on Solaris 8 or BSD, for example.
#
# While similar in structure,
# this is NOT an example for cron (as root).  Cron takes an extra
# argument per line to designate the user to run as.  You could
# reasonably extrapolate the needed info from here though.
#
# WARNING: These jobs will do things like charge fines, send
# potentially VERY MANY emails to patrons and even debar offending
# users.  DO NOT RUN OR SCHEDULE these jobs without being sure you
# really intend to.  Make sure the relevant message templates are
# configured to your liking before scheduling messages to be sent.
};

        $header_block->first(
            Config::Crontab::Comment->new( -data => $header_comment ) );
        $ct->first($header_block);

        # Add environment variables
        my $env_block = Config::Crontab::Block->new();
        my $env_lines;

        push @{$env_lines},
            Config::Crontab::Comment->new( -data => '# ENVIRONMENT' );

        push @{$env_lines},
            Config::Crontab::Env->new(
            -name   => 'KOHA_CONF',
            -value  =>  $ENV{KOHA_CONF} || '/etc/koha/koha-conf.xml',
            -active => 1
            );


        push @{$env_lines},
            Config::Crontab::Env->new(
            -name   => 'PERL5LIB',
            -value  => $ENV{PERL5LIB} || '/usr/share/koha/lib',
            -active => 1
            );

        push @{$env_lines},
            Config::Crontab::Comment->new( -data => '# Some additional variables to save you typing');

        push @{$env_lines},
            Config::Crontab::Env->new(
            -name   => 'KOHA_CRON_PATH',
            -value  => '/usr/share/koha/bin/cronjobs',
            -active => 1
            );

        $env_block->lines($env_lines);

        $ct->after( $header_block, $env_block );

        eval { $ct->write(); };
        if ($@) {
            warn "Failed to create crontab template: $@";
            return 0;
        }

        warn "Created crontab template successfully";
    }

    # Set default backup retention if not already configured
    unless (defined $self->retrieve_data('backup_retention')) {
        $self->store_data({
            backup_retention => 10,
        });
    }

    # Seed a default script policy on a fresh install so the plugin doesn't
    # ship wide open (every script under KOHA_CRON_PATH schedulable). The
    # defaults live in default-policy.yaml rather than in code. Never
    # overwrites an already-configured policy.
    #
    # Skipped when a server policy file is configured: that file is the
    # administrators' policy, and a seeded library policy would silently
    # narrow it to the shipped defaults. With the library tier left unset the
    # server policy applies as written.
    unless ( defined $self->retrieve_data('script_policy') ) {
        my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => { plugin => $self } } );

        unless ( @{ $script_model->get_server_policy() } ) {
            my $defaults = $script_model->_load_policy_source( $script_model->get_default_policy_text() );

            unless (@$defaults) {
                warn "Crontab plugin: default-policy.yaml is missing or has no scripts; "
                    . "refusing to install with an unrestricted script policy";
                return 0;
            }

            $self->store_data( { script_policy => Dump( { scripts => $defaults } ) } );
        }
    }

    # Store installation success
    $self->store_data( {
        installation_date => strftime("%Y-%m-%d %H:%M:%S", localtime),
    } );

    return 1;
}

sub enable {
    my ( $self ) = @_;

    my $ct        = Config::Crontab->new();
    my $cron_file = C4::Context->config('koha_plugin_crontab_cronfile') || undef;
    $ct->file($cron_file) if $cron_file;
    $ct->read or do {
        warn "No crontab found, creating new one";
        return 0;
    };

    # Call parent enable method
    $self->SUPER::enable();

    # Create a backup on enable
    my $path       = $self->mbf_dir . '/backups/';
    my $now_string = strftime "%F_%H-%M-%S", localtime;
    my $filename   = $path . 'enable_' . $now_string;
    $ct->write("$filename") or do {
        warn "Could not write backup to $filename";
        return 0;
    };

    warn "Plugin enabled - jobs can now be managed via the web interface";

    return $self;
}

sub disable {
    my ( $self ) = @_;

    # Call parent disable method
    $self->SUPER::disable();

    # Create a backup on disable
    my $path       = $self->mbf_dir . '/backups/';
    my $now_string = strftime "%F_%H-%M-%S", localtime;
    my $filename   = $path . 'disable_' . $now_string;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read();
    $ct->write("$filename");

    warn "Plugin disabled - jobs remain in crontab but cannot be managed via UI";

    return $self;
}

sub uninstall {
    my ( $self ) = @_;

    # Deliberately leave the crontab alone. The jobs are the library's
    # schedule and keep running whether or not this plugin is installed;
    # removing them on uninstall (which is also what a plain re-install does)
    # silently stops the library's scheduled work. They are still there, as
    # ordinary cron entries, if the plugin is installed again.
    #
    # Note that Koha deletes this plugin's whole directory on uninstall, which
    # includes the crontab backups kept under it.
    return 1;
}

1;
