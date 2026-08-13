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

    my $plugin     = $args->{plugin} or die "Plugin instance required";
    my $backup_dir = $plugin->mbf_dir . '/backups';

    my $self = {
        plugin       => $plugin,
        backup_dir   => $backup_dir,
        lock_timeout => $args->{lock_timeout} || 10,
        lockfile     => '/tmp/koha-crontab-plugin.lock',
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
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->write();

        # 6. Create backup AFTER successful modification
        my $post_modification_backup = $self->backup_crontab();

        return {
            success => 1,
            backup  => $post_modification_backup,
            message => "Crontab modified successfully"
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

Create a backup of the current crontab file

Returns the backup filename on success, undef on failure

=cut

sub backup_crontab {
    my ($self) = @_;

    my $now_string = strftime "%Y-%m-%d_%H-%M-%S", localtime;
    my $filename =
      File::Spec->catfile( $self->{backup_dir}, "crontab_backup_$now_string" );

    try {
        my $ct = Config::Crontab->new();
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->read();
        $ct->write($filename);

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

Restore the most recent crontab backup

Returns 1 on success, 0 on failure

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
        $ct->read($backup_file);

        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->write();

        return 1;
    }
    catch {
        warn "Failed to restore from backup $backup_file: $_";
        return 0;
    };
}

=head2 list_backups

Get a list of available backup files, sorted by date (newest first)

Returns an arrayref of hashrefs with 'filename' and 'timestamp' keys

=cut

sub list_backups {
    my ($self) = @_;

    opendir( my $dh, $self->{backup_dir} ) or return [];
    my @backups = grep {
        /^crontab_backup_/ && -f File::Spec->catfile( $self->{backup_dir}, $_ )
    } readdir($dh);
    closedir($dh);

    # Sort by date (newest first)
    @backups = sort { $b cmp $a } @backups;

    my @result;
    for my $backup (@backups) {
        my $fullpath = File::Spec->catfile( $self->{backup_dir}, $backup );
        my $mtime    = ( stat($fullpath) )[9];
        push @result,
          {
            filename  => $fullpath,
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
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
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

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 3 of the License, or (at your option) any later version.

=cut
