package Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script;

# Script discovery and parsing operations

use Modern::Perl;
use File::Find;
use File::Basename;
use Pod::Usage;
use Try::Tiny;
use C4::Context;
use YAML::XS qw(Load);

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script - Script discovery and parsing

=head1 SYNOPSIS

    my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new({
        crontab => $crontab_instance,
    });

    my $scripts = $script->get_available_scripts();
    my $doc = $script->parse_script_documentation('/path/to/script.pl');

=head1 DESCRIPTION

This module handles script discovery from KOHA_CRON_PATH and parsing of
POD documentation and GetOptions specifications.

=head1 METHODS

=cut

=head2 new

Constructor

    my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new({
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

=head2 get_available_scripts

Get list of available scripts from KOHA_CRON_PATH

    my $scripts = $script->get_available_scripts();
    my $scripts = $script->get_available_scripts({ bypass_filter => 1 });

Returns arrayref of hashrefs with script metadata

=cut

sub get_available_scripts {
    my ($self, $options) = @_;
    $options ||= {};

    # Get KOHA_CRON_PATH from crontab environment
    my $ct = $self->{crontab}->read();
    return [] unless $ct;

    my $cron_path;
    my @env_lines = $ct->select( -type => 'env' );
    for my $env (@env_lines) {
        if ( $env->name eq 'KOHA_CRON_PATH' ) {
            $cron_path = $env->value;
            last;
        }
    }

    return [] unless $cron_path && -d $cron_path;

    my @scripts;
    find(
        sub {
            my $abs_path = $File::Find::name;
            my $rel_path = $abs_path;
            $rel_path =~ s/^\Q$cron_path\E//;
            $rel_path = '$KOHA_CRON_PATH' . $rel_path;

            # Only include .pl and .sh files
            if ( -f $abs_path
                && ( $abs_path =~ /\.pl$/ || $abs_path =~ /\.sh$/ ) )
            {
                my $type     = $abs_path =~ /\.pl$/ ? 'perl' : 'shell';
                my $basename = basename($abs_path);

                # Get brief description from POD NAME section for perl scripts
                my $description = '';
                if ( $type eq 'perl' ) {
                    my $doc = $self->parse_script_documentation($abs_path);
                    $description = $doc->{name_brief} || '';
                }

                push @scripts,
                  {
                    name          => $basename,
                    path          => $abs_path,
                    relative_path => $rel_path,
                    type          => $type,
                    description   => $description,
                  };
            }
        },
        $cron_path
    );

    # Sort by name
    @scripts = sort { $a->{name} cmp $b->{name} } @scripts;

    my $effective_policy = $self->_effective_policy();

    # Filter by script policy if configured (unless bypassed)
    unless ( $options->{bypass_filter} ) {
        if (@$effective_policy) {
            my @filtered_scripts;
            for my $script (@scripts) {
                my $rel_path = $script->{relative_path};
                $rel_path =~ s/^\$KOHA_CRON_PATH\/?//;

                for my $entry (@$effective_policy) {
                    my $pattern = $entry->{path};

                    # Pattern can be exact match or prefix match (e.g., "batch/" matches all in batch dir)
                    if (   $rel_path eq $pattern
                        || index( $rel_path, $pattern ) == 0
                        || $script->{name} eq $pattern )
                    {
                        push @filtered_scripts, $script;
                        last;
                    }
                }
            }
            @scripts = @filtered_scripts;
        }
    }

    # Attach policy to scripts that matched an *exact* effective policy entry
    # (never a directory-prefix entry)
    for my $script (@scripts) {
        my $rel_path = $script->{relative_path};
        $rel_path =~ s/^\$KOHA_CRON_PATH\/?//;

        my ($exact_entry) = grep { $_->{path} eq $rel_path || $_->{path} eq $script->{name} } @$effective_policy;
        if ($exact_entry) {
            $script->{policy} = {
                non_repeatable => $exact_entry->{non_repeatable} ? 1 : 0,
                allowed_hours  => $exact_entry->{allowed_hours}  || '',
            };
        }
    }

    return \@scripts;
}

=head2 parse_script_documentation

Parse POD documentation from a Perl script using Pod::Usage

    my $doc = $script->parse_script_documentation('/path/to/script.pl');

Returns hashref with: name_brief, usage_text

=cut

sub parse_script_documentation {
    my ( $self, $script_path ) = @_;

    return {} unless -f $script_path;

    my %doc = (
        name_brief => '',
        usage_text => '',
    );

    # Extract brief description from DESCRIPTION section
    try {
        my $name_output = '';
        open my $name_fh, '>', \$name_output;
        pod2usage(
            -input    => $script_path,
            -output   => $name_fh,
            -sections => 'DESCRIPTION',
            -verbose  => 99,
            -exitval  => 'NOEXIT'
        );
        close $name_fh;

        $doc{name_brief} = $name_output;
    }
    catch {
        # If DESCRIPTION section fails, that's okay
    };

    # Extract full usage documentation (verbose level 1)
    try {
        my $usage_output = '';
        open my $usage_fh, '>', \$usage_output;
        pod2usage(
            -input   => $script_path,
            -output  => $usage_fh,
            -verbose => 1,
            -exitval => 'NOEXIT'
        );
        close $usage_fh;

        $doc{usage_text} = $usage_output;
    }
    catch {
        warn "Failed to extract POD from $script_path: $_";
        $doc{usage_text} = "No documentation available.\n";
    };

    return \%doc;
}

=head2 parse_script_options

Parse command-line options from a Perl script's GetOptions call and detect
positional @ARGV usage.

    my $result = $script->parse_script_options('/path/to/script.pl');

Returns hashref with:
  options => arrayref of option hashrefs (name, short_name, type, required,
             negatable, incremental, repeatable, dest_type)
  positional_args => arrayref of detected positional argument patterns

For backwards compatibility, when called in list context on code that
previously expected an arrayref, the options arrayref is returned.

=cut

sub parse_script_options {
    my ( $self, $script_path ) = @_;

    return { options => [], positional_args => [] } unless -f $script_path;

    open my $fh, '<', $script_path or return { options => [], positional_args => [] };
    my @lines = <$fh>;
    close $fh;

    my $content = join( '', @lines );

    my @options        = $self->_parse_getoptions_block($content);
    my @positional_args = $self->_detect_argv_usage( $content, \@lines );

    return {
        options         => \@options,
        positional_args => \@positional_args,
    };
}

=head2 _parse_getoptions_block

Extract and parse GetOptions specifications from script content.
Handles both hash-style and list-style GetOptions calls, single and
double-quoted specs, and the full Getopt::Long spec syntax including
negatable (!), incremental (+), array (@) and hash (%) destination types.

=cut

sub _parse_getoptions_block {
    my ( $self, $content ) = @_;

    # Extract GetOptions block(s)
    my $getoptions_block = '';
    my $in_getoptions    = 0;

    for my $line ( split /\n/, $content ) {
        if ( $line =~ /GetOptions\s*\(/i ) {
            $in_getoptions = 1;
        }

        if ($in_getoptions) {
            $getoptions_block .= $line . "\n";
            if (   $line =~ /\)\s*;/
                || $line =~ /\)\s*\|\|\s*/
                || $line =~ /\)\s+or\s+/i )
            {
                last;
            }
        }
    }

    return () unless $getoptions_block;

    # Extract all single or double-quoted strings from the block
    my @specs;
    while ( $getoptions_block =~ /(?:'([^']+)'|"([^"]+)")/g ) {
        push @specs, ( $1 // $2 );
    }

    my @options;
    for my $spec (@specs) {
        my $parsed = $self->_parse_option_spec($spec);
        push @options, $parsed if $parsed;
    }

    return @options;
}

