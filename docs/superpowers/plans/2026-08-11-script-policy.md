# Script Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a server administrator (via a koha-conf.xml-referenced YAML file) and a library administrator (via the existing staff configure page) jointly constrain which cron scripts can be scheduled more than once (`non_repeatable`) or outside certain hours (`allowed_hours`), enforced server-side on job add/update.

**Architecture:** A shared YAML schema (`{ scripts: [{ path, non_repeatable, allowed_hours }, ...] }`) is read from two tiers — an optional server file (new `koha_plugin_crontab_script_policy` koha-conf.xml entry) and the existing `script_allowlist` plugin setting, renamed to `script_policy` and re-stored as YAML instead of plain lines. `Cron::Script.pm` merges the two tiers (server is a ceiling/floor, library can only narrow) into an effective policy, attaches it to script metadata, and exposes pure check functions the REST controllers call at add/update time. Already-saved jobs are never retroactively invalidated — `Jobs::list` just flags current violations for the UI.

**Tech Stack:** Perl (Modern::Perl), YAML::XS (already a hard Koha core dependency — no new dependency introduced), JSON (already used in this plugin), Mojolicious REST controllers, vanilla JS/jQuery + Bootstrap 5 templates (no build step), Test::More run via `koha-prove` inside a KTD instance.

## Global Constraints

- Zero new external CPAN dependencies — this repo's README/CHANGELOG explicitly call out "zero external dependencies" as a deliberate property; `YAML::XS` is already required by Koha core (`cpanfile`: `requires 'YAML::XS', '0.76'`), so it's safe to use directly.
- `policy_violations`/enforcement must never mutate or block an already-saved job — only add/update requests are validated (see spec's "Grandfathering" decision).
- `non_repeatable`/`allowed_hours` are only ever meaningful on an **exact** script path entry, never a directory-prefix allow-pattern (spec's "Policy scope" decision).
- The server-file tier is a **ceiling**: if it lists any scripts at all, the library tier may only select a subset of them and may only make policy *stricter*, never looser (spec's "Policy merge" decision).
- Duplicate (`non_repeatable`) detection scans **all** crontab entries, managed and system (spec's "Duplicate scope" decision).
- All tests in this repo run via `prove` against a live Koha/KTD environment (there is no lighter-weight unit-test harness) — per `CLAUDE.md`, use the `koha-prove` skill or `prove t/<file>.t` inside a running KTD container with `KOHA_PLUGIN_DIR` set. A KTD instance must be running (`kd up`) before any "Run tests" step below can execute.
- Full spec: `docs/superpowers/specs/2026-08-11-script-policy-design.md`.

---

### Task 1: Cron hour-field and allowed-hours expansion helpers

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm` (add methods after `validate_command`, before the final `1;`)
- Test: `t/01-cron-hour-expansion.t` (new)

**Interfaces:**
- Produces: `$script->_expand_cron_field($field, $min, $max)` → hashref `{ int => 1, ... }` of matched values within `[$min, $max]`. `$script->_expand_cron_hour_field($field)` → same, fixed to `(0, 23)`. `$script->_expand_allowed_hours($spec)` → hashref `{ int => 1, ... }` of hours 0-23 matched by an `allowed_hours` policy spec (comma list of single hours and/or `H1-H2` ranges, wrapping past midnight when `H1 > H2`).
- Consumes: nothing (pure functions, no DB/file access).

- [ ] **Step 1: Write the failing test**

Create `t/01-cron-hour-expansion.t`:

```perl
use Modern::Perl;
use Test::More tests => 10;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_cron_field( '*', 0, 23 ) } ],
    [ 0 .. 23 ],
    '* expands to the full range'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_cron_field( '1,3,5', 0, 23 ) } ],
    [ 1, 3, 5 ],
    'comma list expands to exact values'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_cron_field( '1-5', 0, 23 ) } ],
    [ 1, 2, 3, 4, 5 ],
    'simple range expands correctly'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_cron_field( '*/6', 0, 23 ) } ],
    [ 0, 6, 12, 18 ],
    'step wildcard expands correctly'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_cron_field( '1-10/2', 0, 23 ) } ],
    [ 1, 3, 5, 7, 9 ],
    'range with step expands correctly'
);

is_deeply(
    $script->_expand_cron_hour_field('9'),
    { 9 => 1 },
    '_expand_cron_hour_field delegates to _expand_cron_field with 0-23 bounds'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_allowed_hours('1-5') } ],
    [ 1, 2, 3, 4, 5 ],
    'allowed_hours simple range'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_allowed_hours('22-2') } ],
    [ 0, 1, 2, 22, 23 ],
    'allowed_hours wraparound range'
);

is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_allowed_hours('0,12,20-22') } ],
    [ 0, 12, 20, 21, 22 ],
    'allowed_hours mixed list and range'
);
```

- [ ] **Step 2: Run test to verify it fails**

Run (inside a KTD instance, via the `koha-prove` skill or): `KOHA_PLUGIN_DIR=/path/to/koha-plugin-crontab prove -v t/01-cron-hour-expansion.t`
Expected: FAIL — `_expand_cron_field` etc. not yet defined (`Can't locate object method`).

- [ ] **Step 3: Implement the helpers**

In `Cron/Script.pm`, add after the `validate_command` sub (before the trailing `1;`):

```perl
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `KOHA_PLUGIN_DIR=/path/to/koha-plugin-crontab prove -v t/01-cron-hour-expansion.t`
Expected: PASS (10/10).

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm t/01-cron-hour-expansion.t
git commit -m "feat: add cron hour-field and allowed-hours expansion helpers"
```

---

### Task 2: YAML script-policy parsing and two-tier merge

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm` (add `use` statements, new methods, rewrite the allowlist-filter block inside `get_available_scripts`, extend `validate_command`)
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json` (`/scripts` and `/scripts/details` response schemas)
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Scripts.pm` (`get`, to surface `policy`)
- Test: `t/02-script-policy-parsing.t` (new)

**Interfaces:**
- Consumes: `$self->_expand_allowed_hours($spec)` from Task 1.
- Produces: `$script->_load_policy_source($yaml_text)` → arrayref of `{ path, non_repeatable, allowed_hours }`. `$script->_merge_policy_tiers($server_entries, $library_entries)` → arrayref of the same shape (effective policy). `$script->get_server_policy()` → arrayref (server-file tier only, raw). `$script->get_library_policy()` → arrayref (DB `script_policy` tier only, raw). `$script->_effective_policy()` → arrayref (merged). `get_available_scripts()` results now carry `policy => { non_repeatable, allowed_hours }` when a script matched an exact effective-policy entry. `validate_command()`'s return hashref now also carries `policy` (same shape, possibly `undef`).

- [ ] **Step 1: Write the failing test**

Create `t/02-script-policy-parsing.t`:

```perl
use Modern::Perl;
use Test::More tests => 11;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );

is_deeply( $script->_load_policy_source(undef), [], 'undef yaml yields empty list' );
is_deeply( $script->_load_policy_source('   '), [], 'blank yaml yields empty list' );

my $yaml = <<'YAML';
scripts:
  - path: batch/report.pl
    non_repeatable: true
    allowed_hours: "1-5"
  - path: finegen.pl
    non_repeatable: true
  - path: batch/
YAML

my $parsed = $script->_load_policy_source($yaml);
is( scalar @$parsed, 3, 'parses three entries' );

my ($report) = grep { $_->{path} eq 'batch/report.pl' } @$parsed;
is( $report->{non_repeatable}, 1, 'non_repeatable parsed as true' );
is( $report->{allowed_hours}, '1-5', 'allowed_hours parsed' );

my ($prefix) = grep { $_->{path} eq 'batch/' } @$parsed;
is( $prefix->{non_repeatable}, 0, 'entry with no non_repeatable key defaults to false' );

my $server  = [ { path => 'finegen.pl', non_repeatable => 1, allowed_hours => '1-10' } ];
my $library = [
    { path => 'finegen.pl',  non_repeatable => 0, allowed_hours => '2-4' },
    { path => 'unlisted.pl', non_repeatable => 1, allowed_hours => '' },
];

my $effective = $script->_merge_policy_tiers( $server, $library );
is( scalar @$effective, 1, 'server ceiling drops paths it does not list' );

my ($finegen) = @$effective;
is( $finegen->{non_repeatable}, 1, 'effective non_repeatable is OR of both tiers' );
is_deeply(
    [ sort { $a <=> $b } keys %{ $script->_expand_allowed_hours( $finegen->{allowed_hours} ) } ],
    [ 2, 3, 4 ],
    'effective allowed_hours is the intersection of both tiers'
);

my $no_ceiling = $script->_merge_policy_tiers( [], $library );
is( scalar @$no_ceiling, 2, 'an empty server tier leaves the library tier untouched' );
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -v t/02-script-policy-parsing.t`
Expected: FAIL — `_load_policy_source` etc. not yet defined.

- [ ] **Step 3: Add `use` statements**

At the top of `Cron/Script.pm`, change:

```perl
use Modern::Perl;
use File::Find;
use File::Basename;
use Pod::Usage;
use Try::Tiny;
```

to:

```perl
use Modern::Perl;
use File::Find;
use File::Basename;
use Pod::Usage;
use Try::Tiny;
use C4::Context;
use YAML::XS qw(Load);
```

- [ ] **Step 4: Implement parsing, merge, and tier-reader methods**

Add after the Task 1 helpers (before the trailing `1;`):

```perl
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `prove -v t/02-script-policy-parsing.t`
Expected: PASS (11/11).

- [ ] **Step 6: Wire the effective policy into `get_available_scripts` and `validate_command`**

In `get_available_scripts`, replace the entire allowlist-filtering block:

```perl
    # Filter by script allowlist if configured (unless bypassed)
    unless ($options->{bypass_filter}) {
        my $plugin = $self->{crontab}->{plugin};
        if ($plugin) {
            my $script_allowlist = $plugin->retrieve_data('script_allowlist');
            if ($script_allowlist && $script_allowlist =~ /\S/) {
                # Parse allowlist (one entry per line, trim whitespace)
                my @allowed_patterns = grep { /\S/ } split(/\r?\n/, $script_allowlist);

                if (@allowed_patterns) {
                    my @filtered_scripts;
                    for my $script (@scripts) {
                        my $rel_path = $script->{relative_path};
                        # Remove $KOHA_CRON_PATH prefix for matching
                        $rel_path =~ s/^\$KOHA_CRON_PATH\/?//;

                        for my $pattern (@allowed_patterns) {
                            $pattern =~ s/^\s+|\s+$//g; # Trim whitespace

                            # Check if script matches pattern
                            # Pattern can be exact match or prefix match (e.g., "batch/" matches all in batch dir)
                            if ($rel_path eq $pattern ||
                                index($rel_path, $pattern) == 0 ||
                                $script->{name} eq $pattern) {
                                push @filtered_scripts, $script;
                                last; # Found a match, no need to check other patterns
                            }
                        }
                    }
                    @scripts = @filtered_scripts;
                }
            }
        }
    }

    return \@scripts;
}
```

with:

```perl
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
```

In `validate_command`, change:

```perl
    # Command is valid
    return { valid => 1, script => $matched_script };
```

to:

```perl
    # Command is valid
    return { valid => 1, script => $matched_script, policy => $matched_script->{policy} };
```

- [ ] **Step 7: Surface `policy` from the script-details REST endpoint**

In `REST/V1/Cron/Scripts.pm`, `get` currently renders:

```perl
        return $c->render(
            status  => 200,
            openapi => {
                name            => $script->{name},
                path            => $script->{relative_path},
                type            => $script->{type},
                description     => $doc->{name_brief} || '',
                usage_text      => $doc->{usage_text} || '',
                options         => $parsed->{options},
                positional_args => $parsed->{positional_args},
            }
        );
```

Add a `policy` key:

```perl
        return $c->render(
            status  => 200,
            openapi => {
                name            => $script->{name},
                path            => $script->{relative_path},
                type            => $script->{type},
                description     => $doc->{name_brief} || '',
                usage_text      => $doc->{usage_text} || '',
                options         => $parsed->{options},
                positional_args => $parsed->{positional_args},
                policy          => $script->{policy},
            }
        );
```

- [ ] **Step 8: Update the openapi schema**

In `api/openapi.json`, under `/scripts` → `get` → `responses` → `200` → `schema` → `properties` → `scripts` → `items` → `properties`, add a `policy` property alongside the existing `name`/`path`/`relative_path`/`type`/`description`:

