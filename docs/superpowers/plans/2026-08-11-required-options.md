# Required Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix GitHub issues #21 and #22 by replacing the plugin's incorrect Getopt::Long-derived "required" flag with an explicit, administrator-curated `required_options` field in the existing two-tier `script_policy` config, enforced both server-side (job add/update/migrate) and client-side (command builder).

**Architecture:** `Cron::Script.pm`'s `_parse_option_spec` stops inferring `required` from Getopt::Long's `=`/`:` modifier (which only means "needs a value if used", not "must be used"). `required_options` (an array of long option names) is added to the existing `script_policy` YAML schema at both tiers, merged as a union (library can only add to what the server requires, never remove). `Scripts.pm#get` computes each option's `required` boolean from policy membership before returning it, so the frontend's existing rendering code needs no changes. A new `check_required_options` method (mirroring `check_non_repeatable`/`check_allowed_hours`) is wired into `Jobs.pm`'s `add`/`update`/`migrate`. `crontab.tt` gets a client-side pre-flight check for responsiveness, and `configure.tt`'s policy editor gains a per-script checkbox list (fetched from the script's own parsed options) for curating `required_options`.

**Tech Stack:** Perl (Modern::Perl), `Text::ParseWords` (core Perl module, no new dependency) for command tokenization, YAML::XS (already a hard Koha core dependency, already used by `script_policy`), Mojolicious REST controllers, vanilla JS/jQuery + Bootstrap 5 templates (no build step), Test::More run via `koha-prove` inside a KTD instance.

## Global Constraints

- Zero new external CPAN dependencies — `Text::ParseWords` is a core Perl module shipped with every Perl install; `YAML::XS` is already a hard Koha dependency used by the existing `script_policy` feature.
- `required_options` follows the same two-tier ceiling/merge posture as `non_repeatable`/`allowed_hours`: only meaningful on an exact script path entry (never a directory-prefix entry), and only applies to a path once it's present in the library tier's picker selection (same rule the existing tiers already follow).
- Merge semantics for `required_options` specifically are a **union** (server ∪ library), not OR/intersection like the boolean/hours fields — the library tier can only add further mandatory options on top of the server's, never remove one the server requires.
- All tests in this repo run via `prove` against a live Koha/KTD environment (there is no lighter-weight unit-test harness) — per `CLAUDE.md`, use the `koha-prove` skill or `prove t/<file>.t` inside a running KTD container with `KOHA_PLUGIN_DIR` set. A KTD instance must be running (`kd up`) before any "Run tests" step below can execute.
- There is no REST-controller or JS test harness in this repo (confirmed by existing precedent: `Jobs.pm` enforcement changes for `non_repeatable`/`allowed_hours` were verified manually, not via automated test). `Jobs.pm`, `Scripts.pm`, `crontab.tt`, and `configure.tt` changes in this plan follow the same posture — unit-tested where the logic lives in `Cron::Script.pm`, manually verified where it's REST wiring or UI.
- Full spec: `docs/superpowers/specs/2026-08-11-required-options-design.md`.

---

### Task 1: Drop Getopt::Long-inferred `required`, add `required_options` to the policy data model

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm` (`_parse_option_spec`, `_load_policy_source`, `_merge_policy_tiers`, `get_available_scripts`)
- Test: `t/02-script-policy-parsing.t` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `_parse_option_spec($spec)`'s returned hashref no longer has a `required` key. `_load_policy_source($yaml_text)`'s entries gain `required_options` (arrayref of strings, deduped and sorted, `[]` if absent/invalid). `_merge_policy_tiers($server, $library)`'s effective entries gain `required_options` as the deduped, sorted union of both tiers' lists for that path. `get_available_scripts()` results' `policy` hashref gains `required_options => [...]` alongside `non_repeatable`/`allowed_hours`. New private helpers `_normalize_required_options($raw_arrayref)` → sorted, deduped arrayref of defined non-empty strings; `_union_required_options($server_list, $library_list)` → sorted, deduped arrayref union of the two.

- [ ] **Step 1: Write the failing test**

Replace the full contents of `t/02-script-policy-parsing.t` with:

```perl
use Modern::Perl;
use Test::More tests => 16;

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
    required_options: ["report-id", "report-id", "format"]
  - path: finegen.pl
    non_repeatable: true
  - path: batch/
YAML

my $parsed = $script->_load_policy_source($yaml);
is( scalar @$parsed, 3, 'parses three entries' );

my ($report) = grep { $_->{path} eq 'batch/report.pl' } @$parsed;
is( $report->{non_repeatable}, 1, 'non_repeatable parsed as true' );
is( $report->{allowed_hours}, '1-5', 'allowed_hours parsed' );
is_deeply(
    $report->{required_options},
    [ 'format', 'report-id' ],
    'required_options parsed, deduped, and sorted'
);

my ($finegen_raw) = grep { $_->{path} eq 'finegen.pl' } @$parsed;
is_deeply( $finegen_raw->{required_options}, [], 'entry with no required_options key defaults to an empty list' );

my ($prefix) = grep { $_->{path} eq 'batch/' } @$parsed;
is( $prefix->{non_repeatable}, 0, 'entry with no non_repeatable key defaults to false' );

# _parse_option_spec no longer infers "required" from Getopt::Long syntax
my $spec_with_equals = $script->_parse_option_spec('lost|l=s%');
ok( !exists $spec_with_equals->{required}, '_parse_option_spec drops the required key for a "=" spec' );

my $spec_with_colon = $script->_parse_option_spec('charge|c:s');
ok( !exists $spec_with_colon->{required}, '_parse_option_spec drops the required key for a ":" spec' );

my $server  = [
    { path => 'finegen.pl', non_repeatable => 1, allowed_hours => '1-10', required_options => ['lost'] },
];
my $library = [
    {
        path             => 'finegen.pl',
        non_repeatable   => 0,
        allowed_hours    => '2-4',
        required_options => [ 'charge', 'lost' ],
    },
    { path => 'unlisted.pl', non_repeatable => 1, allowed_hours => '', required_options => ['maxdays'] },
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
is_deeply(
    $finegen->{required_options},
    [ 'charge', 'lost' ],
    'effective required_options is the deduped union of both tiers'
);

my $no_ceiling = $script->_merge_policy_tiers( [], $library );
is( scalar @$no_ceiling, 2, 'an empty server tier leaves the library tier untouched, required_options included' );
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -v t/02-script-policy-parsing.t`
Expected: FAIL — `required_options` not yet present on parsed/merged entries, and `_parse_option_spec` still returns a `required` key.

- [ ] **Step 3: Remove the bogus `required` inference from `_parse_option_spec`**

In `Cron/Script.pm`, `_parse_option_spec`, locate:

```perl
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
```

Replace with (drops `$required` entirely — Getopt::Long's `=`/`:` only says whether a *value* is required *if the flag is used*, never whether the flag itself is mandatory; that's now a policy concern, not a parsing concern):

```perl
    my $type        = 'boolean';
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
        negatable   => $negatable,
        incremental => $incremental,
        repeatable  => $repeatable,
        dest_type   => $dest_type,
    };
}
```

Also update the `=head2 parse_script_options` POD just above `_parse_getoptions_block` (search for `options => arrayref of option hashrefs (name, short_name, type, required,`) — remove `required,` from that list since the field no longer exists:

```perl
Returns hashref with:
  options => arrayref of option hashrefs (name, short_name, type, required,
             negatable, incremental, repeatable, dest_type)
  positional_args => arrayref of detected positional argument patterns
```

to:

```perl
Returns hashref with:
  options => arrayref of option hashrefs (name, short_name, type,
             negatable, incremental, repeatable, dest_type)
  positional_args => arrayref of detected positional argument patterns
```

- [ ] **Step 4: Add `required_options` parsing and merge logic**

In `Cron/Script.pm`, `_load_policy_source`, locate:

```perl
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
```

Replace with:

```perl
    my @entries;
    for my $raw ( @{ $data->{scripts} } ) {
        next unless ref($raw) eq 'HASH' && defined $raw->{path} && length $raw->{path};

        push @entries,
          {
            path             => $raw->{path},
            non_repeatable   => $raw->{non_repeatable} ? 1 : 0,
            allowed_hours    => $raw->{allowed_hours} || '',
            required_options => $self->_normalize_required_options( $raw->{required_options} ),
          };
    }

    return \@entries;
}