=head2 _parse_option_spec

Parse a single Getopt::Long option specification string.

Supported spec format:
  name[|alias]...[!+][=:][type][repeat]

Where:
  name|alias  - option names separated by |
  !           - negatable (allows --no-name)
  +           - incremental (each use increments value)
  = or :      - value required (=) or optional (:)
  type        - s (string), i (integer), o (extended integer), f (float)
  repeat      - @ (array destination) or % (hash destination)

=cut

sub _parse_option_spec {
    my ( $self, $spec ) = @_;

    # Full Getopt::Long spec regex
    # Group 1: name and aliases (e.g. "verbose|v|V" or "help|h|?")
    # Group 2: negatable (!) or incremental (+)
    # Group 3: = or : (required/optional value)
    # Group 4: type code (s, i, o, f) or default number or +
    # Group 5: destination type (@ or %)
    return undef
      unless $spec =~ /^([\w][\w-]*(?:\|[\w?][\w-]*)*)([!+])?(?:([=:])([siof]|\d+|\+))?([%\@])?$/;

    my $names_str = $1;
    my $modifier  = $2 || '';
    my $req_char  = $3 || '';
    my $type_code = $4 || '';
    my $dest_char = $5 || '';

    # Split names into primary + aliases
    my @names      = split /\|/, $names_str;
    my $name       = $names[0];
    my $short_name = '';

    # Find the first single-character alias as short_name
    for my $n ( @names[ 1 .. $#names ] ) {
        if ( length($n) == 1 ) {
            $short_name = $n;
            last;
        }
    }

    my $type        = 'boolean';
    my $required    = 0;
    my $negatable   = 0;
    my $incremental = 0;
    my $repeatable  = 0;
    my $dest_type   = 'scalar';

    # Handle negatable
    if ( $modifier eq '!' ) {
        $negatable = 1;
        $type      = 'boolean';
    }

    # Handle incremental
    elsif ( $modifier eq '+' ) {
        $incremental = 1;
        $type        = 'incremental';
    }

    # Handle value types
    if ($req_char) {
        $required = ( $req_char eq '=' ) ? 1 : 0;

        if    ( $type_code eq 's' ) { $type = 'string'; }
        elsif ( $type_code eq 'i' ) { $type = 'integer'; }
        elsif ( $type_code eq 'o' ) { $type = 'integer'; }
        elsif ( $type_code eq 'f' ) { $type = 'float'; }
    }

    # Handle destination type
    if ( $dest_char eq '@' ) {
        $dest_type  = 'array';
        $repeatable = 1;
    }
    elsif ( $dest_char eq '%' ) {
        $dest_type  = 'hash';
        $repeatable = 1;
    }

    return {
        name        => $name,
        short_name  => $short_name,
        type        => $type,
        required    => $required,
        negatable   => $negatable,
        incremental => $incremental,
        repeatable  => $repeatable,
        dest_type   => $dest_type,
    };
}

=head2 _detect_argv_usage

Detect direct @ARGV usage in the script that indicates positional arguments
not declared in GetOptions.

=cut

sub _detect_argv_usage {
    my ( $self, $content, $lines ) = @_;

    my @positional_args;

    # Track the highest ARGV index accessed
    my $max_index = -1;
    while ( $content =~ /\$ARGV\[(\d+)\]/g ) {
        my $idx = $1;
        $max_index = $idx if $idx > $max_index;
    }

    if ( $max_index >= 0 ) {
        for my $i ( 0 .. $max_index ) {
            push @positional_args, {
                position => $i,
                source   => "\$ARGV[$i]",
                label    => _argv_context_label( $content, "\$ARGV[$i]" ),
            };
        }
    }

    # Detect shift @ARGV / shift(@ARGV) patterns
    my $shift_count = 0;
    while ( $content =~ /shift\s*[\(]?\s*\@ARGV\s*[\)]?/g ) {
        $shift_count++;
    }

    # Only add shift-based positional args if we didn't already find index-based ones
    if ( $shift_count > 0 && $max_index < 0 ) {
        for my $i ( 0 .. $shift_count - 1 ) {
            push @positional_args, {
                position => $i,
                source   => 'shift @ARGV',
                label    => _shift_context_label( $lines, $i ),
            };
        }
    }

    # Detect foreach/for @ARGV loops (variable-length positional args)
    if ( $content =~ /for(?:each)?\s+(?:my\s+\$\w+\s+)?\(\s*\@ARGV\s*\)/
        || $content =~ /for(?:each)?\s+(?:my\s+)?\$\w+\s+\(\s*\@ARGV\s*\)/ )
    {
        unless (@positional_args) {
            push @positional_args, {
                position => 0,
                source   => '@ARGV loop',
                label    => 'Positional argument(s)',
                variadic => 1,
            };
        }
    }

    # Detect bare @ARGV usage in assignments (e.g., my @files = @ARGV)
    if ( $content =~ /[\@\$]\w+\s*=\s*\@ARGV\b/ && !@positional_args ) {
        push @positional_args, {
            position => 0,
            source   => '@ARGV assignment',
            label    => 'Positional argument(s)',
            variadic => 1,
        };
    }

    return @positional_args;
}

sub _argv_context_label {
    my ( $content, $argv_expr ) = @_;

    # Try to find the variable name assigned from $ARGV[N]
    my $escaped = quotemeta($argv_expr);
    if ( $content =~ /(?:my\s+)?\$(\w+)\s*=\s*$escaped/ ) {
        my $var_name = $1;
        $var_name =~ s/_/ /g;
        return ucfirst($var_name);
    }

    return 'Positional argument';
}

sub _shift_context_label {
    my ( $lines, $occurrence_idx ) = @_;

    my $count = 0;
    for my $line (@$lines) {
        if ( $line =~ /shift\s*[\(]?\s*\@ARGV\s*[\)]?/ ) {
            if ( $count == $occurrence_idx ) {
                # Try to extract variable name from same line
                if ( $line =~ /(?:my\s+)?\$(\w+)\s*=\s*shift/ ) {
                    my $var_name = $1;
                    $var_name =~ s/_/ /g;
                    return ucfirst($var_name);
                }
                last;
            }
            $count++;
        }
    }

    return 'Positional argument';
}

=head2 validate_command

Validate that a command uses an approved script from the available scripts list

    my $result = $script->validate_command($command);

Returns hashref with: valid => 1/0, error => string (if invalid), script => matched script hashref (if valid)

=cut

sub validate_command {
    my ( $self, $command ) = @_;

    return { valid => 0, error => "Command is required" } unless $command;

    # Extract the script path (first token before any parameters)
    my @parts = split /\s+/, $command;
    my $script_path = $parts[0];

    return { valid => 0, error => "Empty command" } unless $script_path;

    # Get list of available scripts
    my $available_scripts = $self->get_available_scripts();

    # Try to match against available scripts
    my $matched_script;
    for my $script (@$available_scripts) {
        if ( $script->{relative_path} eq $script_path ) {
            $matched_script = $script;
            last;
        }
    }

    unless ($matched_script) {
        return {
            valid => 0,
            error =>
"Command must use a script from the approved list. Use the script browser to select a valid script. Provided: $script_path"
        };
    }

    # Command is valid
    return { valid => 1, script => $matched_script, policy => $matched_script->{policy} };
}

=head2 _expand_cron_field

Expand a single cron schedule field (e.g. the hour field) into the concrete
set of integer values it matches, within [$min, $max]. Supports '*',
comma-separated lists, ranges ('a-b'), and step syntax ('*/n', 'a-b/n').
Unrecognised tokens are silently skipped.

    my $values = $script->_expand_cron_field( '1-10/2', 0, 23 );

Returns a hashref of { integer => 1 }.

=cut

sub _expand_cron_field {
    my ( $self, $field, $min, $max ) = @_;

    my %values;
    return \%values unless defined $field && length $field;

    for my $part ( split /,/, $field ) {
        my ( $range_part, $step ) = split m{/}, $part, 2;
        $step = ( defined $step && $step =~ /^\d+$/ && $step > 0 ) ? $step : 1;

        my ( $range_min, $range_max );
        if ( $range_part eq '*' ) {
            ( $range_min, $range_max ) = ( $min, $max );
        }
        elsif ( $range_part =~ /^(\d+)-(\d+)$/ ) {
            ( $range_min, $range_max ) = ( $1, $2 );
        }
        elsif ( $range_part =~ /^(\d+)$/ ) {
            ( $range_min, $range_max ) = ( $1, $1 );
        }
        else {
            next;
        }

        for ( my $v = $range_min; $v <= $range_max; $v += $step ) {
            $values{$v} = 1 if $v >= $min && $v <= $max;
        }
    }

    return \%values;
}

=head2 _expand_cron_hour_field

Convenience wrapper around C<_expand_cron_field> fixed to the valid hour
range (0-23).

    my $hours = $script->_expand_cron_hour_field('*/4');

=cut

sub _expand_cron_hour_field {
    my ( $self, $field ) = @_;

    return $self->_expand_cron_field( $field, 0, 23 );
}

=head2 _expand_allowed_hours

Expand an C<allowed_hours> policy spec (comma-separated single hours and/or
inclusive ranges, e.g. '1-5' or '0,12,22-2') into the concrete set of hours
0-23 it permits. A range where the second number is smaller than the first
wraps past midnight (e.g. '22-2' => 22,23,0,1,2).

    my $hours = $script->_expand_allowed_hours('22-2');

Returns a hashref of { integer => 1 }.

=cut

sub _expand_allowed_hours {
    my ( $self, $spec ) = @_;

    my %values;
    return \%values unless defined $spec && $spec =~ /\S/;

    for my $part ( split /,/, $spec ) {
        $part =~ s/^\s+|\s+$//g;

        if ( $part =~ /^(\d+)-(\d+)$/ ) {
            my ( $start, $end ) = ( $1, $2 );
            if ( $start <= $end ) {
                $values{$_} = 1 for $start .. $end;
            }
            else {
                $values{$_} = 1 for ( $start .. 23 );
                $values{$_} = 1 for ( 0 .. $end );
            }
        }
        elsif ( $part =~ /^(\d+)$/ ) {
            $values{$1} = 1;
        }
    }

    return \%values;
}

=head2 _load_policy_source

Parse a YAML script-policy document into a normalized list of policy
entries. Used for both the server-file tier and the library (DB) tier —
both use the same schema.

    my $entries = $script->_load_policy_source($yaml_text);

Returns an arrayref of hashrefs: { path, non_repeatable, allowed_hours }.
Returns an empty arrayref for undef/blank input, or if the document has no
'scripts' array.

=cut

sub _load_policy_source {
    my ( $self, $yaml_text ) = @_;

    return [] unless defined $yaml_text && $yaml_text =~ /\S/;

    my $data = eval { Load($yaml_text) };
    return []
      unless $data
      && ref($data) eq 'HASH'
      && ref( $data->{scripts} ) eq 'ARRAY';

    my @entries;
    for my $raw ( @{ $data->{scripts} } ) {
        next unless ref($raw) eq 'HASH' && defined $raw->{path} && length $raw->{path};

        push @entries,
          {
            path           => $raw->{path},
            non_repeatable => $raw->{non_repeatable} ? 1 : 0,
            allowed_hours  => $raw->{allowed_hours} || '',
          };
    }

    return \@entries;
}

=head2 _intersect_allowed_hours

Combine two allowed_hours specs into the spec of their intersection
(rendered back out as a sorted comma list of hours, not collapsed into
ranges — it only needs to round-trip through C<_expand_allowed_hours>).
An unset spec (empty string) is treated as "no restriction from this tier".

    my $spec = $script->_intersect_allowed_hours( '1-10', '2-4' );  # '2,3,4'

=cut

sub _intersect_allowed_hours {
    my ( $self, $server_spec, $library_spec ) = @_;

    my $server_set  = ( $server_spec  && $server_spec  =~ /\S/ ) ? $self->_expand_allowed_hours($server_spec)  : undef;
    my $library_set = ( $library_spec && $library_spec =~ /\S/ ) ? $self->_expand_allowed_hours($library_spec) : undef;

    return '' unless $server_set || $library_set;
    return join( ',', sort { $a <=> $b } keys %$library_set ) unless $server_set;
    return join( ',', sort { $a <=> $b } keys %$server_set )  unless $library_set;

    my %intersection = map { $_ => 1 } grep { $server_set->{$_} } keys %$library_set;
    return join( ',', sort { $a <=> $b } keys %intersection );
}

=head2 _merge_policy_tiers

Merge server-tier (ceiling) and library-tier policy entries into a single
effective list. If the server tier is empty, the library tier applies
unmodified. Otherwise, only paths present in BOTH tiers survive, and each
survivor's non_repeatable is the OR of both tiers (library can only turn it
on) and allowed_hours is the intersection of both tiers (library can only
narrow it).

    my $effective = $script->_merge_policy_tiers( $server_entries, $library_entries );

