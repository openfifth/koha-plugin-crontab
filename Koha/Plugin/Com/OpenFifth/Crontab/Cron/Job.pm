package Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job;

# Job management operations

use Modern::Perl;
use POSIX qw(strftime);
use UUID;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;
use Config::Crontab;
use Scalar::Util qw(refaddr);

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job - Job management operations

=head1 SYNOPSIS

    my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new({
        crontab => $crontab_instance,
    });

    my $jobs = $job->get_plugin_managed_jobs();
    my $block = $job->create_job_block({ ... });

=head1 DESCRIPTION

This module handles all job-related operations including creation, parsing,
listing, and modification of cron jobs.

=head1 METHODS

=cut

=head2 new

Constructor

    my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new({
        crontab => $crontab_instance,  # Required: Crontab model instance
    });

=cut

sub new {
    my ( $class, $args ) = @_;

    die "crontab instance required" unless $args->{crontab};

    my $self = {
        crontab => $args->{crontab},
    };

    bless $self, $class;

    return $self;
}

=head2 parse_job_metadata

Parse metadata from comment block above a cron entry

    my $metadata = $job->parse_job_metadata($block);

Returns hashref with metadata, or undef if not a plugin-managed job

=cut

sub parse_job_metadata {
    my ( $self, $block ) = @_;

    my %metadata;
    my @comments = $block->select( -type => 'comment' );

    for my $comment (@comments) {
        my $data = $comment->data();

        # Parse structured metadata (@key: value format)
        if ( $data =~ /^\s*#\s*\@(\w+(?:-\w+)*):\s*(.+)\s*$/ ) {
            my ( $key, $value ) = ( $1, $2 );
            $metadata{$key} = $value;
        }
    }

    # Only consider this job manageable if it has our ID marker
    return unless $metadata{'crontab-manager-id'};

    return \%metadata;
}

=head2 validate_job_fields

Validate the user-supplied free-text fields of a job (name, description,
schedule, command, environment) before they are written to the crontab.

The crontab is a line-oriented file, so a newline in any value written
into it -- a comment (name/description), an environment variable, the
schedule or the command -- would start a new, attacker-controlled crontab
line, running arbitrary commands regardless of the script allowlist. Every
field is therefore required to be single-line, environment variable names
must be plain identifiers, and (with C<check_env_policy>) environment
variables that change how the interpreter or dynamic loader behaves
(C<PERL5OPT>, C<LD_PRELOAD>, C<PATH>, ...) are refused: setting them would
let an approved script load arbitrary code.

    my $check = $job->validate_job_fields( $data, check_env_policy => 1 );

Only fields present in C<$data> are checked. Returns
C<< { valid => 1 } >> or C<< { valid => 0, error => '...' } >>.

=cut

my $UNSAFE_ENV_NAME = qr/^(?:
      LD_\w*|DYLD_\w*|GCONV_PATH|HOSTALIASES|LOCALDOMAIN|NLSPATH
    | PATH|IFS|SHELL|ENV|BASH_ENV|BASH_FUNC_\w*|PS4|PROMPT_COMMAND
    | PERL5?OPT|PERL5LIB|PERLLIB|PERL5DB|PERL5SHELL|PERL_\w+
    | PYTHON\w*|RUBY\w*|NODE_OPTIONS|NODE_PATH|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|CLASSPATH
)$/xi;

sub validate_job_fields {
    my ( $self, $data, %opts ) = @_;

    my %limits = ( name => 255, description => 2000, schedule => 255, command => 4096 );
    for my $field (qw(name description schedule command)) {
        next unless defined $data->{$field};
        my $value = $data->{$field};
        return { valid => 0, error => "Field '$field' must be a single line of text" }
            if ref $value || $value =~ /[\r\n\0]/;
        return { valid => 0, error => "Field '$field' is too long (maximum $limits{$field} characters)" }
            if length $value > $limits{$field};
    }

    if ( defined $data->{environment} ) {
        return { valid => 0, error => "Field 'environment' must be an object of NAME => value pairs" }
            unless ref $data->{environment} eq 'HASH';

        for my $name ( sort keys %{ $data->{environment} } ) {
            my $value = $data->{environment}{$name};
            return { valid => 0, error => "Invalid environment variable name '" . ( $name =~ s/[^\x20-\x7e]/?/gr ) . "' (letters, digits and underscores only, not starting with a digit)" }
                unless $name =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
            return { valid => 0, error => "Environment variable '$name' must have a single-line text value" }
                if !defined $value || ref $value || $value =~ /[\r\n\0]/;
            return { valid => 0, error => "Environment variable '$name' is not permitted: it changes how scripts are loaded or executed" }
                if $opts{check_env_policy} && $name =~ $UNSAFE_ENV_NAME;
        }
    }

    return { valid => 1 };
}

=head2 create_job_block

Create a crontab block with metadata for a job

    my $block = $job->create_job_block({
        id => $uuid,
        name => 'Job Name',
        description => 'Job description',
        schedule => '0 2 * * *',
        command => '/path/to/command',
        environment => { VAR1 => 'value1' }, # optional
        created => '2025-10-15 10:00:00',    # optional, defaults to now
        updated => '2025-10-15 10:00:00',    # optional, defaults to now
    });

