use Modern::Perl;
use Test::More tests => 16;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );

# Verbatim from misc/cronjobs/cart_to_shelf.pl (Koha core bug 43546's proof
# of concept): a single, genuinely required named option, no positional args.
my $cart_to_shelf_content = <<'PERL';
my $opt = Koha::Script->describe_options(
    'Set any item with a location of CART back to its original shelving location once the given number of hours have passed.

%c %o',
    [
        'hours|h=i', 'hours that need to pass before an item is returned to its original shelving location',
        { required => 1 }
    ],
    {
        epilog =>
            "Examples:\n  %c --hours 24\n    Move any item that has been on the cart for more than 24 hours back to its original shelving location.\n",
    },
);
PERL

my ( $cart_options, $cart_positional ) = $script->_parse_describe_options_block($cart_to_shelf_content);

is( scalar @$cart_options, 1, 'cart_to_shelf.pl: exactly one option found' );
is( $cart_options->[0]{name},     'hours', 'cart_to_shelf.pl: option name is "hours"' );
is( $cart_options->[0]{required}, 1,       'cart_to_shelf.pl: hours is required' );
is( $cart_positional, undef, 'cart_to_shelf.pl: no positional-argument requirement declared' );

# Synthetic (not copied from any real script) but deliberately styled after
# runreport.pl's shape, to exercise the tricky bits a naive parser gets
# wrong: a description containing an internal comma, a description with a
# nested double-quoted string inside single quotes, an array-typed default,
# a multi-line format string, and a trailing args => {...} block alongside
# epilog in the same hashref.
my $multi_option_content = <<'PERL';
my ( $opt, $usage ) = Koha::Script->describe_options(
    'Run one or more saved reports, optionally emailing the output.

%c %o reportID [ reportID ... ]',
    [ 'verbose|v', 'verbose output' ],
    [ 'format=s', 'output format: text, html, csv, or tsv', { default => 'text' } ],
    [ 'method:s', 'authentication method to pass to the SMTP server, e.g. LOGIN, DIGEST-MD5' ],
    [ 'subject=s', 'subject for the email (defaults to the report name, or "Koha Saved Report")' ],
    [ 'param=s@', 'parameter for the report; repeat for multiple parameters', { default => [] } ],
    {
        epilog => "Examples:\n  %c 16\n    Run report #16.\n",
        args   => { min => 1, name => 'reportID', variadic => 1 },
    },
);
PERL

my ( $multi_options, $multi_positional ) = $script->_parse_describe_options_block($multi_option_content);

is( scalar @$multi_options, 5, 'multi-option fixture: all five options found despite tricky descriptions' );
is_deeply(
    [ map { $_->{name} } @$multi_options ],
    [ 'verbose', 'format', 'method', 'subject', 'param' ],
    'multi-option fixture: option names extracted in order, unaffected by internal commas/quotes'
);
is_deeply(
    [ map { $_->{required} } @$multi_options ],
    [ 0, 0, 0, 0, 0 ],
    'multi-option fixture: none of these are required (matches runreport.pl\'s real behavior)'
);
is_deeply(
    $multi_positional,
    { min => 1, name => 'reportID', variadic => 1 },
    'multi-option fixture: positional-argument requirement extracted from the trailing args block'
);

# Dispatch-level tests: parse_script_options($path) must pick the right
# block parser based on script content, without changing behavior for
# plain-GetOptions scripts. positional_args stays an arrayref at this
# level either way (0 or 1 entries), matching what existing consumers
# (Scripts.pm, crontab.tt) already expect from _detect_argv_usage today.

my $dir = tempdir( CLEANUP => 1 );

# A script using the new convention, with a declared positional requirement.
open my $fh1, '>', "$dir/converted.pl" or die $!;
print $fh1 "#!/usr/bin/perl\n$multi_option_content";
close $fh1;

my $converted_result = $script->parse_script_options("$dir/converted.pl");
is( $converted_result->{options}[0]{required}, 0, 'parse_script_options: dispatches to describe_options parsing for a converted script' );
is_deeply(
    $converted_result->{positional_args},
    [ { required => 1, min => 1, name => 'reportID', variadic => 1 } ],
    'parse_script_options: positional-argument requirement surfaced as a single required entry'
);

# A plain GetOptions script -- must be completely unaffected by this change:
# required is always 0/false, and positional_args must match exactly what
# _detect_argv_usage already returns today for the same content.
my $getoptions_content = "#!/usr/bin/perl\n" . <<'PERL';
use Getopt::Long qw( GetOptions );
my $hours = 0;
my $file  = shift @ARGV;
GetOptions( 'h|hours=s' => \$hours );
PERL

open my $fh2, '>', "$dir/legacy.pl" or die $!;
print $fh2 $getoptions_content;
close $fh2;

my $legacy_result       = $script->parse_script_options("$dir/legacy.pl");
my @expected_options    = $script->_parse_getoptions_block($getoptions_content);
my @expected_positional = $script->_detect_argv_usage( $getoptions_content, [ split /\n/, $getoptions_content ] );

is_deeply(
    [ map { $_->{name} } @{ $legacy_result->{options} } ],
    [ map { $_->{name} } @expected_options ],
    'parse_script_options: GetOptions-based script still parses the same option names as before'
);
is( ( grep { $_->{required} } @{ $legacy_result->{options} } ), 0,
    'parse_script_options: GetOptions-based options are never marked required' );
is_deeply(
    $legacy_result->{positional_args},
    \@expected_positional,
    'parse_script_options: GetOptions-based positional_args unchanged from the existing heuristic'
);

# A script with neither convention at all.
open my $fh3, '>', "$dir/empty.pl" or die $!;
print $fh3 "#!/usr/bin/perl\nprint \"hello\\n\";\n";
close $fh3;

my $empty_result = $script->parse_script_options("$dir/empty.pl");
is_deeply( $empty_result->{options}, [], 'parse_script_options: no options for a script with neither convention' );
is_deeply( $empty_result->{positional_args}, [], 'parse_script_options: no positional args for a script with neither convention' );
