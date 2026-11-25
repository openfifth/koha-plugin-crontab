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

package Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;

# Core crontab file operations with safety features

use Modern::Perl;
use Fcntl qw(:flock);
use POSIX qw(strftime);
use Try::Tiny;
use File::Spec;
use File::Path qw(make_path);
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;
use Config::Crontab;
use C4::Context;

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::Cron::File - Safe crontab file operations

=head1 SYNOPSIS

    my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new({
        backup_dir => '/path/to/backups',
        lock_timeout => 10,
    });

    my $result = $crontab->safely_modify_crontab(sub {
        my ($ct) = @_;
        # Make modifications to $ct here
        return 1;
    });

=head1 DESCRIPTION

This module handles all crontab file operations with locking, backups, and validation.

=head1 METHODS

=cut

=head2 new

Constructor

    my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new({
        plugin => $plugin_instance,            # Plugin instance for accessing config
        lock_timeout => 10,                    # Lock timeout in seconds (default: 10)
    });

=cut

sub new {
    my ( $class, $args ) = @_;

    my $plugin = $args->{plugin} or die "Plugin instance required";

    # Where new backups go. Koha deletes a plugin's whole directory when it is
    # uninstalled, so backups kept under it (the old location, still read
    # below) are lost with it; a location outside it survives.
    my $legacy_dir = $plugin->mbf_dir . '/backups';
    my $backup_dir = $args->{backup_dir};
    $backup_dir //= $plugin->persistent_backup_dir() if $plugin->can('persistent_backup_dir');
    $backup_dir //= $legacy_dir;

    my $self = {
        plugin       => $plugin,
        backup_dir   => $backup_dir,
        legacy_dir   => $legacy_dir ne $backup_dir ? $legacy_dir : undef,
        lock_timeout => $args->{lock_timeout} || 10,
        lockfile     => $args->{lockfile} || '/tmp/koha-crontab-plugin.lock',
        cron_file    => $args->{cron_file},    # tests: operate on this file instead of the configured crontab
    };

    bless $self, $class;

    # Ensure backup directory exists
    unless ( -d $self->{backup_dir} ) {
        make_path( $self->{backup_dir} )
          or die "Cannot create backup directory $self->{backup_dir}: $!";
    }

    return $self;
}

=head2 safely_modify_crontab

Safely modify the crontab with file locking, backups, and validation

    my $result = $crontab->safely_modify_crontab(sub {
        my ($ct) = @_;
        # Make modifications to $ct here
        return 1;
    });

    if ($result->{success}) {
        print "Modification successful\n";
    } else {
        print "Error: $result->{error}\n";
    }

=cut

sub safely_modify_crontab {
    my ( $self, $modification_callback ) = @_;

    # Acquire exclusive lock
    my $lock_fh = $self->_acquire_lock();
    unless ($lock_fh) {
        return {
            success => 0,
            error   =>
"Could not acquire lock (another operation in progress or timeout)"
        };
    }

    # Store a backup of the current state BEFORE we start
    # This is for rollback purposes only
    my $pre_modification_backup = $self->backup_crontab();

    my $result = eval {

        # 1. Read and parse current crontab
        my $ct = $self->read();
        unless ($ct) {
            die "Failed to read crontab\n";
        }

        # 2. Pre-modification validation
        unless ( $self->validate($ct) ) {
            die "Pre-modification validation failed\n";
        }

        # 3. Apply modifications via callback
        my $callback_result = $modification_callback->($ct);
        unless ($callback_result) {
            die "Modification callback returned failure\n";
        }

        # 4. Dry-run validation (parse the string we'll write)
        my $draft   = $ct->dump();
        my $test_ct = Config::Crontab->new();
        $test_ct->parse($draft);
        unless ( $self->validate($test_ct) ) {
            die "Post-modification validation failed\n";
        }

        # 5. Write atomically
        my $cron_file = $self->_cron_file();
        $ct->file($cron_file) if $cron_file;
        $ct->write();

        # 6. Create backup AFTER successful modification
        my $post_modification_backup = $self->backup_crontab();

        return {
            success    => 1,
            backup     => $post_modification_backup,
            pre_backup => $pre_modification_backup,
            message    => "Crontab modified successfully"
        };
    };

    if ($@) {

        # Restore from pre-modification backup on failure
        my $restore_result = $self->restore_crontab($pre_modification_backup);
        $result = {
            success  => 0,
            error    => "Modification failed: $@",
            restored => $restore_result,
        };
    }

    # Release lock
    $self->_release_lock($lock_fh);

    return $result;
}

