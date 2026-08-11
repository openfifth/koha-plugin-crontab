use Modern::Perl;
use Test::More tests => 16;
use File::Temp qw(tempfile);

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