=cut

sub create_job_block {
    my ( $self, $job_data ) = @_;

    # Last line of defence: whatever the caller validated, never write a
    # value containing a newline (or an invalid variable name) into the
    # crontab -- it would become a new crontab line.
    my $safe = $self->validate_job_fields($job_data);
    die "Refusing to write unsafe job data: $safe->{error}\n" unless $safe->{valid};

    my $now = strftime( "%Y-%m-%d %H:%M:%S", localtime );

    my $block = Config::Crontab::Block->new();
    my @lines;

    # Add metadata as comments
    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@crontab-manager-id: " . $job_data->{id} );

    push @lines,
      Config::Crontab::Comment->new( -data => "# \@name: " . $job_data->{name} )
      if $job_data->{name};

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@description: " . $job_data->{description} )
      if $job_data->{description};

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@created: " . ( $job_data->{created} || $now ) );

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@updated: " . ( $job_data->{updated} || $now ) );

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@managed-by: koha-crontab-plugin" );

    # Add environment variables if present
    if ( $job_data->{environment} && ref( $job_data->{environment} ) eq 'HASH' )
    {
        for my $key ( sort keys %{ $job_data->{environment} } ) {
            my $value = $job_data->{environment}->{$key};
            push @lines,
              Config::Crontab::Env->new(
                -name  => $key,
                -value => $value
              );
        }
    }

    # Add the cron entry with active flag based on enabled status
    my $event = Config::Crontab::Event->new(
        -datetime => $job_data->{schedule},
        -command  => $job_data->{command}
    );

    # Set active flag (1 = enabled/uncommented, 0 = disabled/commented)
    my $enabled = defined $job_data->{enabled} ? $job_data->{enabled} : 1;
    $event->active($enabled);

    push @lines, $event;

    $block->lines( \@lines );

    return $block;
}

=head2 get_plugin_managed_jobs

Get all jobs managed by this plugin from the crontab

Returns an arrayref of hashrefs containing job data

=cut

sub get_plugin_managed_jobs {
    my ($self) = @_;

    my $ct = $self->{crontab}->read();
    return [] unless $ct;

    my @jobs;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        next unless $metadata;
        next
          unless $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';

        # Extract the cron event from the block
        my @events = $block->select( -type => 'event' );
        next unless @events;

        my $event = $events[0];    # Take first event in block

        # Extract environment variables
        my %environment;
        for my $env ( $block->select( -type => 'env' ) ) {
            $environment{ $env->name } = $env->value;
        }

        my $job = {
            id          => $metadata->{'crontab-manager-id'},
            name        => $metadata->{name}        || '',
            description => $metadata->{description} || '',
            schedule    => $event->datetime,
            command     => $event->command,
            environment => \%environment,
            created     => $metadata->{created} || '',
            updated     => $metadata->{updated} || '',
            enabled     => $event->active
            ? 1
            : 0,    # Check active flag (1 = uncommented, 0 = commented)
        };

        push @jobs, $job;
    }

    return \@jobs;
}

=head2 get_all_crontab_entries

Get ALL entries from the crontab (plugin-managed + system)

Returns an arrayref of hashrefs with job data and a 'managed' flag

=cut

sub get_all_crontab_entries {
    my ($self) = @_;

    my $ct = $self->{crontab}->read();
    return [] unless $ct;

    my @entries;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        my $is_managed =
             $metadata
          && $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';

        # Extract ALL cron events from the block
        my @events = $block->select( -type => 'event' );
        next unless @events;

        # Get any comments for system entries (shared across all events in block)
        my @comments     = $block->select( -type => 'comment' );
        my @comment_text = map { $_->data } @comments;

        # Iterate through ALL events in the block
        for my $event (@events) {
            my $entry = {
                schedule => $event->datetime,
                command  => $event->command,
                managed  => $is_managed    ? 1 : 0,
                enabled  => $event->active ? 1 : 0,
                comments => \@comment_text,
            };

            # Add metadata if plugin-managed
            if ($is_managed) {
                $entry->{id}          = $metadata->{'crontab-manager-id'};
                $entry->{name}        = $metadata->{name}        || '';
                $entry->{description} = $metadata->{description} || '';
                $entry->{created}     = $metadata->{created}     || '';
                $entry->{updated}     = $metadata->{updated}     || '';
            }

            push @entries, $entry;
        }
    }

    return \@entries;
}

=head2 get_global_environment

Get global environment variables from the crontab

Returns a hashref of environment variable name => value pairs

=cut

sub get_global_environment {
    my ($self) = @_;

    my $ct = $self->{crontab}->read();
    return {} unless $ct;

    my %env;

    # Get global environment variables (not inside blocks)
    my @lines = $ct->select( -type => 'env' );
    for my $line (@lines) {
        next unless $line && ref($line);
        $env{ $line->name } = $line->value;
    }

    return \%env;
}

=head2 generate_job_id

Generate a unique UUID for a job

    my $uuid = $job->generate_job_id();