=head2 backup_crontab

Create a backup (a version) of the current crontab

Returns the backup filename on success, undef on failure.

Nothing is written when the crontab is identical to the newest backup: that
backup already is this version, and its name is returned. Every change makes
a "before" and an "after" backup, and without this each is stored twice
(the after of one change is the before of the next), halving how many
distinct versions retention keeps. A backup is never overwritten: two
different states in the same second get distinct names.

=cut

sub backup_crontab {
    my ($self) = @_;

    try {
        my $ct        = Config::Crontab->new();
        my $cron_file = $self->_cron_file();
        $ct->file($cron_file) if $cron_file;
        $ct->read();
        my $dump = $ct->dump();

        my $latest = $self->_get_latest_backup();
        if ( $latest && _same_text( _slurp($latest), $dump ) ) {
            return $latest;
        }

        my $filename = $self->_new_backup_filename();
        open my $fh, '>', $filename or die "Cannot write $filename: $!\n";
        print {$fh} $dump;
        close $fh or die "Cannot write $filename: $!\n";

        # Cleanup old backups
        $self->_cleanup_old_backups();

        return $filename;
    }
    catch {
        warn "Failed to create backup: $_";
        return;
    };
}

=head2 restore_crontab

Restore the most recent crontab backup, or the given backup file

Returns 1 on success, 0 on failure. This is the unvalidated rollback used by
C<safely_modify_crontab> to undo a failed change with the file it just took;
to restore a chosen version for a user, use C<restore_backup>.

=cut

sub restore_crontab {
    my ( $self, $specific_backup ) = @_;

    my $backup_file;

    if ($specific_backup) {
        $backup_file = $specific_backup;
    }
    else {
        # Find the most recent backup
        $backup_file = $self->_get_latest_backup();
    }

    unless ( $backup_file && -f $backup_file ) {
        warn "No backup file found to restore";
        return 0;
    }

    try {
        my $ct = Config::Crontab->new();
        $ct->mode('block');

        # Config::Crontab::read takes -file => $path; a bare path is ignored
        # and the live crontab is read instead, which would "restore" the
        # current state and nothing else.
        $ct->read( -file => $backup_file );
        die "Could not read backup: " . $ct->error . "\n" if $ct->error;

        # Reading set the object's file to the backup; write to the real
        # crontab ('' means the user's crontab, via crontab(1)).
        $ct->file( $self->_cron_file() || '' );
        $ct->write();

        return 1;
    }
    catch {
        warn "Failed to restore from backup $backup_file: $_";
        return 0;
    };
}

=head2 persistent_backup_dir

A directory for backups that survives uninstalling the plugin, or undef if
there isn't a usable one (the caller then keeps backups under the plugin's own
directory).

    my $dir = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File::persistent_backup_dir();

It is C<koha-crontab-plugin> under the C<backupdir> set in C<koha-conf.xml>
(C</var/spool/koha/E<lt>instanceE<gt>> on package installs), created if need be.

=cut

sub persistent_backup_dir {
    my $base = C4::Context->config('backupdir');
    return unless defined $base && length $base && File::Spec->file_name_is_absolute($base);

    my $dir = File::Spec->catdir( $base, 'koha-crontab-plugin' );
    unless ( -d $dir ) {
        return unless -d $base && -w $base;
        make_path($dir);
    }

    return -d $dir && -w $dir ? $dir : undef;
}

# Every directory holding backups, the one new backups go to first
sub _backup_dirs {
    my ($self) = @_;

    return grep { defined $_ && -d $_ } ( $self->{backup_dir}, $self->{legacy_dir} );
}

=head2 backup_path

The full path of the backup called C<$name>, or undef if the name isn't a
backup file name or no such backup exists. This is the only way a
user-supplied name becomes a path: the name must match the backup naming
scheme exactly, so it can't point anywhere else.

=cut

# \z, not $: a trailing newline must not slip through a name check
my $BACKUP_NAME = qr/^crontab_backup_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:_(\d+))?\z/;

sub backup_path {
    my ( $self, $name ) = @_;

    return unless defined $name && !ref $name && $name =~ $BACKUP_NAME;

    for my $dir ( $self->_backup_dirs ) {
        my $path = File::Spec->catfile( $dir, $name );
        return $path if -f $path;
    }

    return;
}

