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
