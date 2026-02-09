package Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job;

# Job management operations

use Modern::Perl;
use POSIX qw(strftime);
use UUID;
use Config::Crontab;

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
    return undef unless $metadata{'crontab-manager-id'};

    return \%metadata;
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

    return undef;
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
    $block->lines( $new_block->lines );

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