```json
                  "policy": {
                    "type": "object",
                    "description": "Script scheduling policy, present only for scripts with an exact policy match",
                    "properties": {
                      "non_repeatable": {
                        "type": "boolean",
                        "description": "Whether only one crontab entry may reference this script at a time"
                      },
                      "allowed_hours": {
                        "type": "string",
                        "description": "Comma-separated hours/ranges (0-23) this script may be scheduled within"
                      }
                    }
                  }
```

Under `/scripts/details` → `get` → `responses` → `200` → `schema` → `properties`, add the same `policy` property alongside the existing top-level `name`/`path`/`type`/`description`/`usage_text`/`options`/`positional_args`.

- [ ] **Step 9: Run the full test suite so far**

Run: `prove -v t/01-cron-hour-expansion.t t/02-script-policy-parsing.t`
Expected: PASS (10/10, 11/11).

- [ ] **Step 10: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm \
        Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Scripts.pm \
        Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json \
        t/02-script-policy-parsing.t
git commit -m "feat: parse and merge two-tier YAML script policy"
```

---

### Task 3: Non-repeatable and allowed-hours enforcement checks

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm` (add methods before the trailing `1;`)
- Test: `t/03-script-policy-enforcement.t` (new)

**Interfaces:**
- Consumes: `$self->_expand_cron_hour_field($field)`, `$self->_expand_allowed_hours($spec)` (Task 1).
- Produces: `$script->_command_references_script($command, $script_hashref)` → boolean. `$script->check_non_repeatable($script_hashref, $all_entries, $exclude_job_id)` → `{ valid => 1 }` or `{ valid => 0, error => "..." }`, where `$all_entries` is the arrayref shape returned by `Cron::Job->get_all_crontab_entries()` (each entry has `command`, `schedule`, and optionally `id`). `$script->check_allowed_hours($allowed_hours_spec, $schedule)` → same result shape.

- [ ] **Step 1: Write the failing test**

Create `t/03-script-policy-enforcement.t`:

```perl
use Modern::Perl;
use Test::More tests => 8;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );

my $script = {
    name          => 'finegen.pl',
    path          => '/usr/share/koha/bin/cronjobs/finegen.pl',
    relative_path => '$KOHA_CRON_PATH/finegen.pl',
};

ok(
    $script_model->_command_references_script( '$KOHA_CRON_PATH/finegen.pl --verbose', $script ),
    'matches the $KOHA_CRON_PATH-relative form'
);
ok(
    $script_model->_command_references_script( '/usr/share/koha/bin/cronjobs/finegen.pl -c', $script ),
    'matches the raw absolute path form'
);
ok(
    !$script_model->_command_references_script( '$KOHA_CRON_PATH/other.pl', $script ),
    'does not match an unrelated command'
);

my $entries = [
    { id => 'job-1', command => '$KOHA_CRON_PATH/finegen.pl --verbose', schedule => '0 2 * * *' },
    { command => '/usr/bin/perl /etc/cron-extra/backup.sh', schedule => '0 3 * * *' },
];

my $result = $script_model->check_non_repeatable( $script, $entries, undef );
is( $result->{valid}, 0, 'rejects a new job when the script is already scheduled elsewhere' );

my $result_excluded = $script_model->check_non_repeatable( $script, $entries, 'job-1' );
is( $result_excluded->{valid}, 1, 'excludes the job being updated from the duplicate scan' );

my $ok_hours = $script_model->check_allowed_hours( '1-5', '0 3 * * *' );
is( $ok_hours->{valid}, 1, 'schedule inside allowed hours passes' );

my $bad_hours = $script_model->check_allowed_hours( '1-5', '0 9 * * *' );
is( $bad_hours->{valid}, 0, 'schedule outside allowed hours fails' );
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -v t/03-script-policy-enforcement.t`
Expected: FAIL — `_command_references_script` etc. not yet defined.

- [ ] **Step 3: Implement the enforcement checks**

Add after the Task 2 methods (before the trailing `1;`):

```perl
=head2 _command_references_script

Best-effort check for whether a crontab entry's command invokes the given
script — matched as a whole path token against either the script's
$KOHA_CRON_PATH-relative form or its raw resolved absolute path. This is a
textual heuristic: it will not catch every possible way an arbitrary
system-managed command could invoke the same script (symlinks, unusual
wrappers, obscured paths).

    my $matches = $script->_command_references_script( $command, $script_hashref );

=cut

sub _command_references_script {
    my ( $self, $command, $script ) = @_;

    return 0 unless defined $command && length $command;

    for my $candidate ( grep { defined && length } ( $script->{relative_path}, $script->{path} ) ) {
        return 1 if $command =~ /(?:^|\s)\Q$candidate\E(?:\s|$)/;
    }

    return 0;
}

=head2 check_non_repeatable

Check whether any OTHER crontab entry (managed or system) already
references the given script.

    my $result = $script->check_non_repeatable( $script_hashref, $all_entries, $exclude_job_id );

$all_entries is the arrayref returned by Cron::Job->get_all_crontab_entries
(each entry has 'command', 'schedule', and an 'id' key present only for
plugin-managed entries). $exclude_job_id, if given, excludes the managed
entry with that crontab-manager-id from the scan (used when updating a job
so it doesn't conflict with itself).

Returns { valid => 1 } or { valid => 0, error => '...' }.

=cut

sub check_non_repeatable {
    my ( $self, $script, $all_entries, $exclude_job_id ) = @_;

    for my $entry (@$all_entries) {
        next if defined $exclude_job_id && defined $entry->{id} && $entry->{id} eq $exclude_job_id;
        next unless $self->_command_references_script( $entry->{command}, $script );

        return {
            valid => 0,
            error => "Script '$script->{name}' is marked non-repeatable and is already scheduled ("
              . $entry->{schedule} . ")",
        };
    }

    return { valid => 1 };
}

=head2 check_allowed_hours

Check that a cron schedule's hour field falls entirely within an
allowed_hours policy spec.

    my $result = $script->check_allowed_hours( '1-5', '0 3 * * *' );

Returns { valid => 1 } or { valid => 0, error => '...' }. A blank/undef
$allowed_hours_spec always passes (no restriction).

=cut

sub check_allowed_hours {
    my ( $self, $allowed_hours_spec, $schedule ) = @_;

    return { valid => 1 } unless $allowed_hours_spec && $allowed_hours_spec =~ /\S/;

    my @fields     = split /\s+/, ( $schedule // '' );
    my $hour_field = $fields[1];

    return { valid => 0, error => "Schedule '$schedule' is missing an hour field" }
      unless defined $hour_field && length $hour_field;

    my $scheduled_hours = $self->_expand_cron_hour_field($hour_field);
    my $allowed_hours    = $self->_expand_allowed_hours($allowed_hours_spec);

    my @disallowed = sort { $a <=> $b } grep { !$allowed_hours->{$_} } keys %$scheduled_hours;

    if (@disallowed) {
        return {
            valid => 0,
            error => "Schedule hour(s) "
              . join( ', ', @disallowed )
              . " are outside the allowed hours ($allowed_hours_spec) for this script",
        };
    }

    return { valid => 1 };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -v t/03-script-policy-enforcement.t`
