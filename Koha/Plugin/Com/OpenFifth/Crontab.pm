use utf8;

package Koha::Plugin::Com::OpenFifth::Crontab;

use Modern::Perl;

## Set up persistent warning filter for bundled dependencies
## This must be done before BEGIN to catch all warnings
$SIG{__WARN__} = sub {
    my $msg = shift;
    ## Suppress redefinition warnings from bundled Config::Crontab
    ## These warnings occur when install_plugins.pl loads plugins multiple times
    ## with nocache => 1, forcing module recompilation
    return if $msg =~ /(?:Subroutine|Constant subroutine) .* redefined at .*Config\/Crontab\.pm/;
    ## Pass through all other warnings
    CORE::warn($msg);
};

BEGIN {
    use Module::Metadata;
    my $path = Module::Metadata->find_module_by_name(__PACKAGE__);
    $path =~ s{[.]pm$}{/lib}xms;
    unless ( eval { require Config::Crontab; 1;  } ) {
        unshift @INC, $path;
    }

    require Config::Crontab;
    Config::Crontab->import();
}

use base qw(Koha::Plugins::Base);

use POSIX qw(strftime);
use JSON;

use C4::Context;

our $VERSION         = '1.3.5';
our $MINIMUM_VERSION = "22.11.00.000";

our $metadata = {
    name            => 'Crontab',
    author          => 'Martin Renvoize',
    description     => 'Script scheduling',
    date_authored   => '2023-04-25',
    date_updated    => '2026-02-09',
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
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

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_logging   => $self->retrieve_data('enable_logging'),
            user_allowlist   => $self->retrieve_data('user_allowlist'),
            script_allowlist => $self->retrieve_data('script_allowlist'),
            backup_retention => $self->retrieve_data('backup_retention') || 10,
        );

        $self->output_html( $template->output() );
    } else {
        my $backup_retention = $cgi->param('backup_retention');
        # Validate backup_retention is between 1 and 100
        $backup_retention = 10 unless ($backup_retention && $backup_retention >= 1 && $backup_retention <= 100);

        $self->store_data(
            {
                enable_logging   => $cgi->param('enable_logging'),
                user_allowlist   => $cgi->param('user_allowlist'),
                script_allowlist => $cgi->param('script_allowlist'),
                backup_retention => $backup_retention,
            }
        );
        $self->go_home();
    }
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

    # Remove all plugin-managed jobs from crontab
    require Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;
    require Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job;

    my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new({
        plugin => $self,
    });
    my $job_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new({
        crontab => $crontab,
    });

    # Create final backup before uninstall
    my $backup_file = $crontab->backup_crontab();
    warn "Created final backup before uninstall: $backup_file" if $backup_file;

    # Remove all plugin-managed jobs
    my $result = $crontab->safely_modify_crontab(sub {
        my ($ct) = @_;

        my @blocks_to_remove;
        for my $block ($ct->blocks) {
            my $metadata = $job_model->parse_job_metadata($block);
            if ($metadata && $metadata->{'managed-by'} &&
                $metadata->{'managed-by'} eq 'koha-crontab-plugin') {
                push @blocks_to_remove, $block;
            }
        }

        for my $block (@blocks_to_remove) {
            $ct->remove($block);
        }

        warn "Removed " . scalar(@blocks_to_remove) . " plugin-managed job(s) from crontab";

        return 1;
    });

    unless ($result->{success}) {
        warn "Failed to remove plugin jobs from crontab: " . $result->{error};
    }

    return 1;
}

1;