=cut

sub generate_job_id {
    my ($self) = @_;

    my $uuid;
    UUID::generate($uuid);

    my $uuid_string;
    UUID::unparse($uuid, $uuid_string);

    return $uuid_string;
}

=head2 find_job_block

Find a job block by ID

    my $block = $job->find_job_block($ct, $job_id);

Returns the block if found, undef otherwise

=cut

sub find_job_block {
    my ( $self, $ct, $job_id ) = @_;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        next unless $metadata;

        if ( $metadata->{'crontab-manager-id'} eq $job_id ) {
            return $block;
        }
    }

    return;
}

=head2 update_job_block

Update an existing job block with new data

    my $success = $job->update_job_block($block, {
        name => 'New Name',
        description => 'New description',
        schedule => '0 3 * * *',
        command => '/new/command',
    });

=cut

sub update_job_block {
    my ( $self, $block, $updates ) = @_;

    # Get existing metadata
    my $metadata = $self->parse_job_metadata($block);
    return 0 unless $metadata;

    my @existing_events  = $block->select( -type => 'event' );
    my $existing_enabled = @existing_events ? $existing_events[0]->active : 1;

    # Create updated block
    my $job_data = {
        id          => $metadata->{'crontab-manager-id'},
        name        => $updates->{name}        // $metadata->{name},
        description => $updates->{description} // $metadata->{description},
        schedule    => $updates->{schedule}    // '',
        command     => $updates->{command}     // '',
        environment => $updates->{environment},
        created     => $metadata->{created},
        updated     => strftime( "%Y-%m-%d %H:%M:%S", localtime ),
        enabled     => $updates->{enabled}     // $existing_enabled,
    };

    # If schedule/command not provided in updates, extract from existing block
    unless ( $job_data->{schedule} ) {
        my @events = $block->select( -type => 'event' );
        $job_data->{schedule} = $events[0]->datetime if @events;
    }

    unless ( $job_data->{command} ) {
        my @events = $block->select( -type => 'event' );
        $job_data->{command} = $events[0]->command if @events;
    }

    # Get existing environment if not provided
    unless ( $job_data->{environment} ) {
        my %env;
        for my $env_var ( $block->select( -type => 'env' ) ) {
            $env{ $env_var->name } = $env_var->value;
        }
        $job_data->{environment} = \%env if %env;
    }

    # Create new block
    my $new_block = $self->create_job_block($job_data);

    # Replace lines in the existing block
    $block->lines( [ $new_block->lines ] );

    return 1;
}

=head2 find_unmanaged_entry

Find an unmanaged (non-plugin) block/event pair matching the given
schedule, command, and comments exactly.

    my ( $block, $event ) = $job->find_unmanaged_entry( $ct, $schedule, $command, $comments );

$comments is an arrayref of raw comment line strings, in the same order
$block->select(-type => 'comment') returns them (i.e. as returned by
get_all_crontab_entries's 'comments' field for this entry).

Returns ($block, $event) if found, or an empty list if not. Never matches a
block that's already plugin-managed.

=cut

sub find_unmanaged_entry {
    my ( $self, $ct, $schedule, $command, $comments ) = @_;

    $comments ||= [];

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        my $is_managed =
             $metadata
          && $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';
        next if $is_managed;

        my @block_comments = map { $_->data } $block->select( -type => 'comment' );
        next unless _comments_match( \@block_comments, $comments );

        for my $event ( $block->select( -type => 'event' ) ) {
            next unless $event->datetime eq $schedule && $event->command eq $command;
            return ( $block, $event );
        }
    }

    return ();
}

=head2 entry_matches

Check whether a get_all_crontab_entries()-shaped entry matches the given
schedule, command, and comments exactly.

    my $matches = $job->entry_matches( $entry, $schedule, $command, $comments );

=cut

sub entry_matches {
    my ( $self, $entry, $schedule, $command, $comments ) = @_;

    return 0 unless $entry->{schedule} eq $schedule && $entry->{command} eq $command;
    return _comments_match( $entry->{comments} || [], $comments || [] );
}

=head2 extract_event_from_block

Remove a single event from a block, preserving any sibling events and the
block's own comments. If the event is the block's only event, the entire
block is removed from the crontab instead.

    $job->extract_event_from_block( $ct, $block, $event );

=cut

sub extract_event_from_block {
    my ( $self, $ct, $block, $event ) = @_;

    my @events = $block->select( -type => 'event' );

    if ( scalar(@events) <= 1 ) {
        $ct->remove($block);
        return;
    }

    my $target_addr      = refaddr($event);
    my @remaining_lines = grep { refaddr($_) != $target_addr } $block->lines;
    $block->lines( \@remaining_lines );

    return;
}

=head2 _comments_match

Compare two arrayrefs of raw comment line strings for exact equality
(same length, same strings, same order).

=cut

sub _comments_match {
    my ( $a, $b ) = @_;

    return 0 unless scalar(@$a) == scalar(@$b);
    for my $i ( 0 .. $#$a ) {
        return 0 unless $a->[$i] eq $b->[$i];
    }
    return 1;
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