Expected: PASS (8/8).

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm t/03-script-policy-enforcement.t
git commit -m "feat: add non-repeatable and allowed-hours policy checks"
```

---

### Task 4: Enforce policy in job add/update

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm` (`add`, `update`)

**Interfaces:**
- Consumes: `$script_model->validate_command($command)` → now includes `policy` (Task 2); `$script_model->check_non_repeatable($script, $all_entries, $exclude_job_id)`, `$script_model->check_allowed_hours($spec, $schedule)` (Task 3); `$job_model->get_all_crontab_entries()` (existing); `$job_model->get_plugin_managed_jobs()` (existing).
- Produces: `add`/`update` now additionally respond `400 { error => "..." }` for a non_repeatable or allowed_hours violation.

There is no dedicated automated test harness for REST controllers in this
repo (confirmed in `CLAUDE.md` — only `t/00-load.t` exists, and it just
loads the plugin module). This task is verified manually against a running
KTD instance, per the repo's existing testing posture.

- [ ] **Step 1: Enforce policy in `add`**

In `Jobs.pm`, `add`, locate:

```perl
        # Validate command uses approved script
        my $validation = $script_model->validate_command( $body->{command} );
        unless ( $validation->{valid} ) {
            return $c->render(
                status  => 400,
                openapi => { error => $validation->{error} }
            );
        }

        my $job_id = $job_model->generate_job_id();
```

Insert a policy check between the two:

```perl
        # Validate command uses approved script
        my $validation = $script_model->validate_command( $body->{command} );
        unless ( $validation->{valid} ) {
            return $c->render(
                status  => 400,
                openapi => { error => $validation->{error} }
            );
        }

        if ( my $policy = $validation->{policy} ) {
            my $all_entries = $job_model->get_all_crontab_entries();

            if ( $policy->{non_repeatable} ) {
                my $check = $script_model->check_non_repeatable( $validation->{script}, $all_entries, undef );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id = $job_model->generate_job_id();
```

- [ ] **Step 2: Enforce policy in `update`**

In `Jobs.pm`, `update`, locate:

```perl
        # Validate command if it's being updated
        if ( defined $body->{command} ) {
            my $validation = $script_model->validate_command( $body->{command} );
            unless ( $validation->{valid} ) {
                return $c->render(
                    status  => 400,
                    openapi => { error => $validation->{error} }
                );
            }
        }

        my $updated_job;
```

Replace with:

```perl
        # Validate command if it's being updated
        if ( defined $body->{command} ) {
            my $validation = $script_model->validate_command( $body->{command} );
            unless ( $validation->{valid} ) {
                return $c->render(
                    status  => 400,
                    openapi => { error => $validation->{error} }
                );
            }
        }

        # Resolve the command/schedule that will be in effect after this
        # update to evaluate script policy against them — this runs even
        # when only the schedule (not the command) is changing. This is a
        # soft lookup: if the effective command can no longer be resolved
        # to a known script (e.g. the allowlist has tightened since this
        # job was created), policy is simply not enforced rather than
        # blocking an unrelated edit.
        my $existing_jobs = $job_model->get_plugin_managed_jobs();
        my ($existing_job) = grep { $_->{id} eq $job_id } @$existing_jobs;
        unless ($existing_job) {
            return $c->render(
                status  => 404,
                openapi => { error => "Job not found" }
            );
        }

        my $effective_command  = $body->{command}  // $existing_job->{command};
        my $effective_schedule = $body->{schedule} // $existing_job->{schedule};

        my $policy_lookup = $script_model->validate_command($effective_command);
        if ( $policy_lookup->{valid} && $policy_lookup->{policy} ) {
            my $policy = $policy_lookup->{policy};

            if ( $policy->{non_repeatable} ) {
                my $all_entries = $job_model->get_all_crontab_entries();
                my $check = $script_model->check_non_repeatable( $policy_lookup->{script}, $all_entries, $job_id );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $effective_schedule );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $updated_job;
```

- [ ] **Step 3: Manually verify against a running KTD instance**

Start (or reuse) a KTD instance for this plugin (`kd up`), then, as a superlibrarian session or via `curl` with a valid session cookie:

1. Add a job for a script that has `non_repeatable: true` in the effective policy (add a test entry to the library `script_policy` setting via the configure page once Task 7 lands — for now, temporarily hardcode a fake policy in `get_library_policy` for a quick manual check, or defer this specific check until Task 7 is done). Confirm the first `POST /api/v1/contrib/crontab/jobs` succeeds.
2. `POST` a second job for the same script. Confirm it fails with `400` and an error mentioning "non-repeatable".
3. Add a job with `allowed_hours: "1-5"` and a schedule of `0 9 * * *`. Confirm the `POST` fails with `400` mentioning "outside the allowed hours".
4. Change the schedule to `0 3 * * *` and retry. Confirm it now succeeds.
5. `PUT` (update) that job changing only its `description` (not `schedule`/`command`). Confirm it still succeeds (the self-exclusion in `check_non_repeatable` and the soft policy lookup both work).

Since the library-tier UI (Task 7) doesn't exist yet, note this step may need to be re-run once Task 7 is complete for full end-to-end coverage — a quick manual check now with a hand-edited DB row is enough to confirm Task 4's logic works before moving on.