Returns an arrayref of hashrefs: { path, non_repeatable, allowed_hours }.

=cut

sub _merge_policy_tiers {
    my ( $self, $server_entries, $library_entries ) = @_;

    $server_entries  ||= [];
    $library_entries ||= [];

    return $library_entries unless @$server_entries;

    my %server_by_path = map { $_->{path} => $_ } @$server_entries;

    my @effective;
    for my $library (@$library_entries) {
        my $server = $server_by_path{ $library->{path} };
        next unless $server;    # ceiling excludes this path entirely

        push @effective,
          {
            path           => $library->{path},
            non_repeatable => ( $server->{non_repeatable} || $library->{non_repeatable} ) ? 1 : 0,
            allowed_hours  => $self->_intersect_allowed_hours( $server->{allowed_hours}, $library->{allowed_hours} ),
          };
    }

    return \@effective;
}

=head2 get_server_policy

Read and parse the server-tier script policy file, if
C<koha_plugin_crontab_script_policy> is configured in koha-conf.xml and
points to a readable file.

    my $entries = $script->get_server_policy();

Returns an arrayref (possibly empty) of hashrefs: { path, non_repeatable,
allowed_hours }.

=cut

sub get_server_policy {
    my ($self) = @_;

    my $file_path = C4::Context->config('koha_plugin_crontab_script_policy');
    return [] unless $file_path && -f $file_path;

    open my $fh, '<', $file_path or return [];
    my $yaml_text = do { local $/; <$fh> };
    close $fh;

    return $self->_load_policy_source($yaml_text);
}

=head2 get_library_policy

Read and parse the library-tier (DB, staff-editable) script policy
setting.

    my $entries = $script->get_library_policy();

Returns an arrayref (possibly empty) of hashrefs: { path, non_repeatable,
allowed_hours }.

=cut

sub get_library_policy {
    my ($self) = @_;

    my $plugin = $self->{crontab}->{plugin};
    return [] unless $plugin;

    return $self->_load_policy_source( $plugin->retrieve_data('script_policy') );
}

=head2 _effective_policy

The merged, effective script policy — server tier as ceiling/floor, library
tier narrowing within it. See C<_merge_policy_tiers>.

    my $entries = $script->_effective_policy();

=cut

sub _effective_policy {
    my ($self) = @_;

    return $self->_merge_policy_tiers( $self->get_server_policy(), $self->get_library_policy() );
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
