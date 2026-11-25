use Modern::Perl;
use Test::More tests => 6;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

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

# A script that declares its options with describe_options and requires none of
# them itself, like runreport.pl: an administrator can still require one
my $cron_dir = tempdir( CLEANUP => 1 );
open my $fh, '>', "$cron_dir/report.pl" or die $!;
print {$fh} <<'PERL';
#!/usr/bin/perl
my $opt = Koha::Script->describe_options(
    'Run reports.

%c %o reportID',
    [ 'to=s',      'email address to send the report to' ],
    [ 'verbose|v', 'verbose output' ],
    { args => { min => 1, name => 'reportID' } },
);
PERL
close $fh;

my $ct        = Config::Crontab->new();
my $env_block = Config::Crontab::Block->new();
$env_block->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $cron_dir ) ] );
$ct->last($env_block);

my $with_policy = sub {
    my ($yaml) = @_;
    Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new( $ct, FakePlugin->new($yaml) ) } );
};

my $plain = $with_policy->("scripts:\n  - path: report.pl\n");
my $v     = $plain->validate_command('$KOHA_CRON_PATH/report.pl 1');
is( $v->{valid}, 1, 'the script is permitted' );
ok( !( $v->{policy} && @{ $v->{policy}{required_options} || [] } ), 'it requires no options of its own' );

my $strict = $with_policy->("scripts:\n  - path: report.pl\n    required_options:\n      - to\n");
$v = $strict->validate_command('$KOHA_CRON_PATH/report.pl 1');
is_deeply( $v->{policy}{required_options}, ['to'], 'an option the library requires is part of the policy even though the script declares its options itself' );

ok( !$strict->check_required_options( $v->{policy}{required_options}, '$KOHA_CRON_PATH/report.pl 1', 'report.pl' )->{valid}, 'a job without it is refused' );
ok( $strict->check_required_options( $v->{policy}{required_options}, '$KOHA_CRON_PATH/report.pl --to a@example.org 1', 'report.pl' )->{valid}, 'a job with it is accepted' );
