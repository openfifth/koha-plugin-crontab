use Modern::Perl;
use Test::More tests => 5;
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

# A describe_options-based script declaring hours as required, with NO
# script_policy entry configured anywhere -- validate_command must still
# surface it as a required option, since script-declared required-ness is
# a floor policy can only add to, not something an admin has to opt into
# before it's enforced (unlike non_repeatable/allowed_hours, which stay
# purely policy-driven).
open my $fh, '>', "$cron_dir/cart_to_shelf.pl" or die "Cannot create fixture script: $!";
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

my $script_model =
  Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new($ct) } );

my $result = $script_model->validate_command("\$KOHA_CRON_PATH/cart_to_shelf.pl --hours 24");
is( $result->{valid}, 1, 'command validates against the approved script list' );
ok( $result->{policy}, 'a policy is surfaced even though no script_policy entry was ever configured' );
is_deeply( $result->{policy}{required_options}, ['hours'], 'the script-declared required option is surfaced' );

# A plain-GetOptions script with no policy entry: nothing to surface,
# behavior must stay exactly as before this change (no policy key at all).
open my $fh2, '>', "$cron_dir/legacy.pl" or die "Cannot create fixture script: $!";
print $fh2 "#!/usr/bin/perl\nuse Getopt::Long qw( GetOptions );\nGetOptions( 'h|hours=s' => \\my \$hours );\n";
close $fh2;

my $legacy_result = $script_model->validate_command("\$KOHA_CRON_PATH/legacy.pl --hours 24");
is( $legacy_result->{policy}, undef, 'a plain-GetOptions script with no policy entry still surfaces no policy at all' );
