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
