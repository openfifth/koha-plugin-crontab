use Modern::Perl;
use Test::More tests => 5;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

# Hermetic: ignore any server policy file the test instance's koha-conf.xml
# happens to configure, so these tests only see the policy they set up.
{
    no warnings 'redefine';
    *Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script::_server_policy_text = sub { return };
}

# Minimal stand-in for Cron::File: get_available_scripts() only ever calls
# ->read() on the crontab instance it is given.
package FakePlugin;
sub new           { my ( $class, $policy ) = @_; return bless { policy => $policy }, $class; }
sub retrieve_data { $_[0]{policy} }
package FakeCrontab;
sub new  { my ( $class, $ct, $plugin ) = @_; return bless { ct => $ct, plugin => $plugin }, $class; }
sub read { my ($self) = @_; return $self->{ct}; }
package main;

my $cron_dir = tempdir( CLEANUP => 1 );
mkdir "$cron_dir/batch" or die "Cannot create fixture directory: $!";

# A describe_options-based script declaring hours as required, with NO
# script_policy entry configured anywhere -- validate_command must still
# surface it as a required option, since script-declared required-ness is
# a floor policy can only add to, not something an admin has to opt into
# before it's enforced (unlike non_repeatable/allowed_hours, which stay
# purely policy-driven).
open my $fh, '>', "$cron_dir/batch/cart_to_shelf.pl" or die "Cannot create fixture script: $!";
print $fh <<'PERL';
#!/usr/bin/perl
my $opt = Koha::Script->describe_options(
    'Move cart items back to their original shelving location.

%c %o',
    [ 'hours|h=i', 'hours since item was placed on the cart', { required => 1 } ],
);
PERL
close $fh;

my $ct        = Config::Crontab->new();
my $env_block = Config::Crontab::Block->new();
$env_block->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $cron_dir ) ] );
$ct->last($env_block);

# An empty policy permits no scripts, so the fixture scripts are permitted via a
# directory entry, so that neither has an exact policy entry of its own (what
# this test is about).
my $script_model =
  Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new( $ct, FakePlugin->new("scripts:\n  - path: batch/\n") ) } );

my $result = $script_model->validate_command("\$KOHA_CRON_PATH/batch/cart_to_shelf.pl --hours 24");
is( $result->{valid}, 1, 'command validates against the approved script list' );
ok( $result->{policy}, 'a policy is surfaced even though no script_policy entry was ever configured' );
is_deeply( $result->{policy}{required_options}, ['hours'], 'the script-declared required option is surfaced' );

# A plain-GetOptions script with no policy entry: nothing to surface,
# behavior must stay exactly as before this change (no policy key at all).
open my $fh2, '>', "$cron_dir/batch/legacy.pl" or die "Cannot create fixture script: $!";
print $fh2 "#!/usr/bin/perl\nuse Getopt::Long qw( GetOptions );\nGetOptions( 'h|hours=s' => \\my \$hours );\n";
close $fh2;

my $legacy_result = $script_model->validate_command("\$KOHA_CRON_PATH/batch/legacy.pl --hours 24");
is( $legacy_result->{policy}, undef, 'a plain-GetOptions script with no policy entry still surfaces no policy at all' );
