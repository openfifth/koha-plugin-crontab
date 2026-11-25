use Modern::Perl;
use Test::More tests => 8;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

# Hermetic: ignore any server policy file the instance's koha-conf.xml configures
{
    no warnings 'redefine';
    *Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script::_server_policy_text = sub { return };
}

package FakePlugin;
sub new           { my ( $class, $policy ) = @_; return bless { policy => $policy }, $class; }
sub retrieve_data { $_[0]{policy} }
package FakeCrontab;
sub new  { my ( $class, $ct, $plugin ) = @_; return bless { ct => $ct, plugin => $plugin }, $class; }
sub read { $_[0]{ct} }
package main;

my $cron_dir = tempdir( CLEANUP => 1 );
for my $name (qw(allowed.pl other.pl)) {
    open my $fh, '>', "$cron_dir/$name" or die $!;
    print {$fh} "#!/usr/bin/perl\n";
    close $fh;
}

my $ct        = Config::Crontab->new();
my $env_block = Config::Crontab::Block->new();
$env_block->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $cron_dir ) ] );
$ct->last($env_block);

my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
    { crontab => FakeCrontab->new( $ct, FakePlugin->new("scripts:\n  - path: allowed.pl\n") ) } );

# Which system entries the UI offers "Migrate" for: only permitted scripts
is( $script->permits('$KOHA_CRON_PATH/allowed.pl'),          1, 'a permitted script, in the form the plugin writes' );
is( $script->permits("$cron_dir/allowed.pl --verbose"),      1, 'a permitted script by absolute path with arguments, as system entries are written' );
is( $script->permits('$KOHA_CRON_PATH/other.pl'),            0, 'a script that exists but is not on the policy' );
is( $script->permits('/usr/local/bin/backup.sh'),            0, 'a command that is not a Koha script at all' );
is( $script->permits('$KOHA_CRON_PATH/allowed.pl; rm -rf /'), 0, 'a permitted script chained with other shell is not' );

my $none = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
    { crontab => FakeCrontab->new( $ct, FakePlugin->new('') ) } );
is( $none->permits('$KOHA_CRON_PATH/allowed.pl'), 0, 'with an empty policy nothing can be migrated' );

# Many commands against one scan of the scripts give the same answers
my $available = $script->get_available_scripts();
is_deeply(
    [ map { $script->permits( $_, $available ) } ( '$KOHA_CRON_PATH/allowed.pl', '$KOHA_CRON_PATH/other.pl', '/usr/local/bin/backup.sh' ) ],
    [ 1, 0, 0 ],
    'passing an already-found list of scripts gives the same answers'
);