=head2 restore_backup

Restore the crontab to a chosen version, through the same lock, pre-change
backup and rollback as any other change.

    my $result = $crontab->restore_backup( $name, sub {
        my ( $candidate, $current ) = @_;
        return "reason" if ...;    # or undef to allow the restore
    } );

The optional validator is given the candidate crontab (the version to restore)
and the current one, and returns an error message to refuse the restore. It
runs before anything is touched, and again under the lock in case the crontab
changed in between. The current crontab is saved as a version first, so a
restore can itself be undone.

Returns a hashref: C<success>, and either C<restored_from>, C<pre_backup> and
C<backup>, or C<error> (and C<not_found> if no such backup).

=cut

sub restore_backup {
    my ( $self, $name, $validator ) = @_;

    my $path = $self->backup_path($name)
      or return { success => 0, not_found => 1, error => "Backup not found" };

    my $candidate = Config::Crontab->new();
    $candidate->mode('block');
    $candidate->read( -file => $path );
    return { success => 0, error => "The backup could not be read: " . $candidate->error }
      if $candidate->error;
    return { success => 0, error => "The backup is not a valid crontab" }
      unless $self->validate($candidate);

    if ($validator) {
        my $current = $self->read()
          or return { success => 0, error => "The current crontab could not be read" };
        if ( my $error = $validator->( $candidate, $current ) ) {
            return { success => 0, error => $error };
        }
    }

    my $result = $self->safely_modify_crontab(
        sub {
            my ($ct) = @_;

            if ($validator) {
                if ( my $error = $validator->( $candidate, $ct ) ) {
                    die "$error\n";
                }
            }

            $ct->blocks( [ $candidate->blocks ] );
            return 1;
        }
    );

    unless ( $result->{success} ) {
        $result->{error} =~ s/^Modification failed: //;
        $result->{error} =~ s/\s+\z//;
        return $result;
    }

    $result->{restored_from} = $name;
    return $result;
}

=head2 list_backups

Get a list of available backup files, sorted by date (newest first)

Returns an arrayref of hashrefs with 'filename' and 'timestamp' keys

=cut

sub list_backups {
    my ($self) = @_;

    # A backup name is in the first directory that has it
    my %dir_of;
    for my $dir ( reverse $self->_backup_dirs ) {
        opendir( my $dh, $dir ) or next;
        for my $name ( readdir $dh ) {
            $dir_of{$name} = $dir if $name =~ $BACKUP_NAME && -f File::Spec->catfile( $dir, $name );
        }
        closedir($dh);
    }
    my @backups = keys %dir_of;

    # Newest first: by timestamp, then by the suffix that tells apart backups
    # taken in the same second ("..._2" is later than "...")
    @backups = sort { _backup_sort_key($b) cmp _backup_sort_key($a) } @backups;

    my @result;
    for my $backup (@backups) {
        my $fullpath = File::Spec->catfile( $dir_of{$backup}, $backup );
        my $mtime    = ( stat($fullpath) )[9];
        push @result,
          {
            filename  => $fullpath,
            name      => $backup,
            timestamp => $mtime,
            display   => strftime( "%Y-%m-%d %H:%M:%S", localtime($mtime) ),
          };
    }

    return \@result;
}

=head2 read

Read and parse the crontab file

Returns Config::Crontab object on success, undef on failure

=cut

sub read {
    my ($self) = @_;

    try {
        my $ct = Config::Crontab->new();
        my $cron_file = $self->_cron_file();
        $ct->file($cron_file) if $cron_file;
        $ct->mode('block');
        $ct->read();
        return $ct;
    }
    catch {
        warn "Failed to read crontab: $_";
        return;
    };
}

=head2 validate

Validate a crontab object

    my $is_valid = $crontab->validate($ct);

Returns 1 if valid, 0 if invalid

=cut

