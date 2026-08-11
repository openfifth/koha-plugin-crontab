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