=head2 _normalize_required_options

Normalize a raw required_options value from parsed YAML into a deduped,
sorted arrayref of option names. Anything other than an arrayref (missing
key, wrong type) is treated as an empty list.

    my $names = $script->_normalize_required_options( ['lost', 'lost', 'charge'] );
    # ['charge', 'lost']

=cut

sub _normalize_required_options {
    my ( $self, $raw ) = @_;

    return [] unless ref($raw) eq 'ARRAY';

    my %seen;
    my @names = grep { !$seen{$_}++ } grep { defined && length } @$raw;

    return [ sort @names ];
}
```

In `_merge_policy_tiers`, locate:

```perl
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
```

Replace with:

```perl
    my @effective;
    for my $library (@$library_entries) {
        my $server = $server_by_path{ $library->{path} };
        next unless $server;    # ceiling excludes this path entirely

        push @effective,
          {
            path             => $library->{path},
            non_repeatable   => ( $server->{non_repeatable} || $library->{non_repeatable} ) ? 1 : 0,
            allowed_hours    => $self->_intersect_allowed_hours( $server->{allowed_hours}, $library->{allowed_hours} ),
            required_options => $self->_union_required_options( $server->{required_options}, $library->{required_options} ),
          };
    }

    return \@effective;
}

=head2 _union_required_options

Combine two required_options lists into their deduped, sorted union. The
library tier can only ever add to what the server tier requires, never
remove from it.

    my $names = $script->_union_required_options( ['lost'], ['charge', 'lost'] );
    # ['charge', 'lost']

=cut

