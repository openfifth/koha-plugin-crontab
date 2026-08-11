use Modern::Perl;
use Test::More tests => 12;
use Scalar::Util qw(refaddr);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
require Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job;

ok(1, 'modules loaded successfully');

my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => {} } );

my $ct = Config::Crontab->new();

my $block1 = Config::Crontab::Block->new();
$block1->lines(
    [
        Config::Crontab::Comment->new( -data => '# Nightly backup' ),
        Config::Crontab::Event->new( -datetime => '0 2 * * *', -command => '/usr/local/bin/backup.sh' ),
    ]
);
$ct->last($block1);

my $block2 = Config::Crontab::Block->new();
my $finegen_event = Config::Crontab::Event->new( -datetime => '0 3 * * *', -command => '$KOHA_CRON_PATH/finegen.pl' );
my $overdue_event = Config::Crontab::Event->new( -datetime => '0 4 * * *', -command => '$KOHA_CRON_PATH/overdue_notices.pl' );
$block2->lines(
    [
        Config::Crontab::Comment->new( -data => '# Ansible managed group' ),
        $finegen_event,
        $overdue_event,
    ]
);
$ct->last($block2);

my $block3 = Config::Crontab::Block->new();
$block3->lines(
    [
        Config::Crontab::Comment->new( -data => '# @crontab-manager-id: existing-job-uuid' ),
        Config::Crontab::Comment->new( -data => '# @managed-by: koha-crontab-plugin' ),
        Config::Crontab::Event->new( -datetime => '0 5 * * *', -command => '$KOHA_CRON_PATH/membership_expiry.pl' ),
    ]
);
$ct->last($block3);

# find_unmanaged_entry

my ( $found_block, $found_event ) =
  $job->find_unmanaged_entry( $ct, '0 2 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup'] );
ok( refaddr($found_block) == refaddr($block1), 'finds the single-event block' );
is( $found_event->command, '/usr/local/bin/backup.sh', 'returns the matching event' );

my ( $group_block, $group_event ) =
  $job->find_unmanaged_entry( $ct, '0 3 * * *', '$KOHA_CRON_PATH/finegen.pl', ['# Ansible managed group'] );
ok( refaddr($group_block) == refaddr($block2), 'finds the right block within a multi-event group' );
is( $group_event->command, '$KOHA_CRON_PATH/finegen.pl', 'finds the right event within a multi-event group' );

my @no_match = $job->find_unmanaged_entry( $ct, '0 2 * * *', '/usr/local/bin/backup.sh', ['# Wrong comment'] );
is( scalar(@no_match), 0, 'does not match when comments differ' );

my @managed_no_match =
  $job->find_unmanaged_entry( $ct, '0 5 * * *', '$KOHA_CRON_PATH/membership_expiry.pl',
    [ '# @crontab-manager-id: existing-job-uuid', '# @managed-by: koha-crontab-plugin' ] );
is( scalar(@managed_no_match), 0, 'never matches an already-managed block' );

# entry_matches

ok(
    $job->entry_matches(
        { schedule => '0 2 * * *', command => '/usr/local/bin/backup.sh', comments => ['# Nightly backup'] },
        '0 2 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup']
    ),
    'entry_matches is true for an identical entry'
);
ok(
    !$job->entry_matches(
        { schedule => '0 2 * * *', command => '/usr/local/bin/backup.sh', comments => ['# Nightly backup'] },
        '0 9 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup']
    ),
    'entry_matches is false when the schedule differs'
);

# extract_event_from_block

$job->extract_event_from_block( $ct, $block1, $found_event );
is( scalar( grep { refaddr($_) == refaddr($block1) } $ct->blocks ), 0, 'removes the whole block when it held only one event' );

$job->extract_event_from_block( $ct, $block2, $finegen_event );
my @remaining_events = $block2->select( -type => 'event' );
is( scalar(@remaining_events), 1, 'leaves the sibling event in place' );
is( $remaining_events[0]->command, '$KOHA_CRON_PATH/overdue_notices.pl', 'the surviving event is the correct sibling' );
