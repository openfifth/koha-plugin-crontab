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

package Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;
use Config::Crontab;

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup - Versions of the crontab and restoring them

=head1 SYNOPSIS

    my $backup = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup->new(
        { crontab => $file, job => $job_model, script => $script_model } );

    my $versions = $backup->versions;
    my $result   = $backup->restore($name);

=head1 DESCRIPTION

Every change the plugin makes keeps the crontab as it was before and after as
a backup file. This presents those files as versions and restores one.

Restoring replaces the whole crontab, so it is held to the same rules as
every other way of changing it: a version is refused if any plugin-managed job
in it could not be added, enabled or edited today. Without that, restoring an
old backup would be a way round the script policy, the command checks and the
environment rule. See C<restore_errors>.

=head1 METHODS

=head2 new

    my $backup = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup->new( {
        crontab => $file,       # Cron::File
        job     => $job_model,  # Cron::Job
        script  => $script_model,  # Cron::Script
    } );

=cut

sub new {
    my ( $class, $args ) = @_;

    for my $required (qw(crontab job script)) {
        die "$required required" unless $args->{$required};
    }

    return bless { map { $_ => $args->{$_} } qw(crontab job script) }, $class;
}

=head2 versions

The crontab's versions, newest first.

    my $versions = $backup->versions;

Each is a hashref: C<name>, C<timestamp> (epoch seconds), C<display>, C<size>
(bytes), C<jobs> and C<enabled_jobs> (plugin-managed), C<entries> (all cron
lines, including disabled ones), C<copies>, and C<current>, true if it is
identical to the crontab as it is now.

Consecutive backups with identical content are one version (C<copies> counts
them): older installs wrote the "after" of one change and the "before" of the
next as two identical files.

=cut

sub versions {
    my ($self) = @_;

    my $current = $self->{crontab}->read();
    my $current_sha = $current ? _sha( $current->dump ) : '';

    my @versions;
    my $previous_sha = '';

    for my $backup ( @{ $self->{crontab}->list_backups } ) {
        my $text = _slurp( $backup->{filename} );
        my $sha  = _sha($text);

        if ( @versions && $sha eq $previous_sha ) {
            $versions[-1]{copies}++;
            next;
        }
        $previous_sha = $sha;

        my $ct   = $self->_parse( $backup->{filename} );
        my $jobs = $ct ? $self->{job}->get_plugin_managed_jobs($ct) : [];

        push @versions,
          {
            name         => $backup->{name},
            timestamp    => $backup->{timestamp},
            display      => $backup->{display},
            size         => length $text,
            jobs         => scalar @$jobs,
            enabled_jobs => scalar( grep { $_->{enabled} } @$jobs ),
            entries      => $ct ? scalar( () = $ct->select( -type => 'event' ) ) : 0,
            copies       => 1,
            current      => $sha eq $current_sha ? 1 : 0,
          };
    }

    return \@versions;
}

=head2 content

The text of a version, or of the crontab as it is now (C<current>).

    my $version = $backup->content($name);    # { name, display, content } or undef

=cut

sub content {
    my ( $self, $name ) = @_;

    if ( defined $name && !ref $name && $name eq 'current' ) {
        my $current = $self->{crontab}->read() or return;
        return { name => 'current', display => 'Current crontab', content => $current->dump };
    }

    my $path = $self->{crontab}->backup_path($name) or return;
    my ($listed) = grep { $_->{name} eq $name } @{ $self->{crontab}->list_backups };

    return {
        name    => $name,
        display => $listed ? $listed->{display} : $name,
        content => _slurp($path),
    };
}

=head2 restore

Restore the crontab to a version, refusing it if it fails C<restore_errors>.

    my $result = $backup->restore($name);

Returns the result of C<Cron::File-E<gt>restore_backup>: C<success> and
C<restored_from>, C<pre_backup>, C<backup>; or C<error>, with C<not_found>
when there is no such version.

=cut

sub restore {
    my ( $self, $name ) = @_;

    return $self->{crontab}->restore_backup( $name, sub { $self->restore_errors(@_) } );
}

=head2 restore_errors

Why a version can't be restored, or undef if it can.

    my $error = $backup->restore_errors( $candidate_ct, $current_ct );

C<$candidate_ct> is the crontab to restore and C<$current_ct> the live one.
Every plugin-managed job in the candidate is checked:

=over 4

=item * its fields are well formed (single line, sensible length) -- a newline
would start a new crontab line;

=item * it adds or changes no job-level environment variable compared with the
same job now (a job that no longer exists counts as having none), so a restore
cannot bring back variables that were removed;

=item * if it is enabled: its command is a single safe command line for a
script the policy permits, and it satisfies that script's requirements and
policy (see C<Cron::Script-E<gt>job_policy_error>), counting duplicates among
the candidate's own entries.

=back

Disabled jobs only need well-formed fields and no new environment variables:
enabling one later re-checks everything, as it always has. Entries the plugin
doesn't manage are the system's own and restored as they were.

=cut

sub restore_errors {
    my ( $self, $candidate, $current ) = @_;

    my $job_model    = $self->{job};
    my $script_model = $self->{script};

    my $jobs    = $job_model->get_plugin_managed_jobs($candidate);
    my $entries = $job_model->get_all_crontab_entries($candidate);
    my %current_environment = map { $_->{id} => $_->{environment} } @{ $job_model->get_plugin_managed_jobs($current) };

    my @errors;
    for my $job (@$jobs) {
        my $label = "'" . ( length $job->{name} ? $job->{name} : $job->{id} ) . "'";

        my $fields = $job_model->validate_job_fields($job);
        unless ( $fields->{valid} ) {
            push @errors, "$label: $fields->{error}";
            next;
        }

        my $environment = $job_model->check_environment_change( $job->{environment}, $current_environment{ $job->{id} } );
        push @errors, "$label: $environment->{error}" unless $environment->{valid};

        next unless $job->{enabled};

        my $validation = $script_model->validate_command( $job->{command} );
        unless ( $validation->{valid} ) {
            push @errors, "$label: $validation->{error}";
            next;
        }

        my $error = $script_model->job_policy_error( $validation, $job->{command}, $job->{schedule}, $job->{id}, $entries );
        push @errors, "$label: $error" if $error;
    }

    return unless @errors;

    my $shown = join( '; ', @errors[ 0 .. ( $#errors < 4 ? $#errors : 4 ) ] );
    my $more  = @errors > 5 ? ' (and ' . ( @errors - 5 ) . ' more)' : '';

    return "This version can't be restored because it contains "
      . ( @errors == 1 ? 'a job' : 'jobs' )
      . " that could not be saved today: $shown$more";
}

sub _parse {
    my ( $self, $path ) = @_;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read( -file => $path );

    return $ct->error ? undef : $ct;
}

sub _slurp {
    my ($file) = @_;

    open my $fh, '<', $file or return '';
    local $/;
    return scalar <$fh> // '';
}

# Identical apart from trailing whitespace is the same version
sub _sha {
    my ($text) = @_;

    $text =~ s/\s+\z//;
    return sha256_hex($text);
}

1;