sub _union_required_options {
    my ( $self, $server_list, $library_list ) = @_;

    my %seen;
    my @union = grep { !$seen{$_}++ } ( @{ $server_list || [] }, @{ $library_list || [] } );

    return [ sort @union ];
}
```

In `get_available_scripts`, locate:

```perl
        my ($exact_entry) = grep { $_->{path} eq $rel_path || $_->{path} eq $script->{name} } @$effective_policy;
        if ($exact_entry) {
            $script->{policy} = {
                non_repeatable => $exact_entry->{non_repeatable} ? 1 : 0,
                allowed_hours  => $exact_entry->{allowed_hours}  || '',
            };
        }
```

Replace with:

```perl
        my ($exact_entry) = grep { $_->{path} eq $rel_path || $_->{path} eq $script->{name} } @$effective_policy;
        if ($exact_entry) {
            $script->{policy} = {
                non_repeatable   => $exact_entry->{non_repeatable}   ? 1  : 0,
                allowed_hours    => $exact_entry->{allowed_hours}    || '',
                required_options => $exact_entry->{required_options} || [],
            };
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `prove -v t/02-script-policy-parsing.t`
Expected: PASS (16/16).

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm t/02-script-policy-parsing.t
git commit -m "fix: stop inferring required options from Getopt::Long syntax, add required_options policy"
```

---

### Task 2: `check_required_options` enforcement helper

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm` (add `use Text::ParseWords`, new method)
- Test: `t/03-script-policy-enforcement.t` (extend)

**Interfaces:**
- Consumes: `$self->parse_script_options($script_path)` (existing).
- Produces: `$script->check_required_options($required_options, $command, $script_path)` → `{ valid => 1 }` or `{ valid => 0, error => "..." }`. `$required_options` is an arrayref of long option names (may be `undef`/empty, which always passes). `$script_path` is optional — when given, it's used to resolve each required long name to its short alias (via `parse_script_options`) so `-x` satisfies a requirement on `x`'s long name too; when omitted, only the long-name/`--name=value` forms are checked.

- [ ] **Step 1: Write the failing test**

In `t/03-script-policy-enforcement.t`, change:

```perl
use Modern::Perl;
use Test::More tests => 8;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
```

to:

```perl
use Modern::Perl;
use Test::More tests => 16;
use File::Temp qw(tempfile);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
```

Then, at the end of the file, after the existing `check_allowed_hours` tests, add:

```perl
my ( $tmp_fh, $tmp_script ) = tempfile( SUFFIX => '.pl' );
print $tmp_fh <<'SCRIPT';
use Getopt::Long;
GetOptions(
    'lost|l=s%'  => \my %lost,
    'charge|c=s' => \my $charge,
);
SCRIPT
close $tmp_fh;

my $none_required = $script_model->check_required_options( [], '$KOHA_CRON_PATH/longoverdue.pl', $tmp_script );
is( $none_required->{valid}, 1, 'an empty required_options list always passes' );

my $missing = $script_model->check_required_options(
    ['lost'], '$KOHA_CRON_PATH/longoverdue.pl --charge 1', $tmp_script
);
is( $missing->{valid}, 0, 'missing required option fails' );
like( $missing->{error}, qr/--lost/, 'error names the missing option by its long form' );

my $present_long = $script_model->check_required_options(
    ['lost'], '$KOHA_CRON_PATH/longoverdue.pl --lost 30=1', $tmp_script
);
is( $present_long->{valid}, 1, 'required option present via long name (space-separated value) passes' );

my $present_eq_form = $script_model->check_required_options(
    ['charge'], '$KOHA_CRON_PATH/longoverdue.pl --charge=1', $tmp_script
);
is( $present_eq_form->{valid}, 1, 'required option present via --name=value form passes' );

my $present_short = $script_model->check_required_options(
    ['lost'], '$KOHA_CRON_PATH/longoverdue.pl -l 30=1', $tmp_script
);
is( $present_short->{valid}, 1, 'required option present via its short alias passes (resolved from script_path)' );

my $present_short_without_path = $script_model->check_required_options(
    ['lost'], '$KOHA_CRON_PATH/longoverdue.pl -l 30=1', undef
);
is(
    $present_short_without_path->{valid}, 0,
    'without a script_path, short-alias resolution is unavailable so only long-form matches'
);

my $quoted = $script_model->check_required_options(
    ['lost'], q{$KOHA_CRON_PATH/longoverdue.pl --lost '30=1 lost'}, $tmp_script
);
is( $quoted->{valid}, 1, 'shellwords tokenizes a quoted value without splitting the flag from it' );

unlink $tmp_script;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -v t/03-script-policy-enforcement.t`
Expected: FAIL — `check_required_options` not yet defined.

- [ ] **Step 3: Implement `check_required_options`**

At the top of `Cron/Script.pm`, change:

```perl
use Modern::Perl;
use File::Find;
use File::Basename;
use Pod::Usage;
use Try::Tiny;
use C4::Context;
use YAML::XS qw(Load);
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
use Text::ParseWords qw(shellwords);
```

Add after `check_allowed_hours` (before the trailing `1;`):

```perl
=head2 check_required_options

Check that a command supplies a value for every option name listed in a
script's effective required_options policy. Getopt::Long's own spec syntax
cannot express "this flag is mandatory" (only "this flag needs a value if
it's used"), so required-ness is entirely policy-driven — this just
confirms each required flag's token is actually present in the submitted
command.

    my $result = $script->check_required_options( $required_options, $command, $script_path );

$required_options is an arrayref of long option names. $script_path, if
given, is used to resolve each name to its short alias (via
C<parse_script_options>) so a command using the short form also satisfies
the requirement; without it, only long-form tokens are recognised.

Returns { valid => 1 } immediately if $required_options is empty/undef.
Otherwise returns { valid => 1 } or { valid => 0, error => '...' } naming
every missing option at once.

=cut

sub check_required_options {
    my ( $self, $required_options, $command, $script_path ) = @_;

    return { valid => 1 } unless $required_options && @$required_options;

    my @tokens = shellwords( $command // '' );

    my %short_name_for;
    if ( defined $script_path && length $script_path ) {
        my $parsed = $self->parse_script_options($script_path);
        %short_name_for = map { $_->{name} => $_->{short_name} } @{ $parsed->{options} };
    }

    my @missing;
    for my $name (@$required_options) {
        my $short = $short_name_for{$name};
        my $present = grep {
                 $_ eq "--$name"
              || index( $_, "--$name=" ) == 0
              || ( $short && ( $_ eq "-$short" || index( $_, "-$short=" ) == 0 ) )
        } @tokens;
        push @missing, $name unless $present;
    }

    if (@missing) {
        return {
            valid => 0,
            error => "Required option(s) missing: " . join( ', ', map { "--$_" } @missing ),
        };
    }

    return { valid => 1 };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -v t/03-script-policy-enforcement.t`
Expected: PASS (16/16).

- [ ] **Step 5: Run the full test suite so far**

Run: `prove -v t/00-load.t t/01-cron-hour-expansion.t t/02-script-policy-parsing.t t/03-script-policy-enforcement.t t/04-script-policy-migration.t`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Script.pm t/03-script-policy-enforcement.t
git commit -m "feat: add check_required_options policy enforcement helper"
```

---

### Task 3: Wire required-options enforcement into job add/update/migrate

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm` (`add`, `update`, `migrate`)

**Interfaces:**
- Consumes: `$script_model->check_required_options($required_options, $command, $script_path)` (Task 2); `$validation->{policy}{required_options}` / `$policy_lookup->{policy}{required_options}` (Task 1, via `validate_command`'s existing `policy` passthrough — no changes needed to `validate_command` itself, since it already returns `policy => $matched_script->{policy}` and that hashref now carries `required_options`).
- Produces: `add`, `update`, and `migrate` now additionally respond `400 { error => "Required option(s) missing: ..." }` when a required option's flag is absent from the submitted command.

No automated test — same rationale as the existing `non_repeatable`/`allowed_hours` wiring in this file: there is no REST-controller test harness in this repo. Verified manually in Step 4.

- [ ] **Step 1: Enforce in `add`**

In `Jobs.pm`, `add`, locate:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id = $job_model->generate_job_id();
```

Replace with:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{required_options} && @{ $policy->{required_options} } ) {
                my $check = $script_model->check_required_options(
                    $policy->{required_options}, $body->{command}, $validation->{script}{path}
                );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id = $job_model->generate_job_id();
```

- [ ] **Step 2: Enforce in `migrate`**

In `Jobs.pm`, `migrate`, locate:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id      = $job_model->generate_job_id();
```

Replace with:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{required_options} && @{ $policy->{required_options} } ) {
                my $check = $script_model->check_required_options(
                    $policy->{required_options}, $body->{command}, $validation->{script}{path}
                );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id      = $job_model->generate_job_id();
```

- [ ] **Step 3: Enforce in `update`**

In `Jobs.pm`, `update`, locate:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $effective_schedule );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $updated_job;
```

Replace with:

```perl
            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $effective_schedule );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{required_options} && @{ $policy->{required_options} } ) {
                my $check = $script_model->check_required_options(
                    $policy->{required_options}, $effective_command, $policy_lookup->{script}{path}
                );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $updated_job;
```

- [ ] **Step 4: Manually verify against a running KTD instance**

Start (or reuse) a KTD instance for this plugin (`kd up`). Since the `configure.tt` UI for curating `required_options` doesn't exist yet (Task 6), temporarily set a policy directly via a KTD shell for this check, then clear it afterward:

```perl
# inside the KTD container, e.g. via `koha-shell` + `perl -e`, or a throwaway one-off script
my $plugin = Koha::Plugin::Com::OpenFifth::Crontab->new;
$plugin->store_data({
    script_policy => "scripts:\n  - path: misc/cronjobs/longoverdue.pl\n    required_options: [\"lost\"]\n",
});
```

1. `POST /api/v1/contrib/crontab/jobs` with `command => '$KOHA_CRON_PATH/misc/cronjobs/longoverdue.pl --charge 1'` (no `--lost`). Confirm `400` with an error mentioning `--lost`.
2. Retry with `--lost 30=1` added. Confirm it now succeeds.
3. `PUT` (update) that job changing only its `description`. Confirm the required-options check still passes (the effective command carries over from the existing job, consistent with how `non_repeatable`/`allowed_hours` already handle schedule-only updates).
4. Find or construct an unmanaged system crontab entry using the same script without `--lost`, and attempt `POST /api/v1/contrib/crontab/jobs/migrate` against it. Confirm `400` with the same missing-option error.
5. Reset the `script_policy` setting back to its prior value (or clear it) once done.

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm
git commit -m "feat: enforce required-options policy on job add, update, and migrate"
```

---

### Task 4: `Scripts.pm#get` computes `required` from policy; add `bypass_filter`; update openapi.json

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Scripts.pm` (`get`)
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json` (`/scripts`, `/scripts/details`)

**Interfaces:**
- Consumes: `$script_model->get_available_scripts($options)` (Task 1's `required_options` addition to `policy`); `$script_model->parse_script_options($path)` (existing, now without a `required` key per Task 1).
- Produces: `GET /scripts/details` (`Scripts.pm#get`) now: (a) accepts an optional `bypass_filter` query param, same semantics as `list`'s; (b) each returned option in the `options` array gains a `required` boolean computed from whether that option's `name` appears in the resolved script's `policy.required_options`, restoring the field the frontend already reads (`option.required`) but now correctly sourced.

No automated test — same rationale as Task 3 (REST controller, no test harness in this repo). Verified manually in Step 3.

- [ ] **Step 1: Add `bypass_filter` support and compute `option.required` from policy**

In `Scripts.pm`, `get`, locate:

```perl
    my $script_name = $c->validation->param('name');

    try {
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $script_model =
          Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
          );

        # Get all scripts and find the requested one
        my $scripts = $script_model->get_available_scripts();
        my ($script) = grep { $_->{name} eq $script_name } @$scripts;

        unless ($script) {
            return $c->render(
                status  => 404,
                openapi => { error => "Script not found" }
            );
        }

        # Parse documentation and options
        my $doc    = $script_model->parse_script_documentation( $script->{path} );
        my $parsed = $script_model->parse_script_options( $script->{path} );

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
                policy          => $script->{policy} || {},
            }
        );
    }
```

Replace with:

```perl
    my $script_name = $c->validation->param('name');

    # Check if bypass_filter parameter is provided (for the configuration page,
    # which needs option details for scripts not yet in the policy)
    my $bypass_filter = $c->validation->param('bypass_filter') || 0;
    my $options_arg = $bypass_filter ? { bypass_filter => 1 } : {};

    try {
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $script_model =
          Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
          );

        # Get all scripts and find the requested one
        my $scripts = $script_model->get_available_scripts($options_arg);
        my ($script) = grep { $_->{name} eq $script_name } @$scripts;

        unless ($script) {
            return $c->render(
                status  => 404,
                openapi => { error => "Script not found" }
            );
        }

        # Parse documentation and options
        my $doc    = $script_model->parse_script_documentation( $script->{path} );
        my $parsed = $script_model->parse_script_options( $script->{path} );

        my $policy           = $script->{policy} || {};
        my %required_lookup  = map { $_ => 1 } @{ $policy->{required_options} || [] };
        my @options_with_req = map {
            { %$_, required => $required_lookup{ $_->{name} } ? 1 : 0 }
        } @{ $parsed->{options} };

        return $c->render(
            status  => 200,
            openapi => {
                name            => $script->{name},
                path            => $script->{relative_path},
                type            => $script->{type},
                description     => $doc->{name_brief} || '',
                usage_text      => $doc->{usage_text} || '',
                options         => \@options_with_req,
                positional_args => $parsed->{positional_args},
                policy          => $policy,
            }
        );
    }
```

- [ ] **Step 2: Update the openapi schema**

In `api/openapi.json`, under `/scripts/details` → `get` → `parameters`, add a `bypass_filter` entry alongside the existing `name` parameter:

```json
            "parameters": [
                {
                    "name": "name",
                    "in": "query",
                    "description": "Script filename (with extension)",
                    "required": true,
                    "type": "string"
                },
                {
                    "name": "bypass_filter",
                    "in": "query",
                    "description": "Bypass script policy filtering (used by configuration page to fetch option details for a script not yet in the policy)",
                    "required": false,
                    "type": "boolean",
                    "default": false
                }
            ],
```

Under `/scripts/details` → `get` → `responses` → `200` → `schema` → `properties` → `options` → `items` → `properties`, update the description of the existing `required` property to reflect its new source. Locate:

```json
                                        "required": {
                                            "type": "boolean",
                                            "description": "Whether option value is required (= vs : modifier)"
                                        },
```

Replace with:

```json
                                        "required": {
                                            "type": "boolean",
                                            "description": "Whether this option is required by script policy (required_options)"
                                        },
```

Under both `/scripts` → `get` → `responses` → `200` → `schema` → `properties` → `scripts` → `items` → `properties` → `policy` → `properties`, and `/scripts/details` → `get` → `responses` → `200` → `schema` → `properties` → `policy` → `properties`, add a `required_options` property alongside the existing `non_repeatable`/`allowed_hours`. In both places, locate:

```json
                                            "allowed_hours": {
                                                "type": "string",
                                                "description": "Comma-separated hours/ranges (0-23) this script may be scheduled within"
                                            }
                                        }
                                    }
```

(the `/scripts` occurrence — note the different indentation/closing braces at the `/scripts/details` occurrence, shown separately below) and replace with:

```json
                                            "allowed_hours": {
                                                "type": "string",
                                                "description": "Comma-separated hours/ranges (0-23) this script may be scheduled within"
                                            },
                                            "required_options": {
                                                "type": "array",
                                                "description": "Long option names that must have a value in this script's command",
                                                "items": {
                                                    "type": "string"
                                                }
                                            }
                                        }
                                    }
```

For the `/scripts/details` occurrence, locate:

```json
                                    "allowed_hours": {
                                        "type": "string",
                                        "description": "Comma-separated hours/ranges (0-23) this script may be scheduled within"
                                    }
                                }
                            }
```

and replace with:

```json
                                    "allowed_hours": {
                                        "type": "string",
                                        "description": "Comma-separated hours/ranges (0-23) this script may be scheduled within"
                                    },
                                    "required_options": {
                                        "type": "array",
                                        "description": "Long option names that must have a value in this script's command",
                                        "items": {
                                            "type": "string"
                                        }
                                    }
                                }
                            }
```

- [ ] **Step 3: Manually verify against a running KTD instance**

With the same temporary `script_policy` setting from Task 3's manual verification (or set a fresh one), `GET /api/v1/contrib/crontab/scripts/details?name=longoverdue.pl` and confirm: the `lost` option in the `options` array now has `"required": true`, every other option has `"required": false`, and `policy.required_options` contains `["lost"]`. Then `GET /api/v1/contrib/crontab/scripts/details?name=longoverdue.pl&bypass_filter=1` for a script with no policy entry at all and confirm it now returns `200` (not `404`) with `policy: {}` and all options `required: false`.

- [ ] **Step 4: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Scripts.pm \
        Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json
git commit -m "feat: compute option required flag from script policy, add bypass_filter to script details"
```

---

### Task 5: Client-side required-field check in the job builder

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt` (`buildCommandFromParams`)

**Interfaces:**
- Consumes: `currentScriptData.options` (existing module-scoped variable, populated by `loadScriptDetails`; each option now has an accurate `required` boolean per Task 4).
- Produces: `buildCommandFromParams()` now blocks (via `showMessage(..., 'danger')`, without setting `#job-command`) when a required option has no value among the collected `params`, instead of silently building an incomplete command.

No automated test — no JS test harness exists in this repo (confirmed in `CLAUDE.md`). Verified manually in Step 2.

- [ ] **Step 1: Add the pre-flight check**

In `crontab.tt`, `buildCommandFromParams`, locate:

```javascript
            let fullCommand = basePath;
            if (params.length > 0) {
                fullCommand += ' ' + params.join(' ');
            }
```

Replace with:

```javascript
            let missingRequired = (currentScriptData && currentScriptData.options ? currentScriptData.options : [])
                .filter(function(option) { return option.required; })
                .filter(function(option) {
                    let prefix = '--' + option.name;
                    return !params.some(function(p) { return p === prefix || p.indexOf(prefix + '=') === 0; });
                });

            if (missingRequired.length > 0) {
                let names = missingRequired.map(function(o) { return '--' + o.name; }).join(', ');
                showMessage('Missing required option(s): ' + names, 'danger');
                return;
            }

            let fullCommand = basePath;
            if (params.length > 0) {
                fullCommand += ' ' + params.join(' ');
            }
```

- [ ] **Step 2: Manually verify against a running KTD instance**

Using the same temporary `script_policy` setting that marks `longoverdue.pl`'s `lost` option required (from Task 3/4's manual verification):

1. In the staff UI, open the job add form, pick `longoverdue.pl`, leave the "lost" field blank, fill in an unrelated optional field, and click "Build Command". Confirm a red `showMessage` appears reading "Missing required option(s): --lost" and `#job-command` is left unchanged (or empty).
2. Fill in the "lost" field and click "Build Command" again. Confirm it now succeeds and the command appears in the field, including `--lost=...`.
3. Pick a script with no required options at all and confirm "Build Command" behaves exactly as before (no regression for the common case).

- [ ] **Step 3: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt
git commit -m "feat: block command builder on missing required options"
```

---

### Task 6: `configure.tt` required-options checkbox editor, CHANGELOG entry, final verification

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/configure.tt`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `GET /api/v1/contrib/crontab/scripts/details?name=<name>&bypass_filter=1` (Task 4) for a given exact selected script's parsed `options` array; `serverPolicy[path].required_options` (already present in the `server_policy` JSON the plugin's `configure()` action already serializes, since it comes from `get_server_policy()` → `_load_policy_source` → Task 1's `required_options` field, with no `Crontab.pm` changes needed).
- Produces: each exact selected script's policy panel gains a checkbox per non-boolean, non-incremental detected option; checking one adds it to `libraryPolicyState[path].required_options`; on submit, the JSON payload written to the `script_policy` hidden field includes `required_options` per script alongside `non_repeatable`/`allowed_hours`.

No automated test — no JS test harness exists in this repo. Verified manually in Step 3.

- [ ] **Step 1: Cache script options and extend `renderPolicyPanels` to fetch and render required-option checkboxes**

In `configure.tt`, locate:

```javascript
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
```

Replace with:

```javascript
                function isExactScript(path) {
                    return allScripts.some(function(candidate) {
                        let relative = candidate.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, '');
                        return relative === path || candidate.name === path;
                    });
                }

                function emptyLibraryState() {
                    return { non_repeatable: false, allowed_hours: '', required_options: [] };
                }

                let scriptOptionsCache = {};

                function fetchMissingScriptOptions(paths, callback) {
                    let toFetch = paths.filter(function(path) {
                        return !scriptOptionsCache.hasOwnProperty(path);
                    });

                    if (!toFetch.length) {
                        callback();
                        return;
                    }

                    let requests = toFetch.map(function(path) {
                        let match = allScripts.find(function(s) {
                            let relative = s.relative_path.replace(/^\$KOHA_CRON_PATH\/?/, '');
                            return relative === path || s.name === path;
                        });

                        if (!match || match.type !== 'perl') {
                            scriptOptionsCache[path] = [];
                            return $.Deferred().resolve().promise();
                        }

                        return $.ajax({
                            url: '/api/v1/contrib/crontab/scripts/details',
                            method: 'GET',
                            data: { name: match.name, bypass_filter: 1 }
                        }).done(function(data) {
                            scriptOptionsCache[path] = (data.options || []).filter(function(o) {
                                return o.type !== 'boolean' && o.type !== 'incremental';
                            });
                        }).fail(function() {
                            scriptOptionsCache[path] = [];
                        });
                    });

                    $.when.apply($, requests).always(callback);
                }

                function renderPolicyPanels() {
                    let selected = ($("#script_picker").val() || []).filter(isExactScript);
                    fetchMissingScriptOptions(selected, function() {
                        renderPolicyPanelsNow(selected);
                    });
                }

                function renderPolicyPanelsNow(selected) {
                    let container = $("#script_policy_panels");
                    container.empty();

                    selected.forEach(function(path) {
                        let serverEntry = serverPolicy[path] || {};
                        let state = libraryPolicyState[path] || emptyLibraryState();
                        let locked = !!serverEntry.non_repeatable;
                        let nonRepeatable = locked || state.non_repeatable;
                        let hoursLocked = !!serverEntry.allowed_hours;
                        let allowedHours = hoursLocked ? serverEntry.allowed_hours : state.allowed_hours;
                        let serverRequired = serverEntry.required_options || [];
                        let libraryRequired = state.required_options || [];
                        let scriptOptions = scriptOptionsCache[path] || [];

                        let requiredHtml = '';
                        if (scriptOptions.length) {
                            requiredHtml = '<div class="form-group d-block mt-2"><label class="d-block">Required options:</label>';
                            scriptOptions.forEach(function(option) {
                                let isServerRequired = serverRequired.indexOf(option.name) !== -1;
                                let checked = isServerRequired || libraryRequired.indexOf(option.name) !== -1;
                                requiredHtml +=
                                    '<div class="form-check form-check-inline">' +
                                        '<input class="form-check-input policy-required-option" type="checkbox" data-path="' + escape_str(path) + '" data-option="' + escape_str(option.name) + '"' +
                                            (checked ? ' checked' : '') + (isServerRequired ? ' disabled' : '') + '>' +
                                        '<label class="form-check-label">--' + escape_str(option.name) + (isServerRequired ? ' (set by server administrator)' : '') + '</label>' +
                                    '</div>';
                            });
                            requiredHtml += '</div>';
                        }

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
                                    requiredHtml +
                                '</div>' +
                            '</div>'
                        );

                        container.append(panel);
                    });

                    container.find('.policy-non-repeatable').on('change', function() {
                        let path = $(this).data('path');
                        libraryPolicyState[path] = libraryPolicyState[path] || emptyLibraryState();
                        libraryPolicyState[path].non_repeatable = $(this).is(':checked');
                    });

                    container.find('.policy-allowed-hours').on('input', function() {
                        let path = $(this).data('path');
                        libraryPolicyState[path] = libraryPolicyState[path] || emptyLibraryState();
                        libraryPolicyState[path].allowed_hours = $(this).val();
                    });

                    container.find('.policy-required-option').on('change', function() {
                        let path = $(this).data('path');
                        let optionName = $(this).data('option');
                        libraryPolicyState[path] = libraryPolicyState[path] || emptyLibraryState();
                        let list = libraryPolicyState[path].required_options || [];
                        if ($(this).is(':checked')) {
                            if (list.indexOf(optionName) === -1) list.push(optionName);
                        } else {
                            list = list.filter(function(n) { return n !== optionName; });
                        }
                        libraryPolicyState[path].required_options = list;
                    });
                }
```

- [ ] **Step 2: Load existing `required_options` and include them in the submitted payload**

In `configure.tt`, locate:

```javascript
                    (existingPolicy.scripts || []).forEach(function(entry) {
                        libraryPolicyState[entry.path] = {
                            non_repeatable: !!entry.non_repeatable,
                            allowed_hours: entry.allowed_hours || ''
                        };
```

Replace with:

```javascript
                    (existingPolicy.scripts || []).forEach(function(entry) {
                        libraryPolicyState[entry.path] = {
                            non_repeatable: !!entry.non_repeatable,
                            allowed_hours: entry.allowed_hours || '',
                            required_options: entry.required_options || []
                        };
```

Then locate:

```javascript
                    let scriptsPayload = selectedScripts.map(function(path) {
                        let state = libraryPolicyState[path] || { non_repeatable: false, allowed_hours: '' };
                        let exact = isExactScript(path);
                        return {
                            path: path,
                            non_repeatable: exact ? !!state.non_repeatable : false,
                            allowed_hours: exact ? ( state.allowed_hours || '' ) : ''
                        };
                    });
```

Replace with:

```javascript
                    let scriptsPayload = selectedScripts.map(function(path) {
                        let state = libraryPolicyState[path] || emptyLibraryState();
                        let exact = isExactScript(path);
                        return {
                            path: path,
                            non_repeatable: exact ? !!state.non_repeatable : false,
                            allowed_hours: exact ? ( state.allowed_hours || '' ) : '',
                            required_options: exact ? ( state.required_options || [] ) : []
                        };
                    });
```

- [ ] **Step 3: Manually verify against a running KTD instance**

Start (or reuse) a KTD instance for this plugin (`kd up`) and, on the plugin's configure page:

1. Add `longoverdue.pl` to the script picker. Confirm its policy panel now shows a "Required options" row with a checkbox per non-boolean option (`lost`, `charge`, `maxdays`, `category`, `skip-category`, `library`, `skip-library`, `itemtype`, `skip-itemtype`, `skip-lost-value`) and none checked yet.
2. Check the `lost` checkbox and click Save. Reload the configure page, re-add `longoverdue.pl` (or confirm it's still selected), and confirm `lost` is now pre-checked.
3. Set a server-file policy (via a koha-conf.xml `koha_plugin_crontab_script_policy` entry pointing at a YAML file with `required_options: ["lost"]` for `misc/cronjobs/longoverdue.pl`) and reload the configure page. Confirm the `lost` checkbox now renders checked and disabled with "(set by server administrator)", and that unchecking is not possible.
4. Confirm a directory-prefix entry (e.g. `batch/`) never shows a required-options row (no exact script to fetch option data for).
5. Save with a required option checked, then use the staff UI job builder against that script to confirm end-to-end: the option's asterisk appears, the client-side check from Task 5 blocks an empty submission, and the server-side check from Task 3 blocks a raw API call bypassing the UI.

- [ ] **Step 4: Add the CHANGELOG entry**

In `CHANGELOG.md`, locate:

```markdown
## [Unreleased]

### Fixed
- `GET /scripts/details` returning a 500 for any script without a script policy attached, breaking the script picker's parameter builder for most scripts

### Added
- Script policy: mark individual allowed scripts as non-repeatable (only one scheduled instance at a time) or restricted to specific hours of the day
```

Replace with:

```markdown
## [Unreleased]

### Fixed
- `GET /scripts/details` returning a 500 for any script without a script policy attached, breaking the script picker's parameter builder for most scripts
- Script options were marked "required" based on Getopt::Long's `=`/`:` syntax, which only indicates whether a value is needed *if* the flag is used, not whether the flag itself is mandatory — this produced both false positives (options flagged required that scripts treat as optional) and an unenforced true positive (a genuinely mandatory option could still be saved blank). Required-ness is now driven entirely by an explicit `required_options` script policy field, curated by administrators and enforced both client- and server-side.

### Added
- Script policy: mark individual allowed scripts as non-repeatable (only one scheduled instance at a time), restricted to specific hours of the day, or as requiring specific command-line options to have a value before a job can be saved
```

- [ ] **Step 5: Run the full test suite**

Run: `prove -v t/00-load.t t/01-cron-hour-expansion.t t/02-script-policy-parsing.t t/03-script-policy-enforcement.t t/04-script-policy-migration.t`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/configure.tt CHANGELOG.md
git commit -m "feat: add required-options policy editor to configure page"
```