- [ ] **Step 4: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm
git commit -m "feat: enforce non-repeatable and allowed-hours policy on job add/update"
```

---

### Task 5: Surface policy violations on the jobs list

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm` (`list`)
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json` (`/jobs` GET response schema)

**Interfaces:**
- Consumes: `$script_model->validate_command`, `check_non_repeatable`, `check_allowed_hours` (Tasks 2-3); `$job_model->get_all_crontab_entries()` (existing).
- Produces: each job in `GET /api/v1/contrib/crontab/jobs`'s response now includes `policy_violations: []` (array of `"non_repeatable"` and/or `"allowed_hours"` strings, empty when compliant).

No automated test — same rationale as Task 4 (no REST test harness in this repo). Verified manually in Step 3.

- [ ] **Step 1: Instantiate the script model and compute violations in `list`**

In `Jobs.pm`, `list`, locate:

```perl
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $job_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new(
            { crontab => $crontab }
        );

        my $jobs      = $job_model->get_plugin_managed_jobs();
        my @jobs_data = map {
            {
                id          => $_->{id},
                name        => $_->{name},
                description => $_->{description},
                schedule    => $_->{schedule},
                command     => $_->{command},
                enabled => $_->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                environment => $_->{environment},
                created_at  => $_->{created},
                updated_at  => $_->{updated}
            }
        } @$jobs;
```

Replace with:

```perl
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $job_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new(
            { crontab => $crontab }
        );
        my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
        );

        my $jobs        = $job_model->get_plugin_managed_jobs();
        my $all_entries = $job_model->get_all_crontab_entries();

        my @jobs_data = map {
            my $job = $_;

            my @violations;
            my $lookup = $script_model->validate_command( $job->{command} );
            if ( $lookup->{valid} && $lookup->{policy} ) {
                my $policy = $lookup->{policy};

                if ( $policy->{non_repeatable} ) {
                    my $check = $script_model->check_non_repeatable( $lookup->{script}, $all_entries, $job->{id} );
                    push @violations, 'non_repeatable' unless $check->{valid};
                }

                if ( $policy->{allowed_hours} ) {
                    my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $job->{schedule} );
                    push @violations, 'allowed_hours' unless $check->{valid};
                }
            }

            {
                id                => $job->{id},
                name              => $job->{name},
                description       => $job->{description},
                schedule          => $job->{schedule},
                command           => $job->{command},
                enabled           => $job->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                environment       => $job->{environment},
                created_at        => $job->{created},
                updated_at        => $job->{updated},
                policy_violations => \@violations,
            };
        } @$jobs;
```

- [ ] **Step 2: Update the openapi schema**

In `api/openapi.json`, under `/jobs` → `get` → `responses` → `200` → `schema` → `properties` → `jobs` → `items` → `properties`, add:

```json
            "policy_violations": {
              "type": "array",
              "description": "Script policy constraints this job currently violates (non_repeatable, allowed_hours); empty when compliant",
              "items": {
                "type": "string"
              }
            }
```

- [ ] **Step 3: Manually verify against a running KTD instance**

With the library-tier UI not yet built (Task 7), verify by hand-editing the `script_policy` DB setting directly (or via `store_data` in a throwaway KTD shell) to add a policy for a script already used by an existing managed job, in a way that puts that job in violation (e.g. tighten `allowed_hours` to exclude its current schedule). `GET /api/v1/contrib/crontab/jobs` and confirm that job's `policy_violations` array now contains the expected tag(s), and that other compliant jobs have an empty array.

- [ ] **Step 4: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm \
        Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json
git commit -m "feat: report script policy violations on the jobs list"
```

---

### Task 6: Rename script_allowlist to script_policy, add upgrade migration, YAML/JSON transcoding in configure()

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab.pm`
- Test: `t/04-script-policy-migration.t` (new)

**Interfaces:**
- Produces: `$plugin->_convert_legacy_allowlist_text($legacy_text)` → YAML string in the new `{ scripts: [...] }` shape. `$plugin->upgrade()` → migrates the `script_allowlist` DB key to `script_policy` (YAML) and clears the old key; returns `1`. `configure()`'s GET path now populates template params `script_policy` (JSON string, library tier) and `server_policy` (JSON string, server tier, read-only) instead of `script_allowlist`. `configure()`'s save path reads `$cgi->param('script_policy')` as a JSON string and persists it as YAML under the `script_policy` DB key.
- Consumes: `Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new({ plugin => $self })`, `Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new({ crontab => $crontab })->get_server_policy()` (Task 2).

**Note:** Step 4's test triggers a real `upgrade()` run against the KTD instance's live plugin_data table, which will overwrite that instance's `script_allowlist`/`script_policy` settings. If you want a clean slate for manual QA in Tasks 7-9, reset `script_policy` via the configure page (or `store_data`) afterward.

- [ ] **Step 1: Write the failing test**

Create `t/04-script-policy-migration.t`:

```perl
use Modern::Perl;
use Test::More tests => 5;
use JSON::MaybeXS qw(decode_json);
use Path::Tiny qw(path);
use YAML::XS qw(Load);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $package_json = decode_json( path($plugin_dir)->child('package.json')->slurp );
my $plugin_module = $package_json->{plugin}->{module};

unshift @INC, $plugin_dir;
use_ok($plugin_module);

my $plugin = $plugin_module->new();

my $yaml = $plugin->_convert_legacy_allowlist_text("batch/report.pl\nfinegen.pl\n");
like( $yaml, qr/path:\s*batch\/report\.pl/, 'first legacy pattern converted into the scripts list' );
like( $yaml, qr/path:\s*finegen\.pl/, 'second legacy pattern converted' );

$plugin->store_data(
    {
        script_allowlist      => "batch/report.pl\nfinegen.pl\n",
        script_policy          => undef,
        __INSTALLED_VERSION__ => '0.0.1',
    }
);

my $upgraded = $plugin_module->new();    # constructor runs upgrade() since installed version is behind

my $migrated_data = Load( $upgraded->retrieve_data('script_policy') );
is( scalar @{ $migrated_data->{scripts} }, 2, 'upgrade() migrates both legacy patterns' );
is( $upgraded->retrieve_data('script_allowlist'), undef, 'upgrade() clears the legacy key' );
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -v t/04-script-policy-migration.t`
Expected: FAIL — `_convert_legacy_allowlist_text`/`upgrade` not yet defined.

- [ ] **Step 3: Add `use` statements and the migration methods**

At the top of `Crontab.pm`, change:

```perl
use POSIX qw(strftime);
use JSON;

