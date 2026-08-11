use Modern::Perl;
use Test::More tests => 4;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

# Minimal stand-in for Cron::File: get_available_scripts() only ever calls
# ->read() on the crontab instance it is given.
package FakeCrontab;
sub new  { my ( $class, $ct ) = @_; return bless { ct => $ct }, $class; }
sub read { my ($self) = @_; return $self->{ct}; }
package main;

my $cron_dir = tempdir( CLEANUP => 1 );
open my $fh, '>', "$cron_dir/runreport.pl" or die "Cannot create fixture script: $!";
print $fh "#!/usr/bin/perl\n";
close $fh;

my $ct        = Config::Crontab->new();
my $env_block = Config::Crontab::Block->new();
$env_block->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $cron_dir ) ] );
$ct->last($env_block);

my $script_model =
  Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new($ct) } );

# This is how the plugin itself writes commands for newly-created jobs.
my $relative_result =
  $script_model->validate_command("\$KOHA_CRON_PATH/runreport.pl --format=csv");
is( $relative_result->{valid}, 1, 'matches the $KOHA_CRON_PATH-relative form' );

# This is how pre-existing/system crontab entries typically reference a
# script (as encountered when migrating a system job into the plugin) -
# regression test for the "Command must use a script from the approved
# list" bug reported against the migrate feature.
my $absolute_result =
  $script_model->validate_command("$cron_dir/runreport.pl --format=csv");
is( $absolute_result->{valid}, 1, 'matches the raw absolute path form' );
is(
    $absolute_result->{script}{name},
    'runreport.pl',
    'resolves to the same script regardless of which form was used'
);
