use Modern::Perl;
use Test::More tests => 8;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

# The server policy file in this test: allowed.pl only
my $server_yaml = "scripts:\n  - path: allowed.pl\n";
{
    no warnings 'redefine';
    *Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script::_server_policy_text = sub { return $server_yaml };
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
    { crontab => FakeCrontab->new( $ct, FakePlugin->new('') ) } );

sub names { join ',', map { $_->{name} } @{ $_[0] } }

is( names( $script->get_available_scripts( { bypass_filter => 1 } ) ), 'allowed.pl', 'the Configure listing is limited to what the server permits by default' );

my $all = $script->get_available_scripts( { bypass_filter => 1, include_restricted => 1 } );
is( names($all), 'allowed.pl,other.pl', 'include_restricted also lists what the server leaves out' );
ok( !$all->[0]{server_restricted}, 'a permitted script is not marked' );
ok( $all->[1]{server_restricted},  'a script the server leaves out is marked server_restricted' );

# Only the Configure listing may ask for this: enforcement is unchanged
is( names( $script->get_available_scripts( { include_restricted => 1 } ) ), 'allowed.pl', 'include_restricted does nothing without bypass_filter: the server policy still applies' );
is( $script->permits('$KOHA_CRON_PATH/other.pl'), 0, 'a script the server leaves out still cannot be scheduled' );

# With no server policy, nothing is marked
$server_yaml = '';
my $open = $script->get_available_scripts( { bypass_filter => 1, include_restricted => 1 } );
is( scalar( grep { $_->{server_restricted} } @$open ), 0, 'without a server policy nothing is marked restricted' );
