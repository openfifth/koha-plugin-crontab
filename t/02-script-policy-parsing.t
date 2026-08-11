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