use C4::Context;
```

to:

```perl
use POSIX qw(strftime);
use JSON;
use YAML::XS qw(Load Dump);

use C4::Context;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script;
```

Add, near the other lifecycle subs (`install`, `enable`, `disable`, `uninstall`):

```perl
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -v t/04-script-policy-migration.t`
Expected: PASS (5/5).

- [ ] **Step 5: Rewire `configure()` to the new setting and JSON/YAML transcoding**

Replace the entire `configure` sub:

```perl
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
```

with:

```perl
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $policy_yaml = $self->retrieve_data('script_policy');
        my $policy_data = ( $policy_yaml && $policy_yaml =~ /\S/ ) ? Load($policy_yaml) : { scripts => [] };

        my $crontab      = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $self } );
        my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $crontab } );
        my $server_policy = $script_model->get_server_policy();

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_logging   => $self->retrieve_data('enable_logging'),
            user_allowlist   => $self->retrieve_data('user_allowlist'),
            script_policy    => encode_json($policy_data),
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
        my $policy_yaml = Dump($policy_data);

        $self->store_data(
            {
                enable_logging   => $cgi->param('enable_logging'),
                user_allowlist   => $cgi->param('user_allowlist'),
                script_policy    => $policy_yaml,
                backup_retention => $backup_retention,
            }
        );
        $self->go_home();
    }
}
```

- [ ] **Step 6: Run the full test suite so far**

Run: `prove -v t/00-load.t t/01-cron-hour-expansion.t t/02-script-policy-parsing.t t/03-script-policy-enforcement.t t/04-script-policy-migration.t`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab.pm t/04-script-policy-migration.t
git commit -m "feat: migrate script_allowlist to script_policy with server-file support"
```

---

### Task 7: Configure page — script policy picker with per-script constraints

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/configure.tt`

**Interfaces:**
- Consumes: template params `script_policy` (JSON string, library tier) and `server_policy` (JSON string, server tier) from Task 6's `configure()`.
- Produces: on submit, the hidden `#script_policy` field carries a JSON string `{ scripts: [{path, non_repeatable, allowed_hours}, ...] }`, which `configure()`'s save path (Task 6) transcodes to YAML.