sub validate {
    my ( $self, $ct ) = @_;

    return 0 unless $ct;

    try {
        # Test that we can dump the crontab (catches syntax errors)
        my $dump = $ct->dump();

        # Validate that we can parse what we dumped
        my $test_ct = Config::Crontab->new();
        $test_ct->parse($dump);

        # Validate all events have valid cron syntax
        for my $block ( $ct->blocks ) {
            for my $event ( $block->select( -type => 'event' ) ) {
                my $datetime = $event->datetime;

                # Basic cron syntax validation (5 fields)
                my @fields = split /\s+/, $datetime;
                unless ( @fields == 5 ) {
                    warn
                      "Invalid cron datetime (must have 5 fields): $datetime";
                    return 0;
                }

                # Validate each field has allowed characters. Month/day-of-week
                # fields may use 3-letter name abbreviations (e.g. Mon, Jan),
                # which Config::Crontab itself accepts (see RE_DM/RE_DTMOY/
                # RE_DTDOW in lib/Config/Crontab.pm) - this check must stay at
                # least as permissive or it rejects schedules the underlying
                # parser considers valid.
                for my $field (@fields) {
                    unless ( $field =~ /^[\w\*\/\-\,]+$/ ) {
                        warn "Invalid cron field: $field";
                        return 0;
                    }
                }
            }
        }

        return 1;
    }
    catch {
        warn "Crontab validation failed: $_";
        return 0;
    };
}

=head2 Internal Methods

=cut

sub _acquire_lock {
    my ($self) = @_;

    open my $lock_fh, '>', $self->{lockfile} or do {
        warn "Cannot create lockfile: $!";
        return;
    };

    my $timeout = $self->{lock_timeout};
    my $locked  = 0;

    eval {
        local $SIG{ALRM} = sub { die "Lock timeout\n" };
        alarm($timeout);
        flock( $lock_fh, LOCK_EX ) or die "Cannot lock: $!";
        $locked = 1;
        alarm(0);
    };

    if ( !$locked ) {
        close $lock_fh;
        warn "Failed to acquire lock: $@" if $@;
        return;
    }

    return $lock_fh;
}

sub _release_lock {
    my ( $self, $lock_fh ) = @_;

    return unless $lock_fh;

    flock( $lock_fh, LOCK_UN );
    close $lock_fh;
}

sub _cron_file {
    my ($self) = @_;

    return $self->{cron_file} if defined $self->{cron_file};
    return C4::Context->config('koha_plugin_crontab_cronfile') || undef;
}

sub _backup_sort_key {
    my ($name) = @_;

    my ( $when, $n ) = $name =~ $BACKUP_NAME;
    return sprintf( '%s_%06d', $when // '', $n // 1 );
}

sub _new_backup_filename {
    my ($self) = @_;

    my $when = strftime( "%Y-%m-%d_%H-%M-%S", localtime );
    my $base = File::Spec->catfile( $self->{backup_dir}, "crontab_backup_$when" );

    # Backups taken in the same second get an increasing suffix. It has to
    # increase past what exists, not fill the first gap: once retention has
    # pruned the oldest of them its name is free again, and a new version
    # reusing it would sort as the oldest and be pruned straight away.
    my $highest = 0;
    for my $dir ( $self->_backup_dirs ) {
        opendir( my $dh, $dir ) or next;
        for my $existing ( readdir $dh ) {
            next unless $existing =~ /^crontab_backup_\Q$when\E(?:_(\d+))?\z/;
            my $n = defined $1 ? $1 : 1;
            $highest = $n if $n > $highest;
        }
        closedir $dh;
    }

    return $highest ? $base . '_' . ( $highest + 1 ) : $base;
}

sub _slurp {
    my ($file) = @_;

    open my $fh, '<', $file or return '';
    local $/;
    return scalar <$fh> // '';
}

# Trailing whitespace is not a difference between versions
sub _same_text {
    my ( $x, $y ) = @_;

    s/\s+\z// for ( $x, $y );
    return $x eq $y;
}

sub _get_latest_backup {
    my ($self) = @_;

    my $backups = $self->list_backups();
    return unless @$backups;

    return $backups->[0]->{filename};
}

sub _cleanup_old_backups {
    my ($self) = @_;

    my $backups   = $self->list_backups();
    my $retention = $self->{plugin}->retrieve_data('backup_retention') || 10;

    # Remove backups beyond retention limit
    if ( @$backups > $retention ) {
        my @to_remove = @$backups[ $retention .. $#$backups ];
        for my $backup (@to_remove) {
            unlink $backup->{filename}
              or warn "Failed to remove old backup $backup->{filename}: $!";
        }
    }
}

1;

=head1 AUTHOR

Martin Renvoize <martin.renvoize@openfifth.co.uk>

=head1 COPYRIGHT

Copyright 2025 Open Fifth

=head1 LICENSE

Copyright 2023-2026 Open Fifth and contributors

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See the F<LICENSE> file for the full text.

=cut
