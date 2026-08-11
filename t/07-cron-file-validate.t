use Modern::Perl;
use Test::More tests => 4;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::File');

# Minimal stand-in for the plugin object: Cron::File::new() only ever calls
# ->mbf_dir() (to locate its backup directory) and, elsewhere, retrieve_data().
package FakePlugin;
sub new           { return bless {}, shift; }
sub mbf_dir       { return File::Temp::tempdir( CLEANUP => 1 ); }
sub retrieve_data { return undef; }
package main;

my $crontab =
  Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => FakePlugin->new } );

sub block_for {
    my ($datetime) = @_;
    my $ct    = Config::Crontab->new();
    my $block = Config::Crontab::Block->new();
    $block->lines(
        [ Config::Crontab::Event->new( -datetime => $datetime, -command => '$KOHA_CRON_PATH/runreport.pl' ) ] );
    $ct->last($block);
    return $ct;
}

# Regression test: a customer-entered schedule using a 3-letter day-of-week
# name caused job creation to fail with a 500 error, because this method's
# own field-character check was stricter than the underlying Config::Crontab
# parser (which accepts day/month name abbreviations - see RE_DM/RE_DTMOY/
# RE_DTDOW in lib/Config/Crontab.pm).
ok( $crontab->validate( block_for('5 4 * * Mon') ), 'accepts a schedule using a day-of-week name (Mon)' );
ok( $crontab->validate( block_for('0 0 1 Jan *') ), 'accepts a schedule using a month name (Jan)' );
ok( $crontab->validate( block_for('*/5 * * * *') ), 'still accepts a plain numeric schedule' );
