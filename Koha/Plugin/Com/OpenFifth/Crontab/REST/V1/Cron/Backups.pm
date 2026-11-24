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

package Koha::Plugin::Com::OpenFifth::Crontab::REST::V1::Cron::Backups;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use C4::Log qw( logaction );
use Koha::Plugin::Com::OpenFifth::Crontab;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup;
use Try::Tiny;
use Mojo::JSON;

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::REST::V1::Cron::Backups

=head1 API

Versions of the crontab: list them, read one, restore one.

=head2 Class Methods

=head3 list

List the crontab's versions, newest first

=cut

sub list {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    try {
        my ($backup) = _models();

        return $c->render(
            status  => 200,
            openapi => { backups => $backup->versions }
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to list backups: $_" }
        );
    };
}

=head3 get

The text of a version, or of the current crontab (C<current>)

=cut

sub get {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    my $name = $c->validation->param('name');

    try {
        my ($backup) = _models();
        my $version = $backup->content($name);

        unless ($version) {
            return $c->render(
                status  => 404,
                openapi => { error => "Backup not found" }
            );
        }

        return $c->render(
            status  => 200,
            openapi => $version
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to read backup: $_" }
        );
    };
}

=head3 restore

Restore the crontab to a version. The version is held to the same checks as
adding or enabling a job (see C<Cron::Backup::restore_errors>); the current
crontab is saved as a version first so the restore can be undone.

=cut

sub restore {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    my $name = $c->validation->param('name');

    my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    try {
        my ($backup) = _models($plugin);
        my $result = $backup->restore($name);

        if ( $result->{not_found} ) {
            return $c->render(
                status  => 404,
                openapi => { error => "Backup not found" }
            );
        }

        unless ( $result->{success} ) {

            # A version refused by the checks is the user's to act on; anything
            # else (a lock that could not be taken, a failed write) is ours.
            my $refused = $result->{error} =~ /can't be restored|could not be read|not a valid crontab/;
            return $c->render(
                status  => $refused ? 400 : 500,
                openapi => { error => $result->{error} }
            );
        }

        logaction( 'SYSTEMPREFERENCE', 'MODIFY', $name, "CrontabPlugin: Restored the crontab from backup '$name'" )
          if $logging;

        return $c->render(
            status  => 200,
            openapi => {
                success       => Mojo::JSON->true,
                restored_from => $name,
                message       => "Crontab restored from backup",
            }
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to restore backup: $_" }
        );
    };
}

=head2 Internal Methods

=head3 _models

The backup model with the file, job and script models it works with

=cut

sub _models {
    my ($plugin) = @_;

    $plugin ||= Koha::Plugin::Com::OpenFifth::Crontab->new( {} );

    my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $plugin } );
    my $job     = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => $crontab } );
    my $script  = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $crontab } );

    return ( Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup->new( { crontab => $crontab, job => $job, script => $script } ), $crontab );
}

=head3 _check_user_allowlist

Check if the current user is authorized to use the plugin

=cut

sub _check_user_allowlist {
    my ($c) = @_;

    # Check if user is logged in
    my $userenv = C4::Context->userenv;
    unless ( $userenv && $userenv->{number} ) {
        return $c->render(
            status  => 401,
            openapi => { error => "Authentication required" }
        );
    }

    # Superlibrarians always have access
    my $is_superlibrarian = $userenv->{flags} && $userenv->{flags} == 1;
    return if $is_superlibrarian;

    # Check allowlist if configured
    my $plugin         = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
    my $user_allowlist = $plugin->retrieve_data('user_allowlist');

    if ($user_allowlist) {
        my @borrowernumbers = split( /\s*,\s*/, $user_allowlist );
        my $bn              = $userenv->{number};

        if ( grep( /^$bn$/, @borrowernumbers ) ) {
            return;
        }
        else {
            return $c->render(
                status  => 401,
                openapi =>
                  { error => "You are not authorised to use this plugin" }
            );
        }
    }

    # If no allowlist is configured, allow access
    return;
}

1;