No automated test (template + JS, no test harness for the plugin's UI exists in this repo). Verified manually in Step 3.

- [ ] **Step 1: Update the markup**

Replace:

```html
                                <li>
                                    <label for="script_picker">Script allowlist: </label>
                                    <select name="script_picker" id="script_picker" multiple="multiple"></select>
                                    <input type="hidden" name="script_allowlist" id="script_allowlist" value="[% script_allowlist | html %]" />
                                    <div class="hint">
                                        Search and select scripts to allow users to schedule. Leave empty to allow all scripts from KOHA_CRON_PATH.
                                        <br/><strong>Note:</strong> You can also type directory prefixes (e.g., <code>batch/</code>) to allow all scripts in that directory.
                                    </div>
                                </li>
```

with:

```html
                                <li>
                                    <label for="script_picker">Script policy: </label>
                                    <select name="script_picker" id="script_picker" multiple="multiple"></select>
                                    <input type="hidden" name="script_policy" id="script_policy" value="[% script_policy | html %]" />
                                    <input type="hidden" id="server_policy" value="[% server_policy | html %]" />
                                    <div class="hint">
                                        Search and select scripts to allow users to schedule. Leave empty to allow all scripts from KOHA_CRON_PATH.
                                        <br/><strong>Note:</strong> You can also type directory prefixes (e.g., <code>batch/</code>) to allow all scripts in that directory.
                                        <br/><strong>Note:</strong> Exact scripts (not prefixes) can additionally be marked non-repeatable or restricted to specific hours below the picker.
                                    </div>
                                    <div id="script_policy_panels"></div>
                                </li>
```

- [ ] **Step 2: Replace the script-picker JS**

Replace the entire block from:

```javascript
                // Initialize script allowlist select2
                let allScripts = [];
```

through (inclusive of) the end of:

```javascript
                        $("#script_picker").trigger('change');
                    }
                }
```

(i.e. everything from the `let allScripts = [];` declaration through the end of `initializeScriptPicker`, not including the later `$("form").on("submit", ...)` block) with:

```javascript
                // Initialize script policy picker
                let allScripts = [];
                let libraryPolicyState = {};
                let serverPolicy = {};

                try {
                    let serverPolicyData = JSON.parse($("#server_policy").val() || '{"scripts":[]}');
                    (serverPolicyData.scripts || []).forEach(function(entry) {
                        serverPolicy[entry.path] = entry;
                    });
                } catch (e) {
                    console.error('Failed to parse server policy', e);
                }

                function isExactScript(path) {
                    return allScripts.some(function(candidate) {
                        let relative = candidate.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, '');
                        return relative === path || candidate.name === path;
                    });
                }

                function renderPolicyPanels() {
                    let selected = $("#script_picker").val() || [];
                    let container = $("#script_policy_panels");
                    container.empty();

                    selected.filter(isExactScript).forEach(function(path) {
                        let serverEntry = serverPolicy[path];
                        let state = libraryPolicyState[path] || { non_repeatable: false, allowed_hours: '' };
                        let locked = !!(serverEntry && serverEntry.non_repeatable);
                        let nonRepeatable = locked || state.non_repeatable;
                        let hoursLocked = !!(serverEntry && serverEntry.allowed_hours);
                        let allowedHours = hoursLocked ? serverEntry.allowed_hours : state.allowed_hours;

                        let panel = $(
                            '<div class="card mb-2">' +
                                '<div class="card-body py-2">' +
                                    '<strong>' + escape_str(path) + '</strong><br>' +
                                    '<div class="form-check form-check-inline">' +
                                        '<input class="form-check-input policy-non-repeatable" type="checkbox" data-path="' + escape_str(path) + '"' +
                                            (nonRepeatable ? ' checked' : '') + (locked ? ' disabled' : '') + '>' +
                                        '<label class="form-check-label">Non-repeatable' + (locked ? ' (set by server administrator)' : '') + '</label>' +
                                    '</div>' +
                                    '<div class="form-group d-inline-block ms-3">' +
                                        '<label class="me-1">Allowed hours:</label>' +
                                        '<input type="text" class="form-control form-control-sm d-inline-block policy-allowed-hours" style="width:150px" data-path="' + escape_str(path) + '" placeholder="e.g. 1-5" value="' + escape_str(allowedHours) + '"' +
                                            (hoursLocked ? ' disabled' : '') + '>' +
                                        (hoursLocked ? '<small class="text-muted ms-1">(set by server administrator)</small>' : '') +
                                    '</div>' +
                                '</div>' +
                            '</div>'
                        );

                        container.append(panel);
                    });

                    container.find('.policy-non-repeatable').on('change', function() {
                        let path = $(this).data('path');
                        libraryPolicyState[path] = libraryPolicyState[path] || { non_repeatable: false, allowed_hours: '' };
                        libraryPolicyState[path].non_repeatable = $(this).is(':checked');
                    });

                    container.find('.policy-allowed-hours').on('input', function() {
                        let path = $(this).data('path');
                        libraryPolicyState[path] = libraryPolicyState[path] || { non_repeatable: false, allowed_hours: '' };
                        libraryPolicyState[path].allowed_hours = $(this).val();
                    });
                }

                // Load all available scripts (with bypass_filter=1 to see all scripts for configuration)
                $.ajax({
                    url: '/api/v1/contrib/crontab/scripts?bypass_filter=1',
                    method: 'GET',
                    success: function(data) {
                        if (data.scripts) {
                            allScripts = data.scripts;
                            initializeScriptPicker();
                        }
                    },
                    error: function() {
                        console.error('Failed to load scripts');
                    }
                });

                function initializeScriptPicker() {
                    $("#script_picker").select2({
                        width: "75%",
                        multiple: true,
                        allowClear: true,
                        tags: true, // Allow custom entries like "batch/" for directory prefixes
                        data: allScripts.map(function(script) {
                            return {
                                id: script.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, ''),
                                text: script.name,
                                description: script.description,
                                path: script.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, ''),
                                type: script.type
                            };
                        }),
                        templateResult: function(script) {
                            if (!script.id) {
                                return script.text;
                            }

                            let $script = $("<div></div>");
                            let html = '<strong>' + escape_str(script.text) + '</strong>';

                            if (script.type) {
                                html += ' <span class="badge badge-secondary">' + script.type + '</span>';
                            }

                            if (script.description) {
                                html += '<br><small class="text-muted">' + escape_str(script.description) + '</small>';
                            }

                            if (script.path) {
                                html += '<br><small><code>' + escape_str(script.path) + '</code></small>';
                            }

                            $script.html(html);
                            return $script;
                        },
                        templateSelection: function(script) {
                            if (script.text) {
                                return escape_str(script.text);
                            }
                            return escape_str(script.id);
                        },
                        placeholder: "Select scripts or type directory prefixes (e.g., batch/)"
                    });

                    // Load existing library-tier selections and policy
                    let existingPolicy = { scripts: [] };
                    try {
                        existingPolicy = JSON.parse($("#script_policy").val() || '{"scripts":[]}');
                    } catch (e) {
                        console.error('Failed to parse existing script policy', e);
                    }

                    (existingPolicy.scripts || []).forEach(function(entry) {
                        libraryPolicyState[entry.path] = {
                            non_repeatable: !!entry.non_repeatable,
                            allowed_hours: entry.allowed_hours || ''
                        };

                        let existingOption = allScripts.find(s =>
                            s.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, '') === entry.path ||
                            s.name === entry.path
                        );

                        let displayText = existingOption ? existingOption.name : entry.path;
                        let option = new Option(displayText, entry.path, true, true);
                        $("#script_picker").append(option);
                    });
                    $("#script_picker").trigger('change');

                    renderPolicyPanels();

                    $("#script_picker").on('change', function() {
                        let selected = $(this).val() || [];
                        Object.keys(libraryPolicyState).forEach(function(path) {
                            if (selected.indexOf(path) === -1) {
                                delete libraryPolicyState[path];
                            }
                        });
                        renderPolicyPanels();
                    });
                }
```

- [ ] **Step 3: Update the form-submit serialization**

Replace:

```javascript
                    // Handle script allowlist
                    let selectedScripts = $("#script_picker").val();
                    if (selectedScripts && selectedScripts.length > 0) {
                        $("#script_allowlist").val(selectedScripts.join("\n"));
                    } else {
                        $("#script_allowlist").val("");
                    }
```

with:

```javascript
                    // Handle script policy
                    let selectedScripts = $("#script_picker").val() || [];
                    let scriptsPayload = selectedScripts.map(function(path) {
                        let state = libraryPolicyState[path] || { non_repeatable: false, allowed_hours: '' };
                        let exact = isExactScript(path);
                        return {
                            path: path,
                            non_repeatable: exact ? !!state.non_repeatable : false,
                            allowed_hours: exact ? ( state.allowed_hours || '' ) : ''
                        };
                    });
                    $("#script_policy").val(JSON.stringify({ scripts: scriptsPayload }));
```

- [ ] **Step 4: Manually verify against a running KTD instance**

With a KTD instance running (`kd up`) and the plugin enabled:

1. Open the plugin's Configure page. Confirm the script picker and any previously-selected scripts (from before this change, if any existed as plain-line `script_allowlist`) still render sensibly after Task 6's migration ran.
2. Select an exact script (not a directory prefix). Confirm a policy panel appears below the picker with an unchecked "Non-repeatable" box and an empty "Allowed hours" field.
3. Check "Non-repeatable" and set "Allowed hours" to `1-5`. Save. Reload the page. Confirm both values persisted (the panel re-renders with the same state).
4. Select a directory-prefix entry (e.g. type `batch/` and press enter in the picker). Confirm no policy panel appears for it.
5. If a server policy file is configured (`koha_plugin_crontab_script_policy` in koha-conf.xml) with a `non_repeatable: true` entry for a script, confirm that script's panel renders with the checkbox checked and disabled, labelled "(set by server administrator)", when selected.

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/configure.tt
git commit -m "feat: add per-script policy controls to the configure page"
```

---

### Task 8: Job form hints and jobs table violation badge

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt`

**Interfaces:**
- Consumes: `scriptData.policy` from `GET /api/v1/contrib/crontab/scripts/details` (Task 2); `job.policy_violations` from `GET /api/v1/contrib/crontab/jobs` (Task 5).

No automated test (template + JS). Verified manually in Step 3.

- [ ] **Step 1: Add a hint element near the script description**

Replace:

```html
                                        <div id="script-description" class="alert alert-info" style="display: none;">
                                            <!-- Script description will be shown here -->
                                        </div>
```

with:

```html
                                        <div id="script-description" class="alert alert-info" style="display: none;">
                                            <!-- Script description will be shown here -->
                                        </div>
                                        <div id="script-policy-hint" class="alert alert-warning" style="display: none;">
                                            <!-- Script policy constraints will be shown here -->
                                        </div>
```

- [ ] **Step 2: Render the hint when a policy-restricted script is selected**

In `displayScriptOptions(scriptData)`, locate:

```javascript
        function displayScriptOptions(scriptData) {
            // Show description
            if (scriptData.description) {
                $('#script-description').html('<strong>' + scriptData.name + ':</strong> ' + scriptData.description).show();
            }
```

Add immediately after:

```javascript
        function displayScriptOptions(scriptData) {
            // Show description
            if (scriptData.description) {
                $('#script-description').html('<strong>' + scriptData.name + ':</strong> ' + scriptData.description).show();
            }

            // Show policy hint, if this script has scheduling constraints
            if (scriptData.policy && (scriptData.policy.non_repeatable || scriptData.policy.allowed_hours)) {
                let hints = [];
                if (scriptData.policy.non_repeatable) {
                    hints.push('this script may only be scheduled once across the crontab');
                }
                if (scriptData.policy.allowed_hours) {
                    hints.push('it may only run during hours: ' + scriptData.policy.allowed_hours);
                }
                $('#script-policy-hint').html('<i class="fa fa-exclamation-triangle"></i> ' + hints.join('; ') + '.').show();
            } else {
                $('#script-policy-hint').hide();
            }
```

- [ ] **Step 3: Reset the hint alongside the description when the form is reset**

Locate the reset block:

```javascript
            $('#script-description').hide();
```

Add immediately after:

```javascript
            $('#script-description').hide();
            $('#script-policy-hint').hide();
```

- [ ] **Step 4: Add a violation badge to the managed jobs table**

In `populateJobsTable`, locate:

```javascript
                let statusBadge = job.enabled
                    ? '<span class="badge bg-success">Enabled</span>'
                    : '<span class="badge bg-secondary">Disabled</span>';
```

Replace with:

```javascript
                let statusBadge = job.enabled
                    ? '<span class="badge bg-success">Enabled</span>'
                    : '<span class="badge bg-secondary">Disabled</span>';

                if (job.policy_violations && job.policy_violations.length > 0) {
                    let violationLabels = job.policy_violations.map(function(v) {
                        return v === 'non_repeatable' ? 'duplicate script' : 'outside allowed hours';
                    }).join(', ');
                    statusBadge += ' <span class="badge bg-warning text-dark" title="Violates script policy: ' + violationLabels + '"><i class="fa fa-exclamation-triangle"></i></span>';
                }
```

- [ ] **Step 5: Manually verify against a running KTD instance**

With a KTD instance running and at least one exact script marked with policy via the Task 7 configure page:

1. Open the "New Job" modal, browse to and select that script. Confirm the yellow policy hint appears under the description with the expected wording.
2. Create a job that violates `allowed_hours` bypassing the hint (e.g. via `curl` directly, since the UI itself won't stop you — Task 4 enforces server-side) is not needed; instead, create a compliant job, then tighten the policy afterward via configure (per Task 7 Step 4) so the existing job becomes non-compliant.
3. Reload the Managed Jobs tab. Confirm the now-noncompliant job shows a warning badge next to its status, with a tooltip listing the violated constraint(s), and that the job itself is otherwise untouched (still enabled/scheduled as before).

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt
git commit -m "feat: show script policy hints and violation badges in the job UI"
```

---

### Task 9: Document the new koha-conf.xml entry and changelog

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Document `koha_plugin_crontab_script_policy` in README.md**

After the existing `koha_plugin_crontab_cronfile` entry:

```markdown
### koha_plugin_crontab_cronfile

`<koha_plugin_crontab_cronfile>/etc/cron.d/koha-mylibrary</koha_plugin_crontab_cronfile>`
By default the plugin will use the Koha user's crontab. If this option is set, it will use this file instead.
```

Add:

```markdown
### koha_plugin_crontab_script_policy

`<koha_plugin_crontab_script_policy>/etc/koha/plugins/crontab-script-policy.yaml</koha_plugin_crontab_script_policy>`
If set, points to a YAML file defining a server-enforced ceiling on which scripts may be scheduled and what scheduling constraints apply to them. The library's own Script Policy setting (configured via the Configure page) can only select a subset of what this file allows, and can only tighten (never loosen) any `non_repeatable`/`allowed_hours` it sets. See the plugin's Configure page for the schema. If this option is not set, the library's Script Policy setting alone governs, as before.
```

- [ ] **Step 2: Update the "Configuration Page" bullet list**

Replace:

```markdown
- **Command Allowlist**: Define which subset of KOHA_CRON commands/scripts are permitted to run (recommended for security)
```

with:

```markdown
- **Script Policy**: Define which subset of KOHA_CRON commands/scripts are permitted to run, and optionally mark individual scripts as non-repeatable (only one scheduled instance at a time) or restricted to specific hours of the day (recommended for security)
```

- [ ] **Step 3: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add an `### Added` and `### Changed` section (or append to existing ones if already present):

```markdown
### Added
- Script policy: mark individual allowed scripts as non-repeatable (only one scheduled instance at a time) or restricted to specific hours of the day
- Optional server-administrator-controlled script policy file (`koha_plugin_crontab_script_policy` koha-conf.xml entry) that acts as a ceiling/floor on the library's own script policy settings
- Warning badge on the Managed Jobs table for jobs that currently violate script policy (existing jobs are never blocked or altered, only flagged)

### Changed
- Renamed the `script_allowlist` plugin setting to `script_policy` and switched its storage format from plain text lines to YAML; existing installations are migrated automatically on upgrade
```

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document script policy configuration and changelog"
```
