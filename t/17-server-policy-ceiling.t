use Modern::Perl;
use Test::More;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

package FakePlugin;
sub new           { bless { p => $_[1] }, $_[0] }
sub retrieve_data { $_[0]{p} }
package FakeCrontab;
sub new  { bless { ct => $_[1], plugin => $_[2] }, $_[0] }
sub read { $_[0]{ct} }
package main;

my $dir = tempdir( CLEANUP => 1 );
for my $f (qw(approved.pl dangerous.pl other.pl)) {
    open my $fh, '>', "$dir/$f" or die $!;
    print {$fh} "#!/usr/bin/perl\n";
    close $fh;
}
mkdir "$dir/batch";
open my $bfh, '>', "$dir/batch/nightly.pl" or die $!;
print {$bfh} "#!/usr/bin/perl\n";
close $bfh;

my $ct = Config::Crontab->new();
my $b  = Config::Crontab::Block->new();
$b->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $dir ) ] );
$ct->last($b);

sub model {
    my ( $library, $server ) = @_;
    my $m = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new( $ct, FakePlugin->new($library) ) } );
    no warnings 'redefine';
    *Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script::_server_policy_text = sub { $server };
    return $m;
}
sub names { join ',', map { $_->{name} } @{ $_[0]->get_available_scripts } }

my $server = "scripts:\n  - path: approved.pl\n    non_repeatable: true\n    allowed_hours: '1-5'\n    required_options: [x]\n";

# --- the server policy is a ceiling that holds ------------------------------
is( names( model( undef,           $server ) ), 'approved.pl', 'server policy, library never configured: only the server scripts' );
is( names( model( "scripts: []\n", $server ) ), 'approved.pl', 'server policy, library cleared: still only the server scripts' );
is( names( model( "scripts:\n  - path: approved.pl\n", $server ) ), 'approved.pl', 'library selecting a server script: that script' );
is( names( model( "scripts:\n  - path: dangerous.pl\n", $server ) ), '', 'library selecting only a script the server does not list: nothing, not everything' );
is( names( model( "scripts:\n  - path: approved.pl\n  - path: dangerous.pl\n", $server ) ), 'approved.pl', 'library cannot add scripts beyond the server policy' );
is( names( model( "not: yaml: [", $server ) ), 'approved.pl', 'an unparseable library policy leaves the server policy in force' );

# --- the server's constraints apply when the library tier is silent -----------
my ($inherited) = @{ model( undef, $server )->get_available_scripts };
is( $inherited->{policy}{non_repeatable},   1,     'inherited: non_repeatable from the server policy' );
is( $inherited->{policy}{allowed_hours},    '1-5', 'inherited: allowed_hours from the server policy' );
is_deeply( $inherited->{policy}{required_options}, ['x'], 'inherited: required_options from the server policy' );

# --- validate_command goes through the same gate ---------------------------------
my $m = model( undef, $server );
ok(  $m->validate_command('$KOHA_CRON_PATH/approved.pl --x 1')->{valid},  'validate_command: a server-approved script' );
ok( !$m->validate_command('$KOHA_CRON_PATH/dangerous.pl')->{valid},       'validate_command: a script outside the server policy is refused' );
ok( !$m->validate_command('$KOHA_CRON_PATH/other.pl')->{valid},           'validate_command: another unlisted script is refused' );
$m = model( "scripts:\n  - path: dangerous.pl\n", $server );
ok( !$m->validate_command('$KOHA_CRON_PATH/dangerous.pl')->{valid},       'validate_command: a library entry cannot widen the server policy' );

# --- directory entries -----------------------------------------------------------
my $dir_server = "scripts:\n  - path: batch/\n";
is( names( model( undef, $dir_server ) ), 'nightly.pl', 'a server directory entry offers the scripts under it' );

# --- no server policy: the library tier governs ---------------------------------
is( names( model( "scripts:\n  - path: approved.pl\n", undef ) ), 'approved.pl', 'no server policy: library policy limits scripts' );

# --- an empty policy means no scripts, never all of them -----------------------------
is( names( model( undef, undef ) ),         '', 'nothing configured anywhere: no scripts' );
is( names( model( "scripts: []\n", undef ) ), '', 'library policy cleared, no server policy: no scripts' );
is( names( model( "", undef ) ),            '', 'blank library policy: no scripts' );
is( names( model( "not: yaml: [", undef ) ), '', 'unparseable library policy: no scripts' );

my $closed = model( undef, undef );
my $refused = $closed->validate_command('$KOHA_CRON_PATH/approved.pl');
ok( !$refused->{valid}, 'validate_command: refused when no policy permits anything' );
like( $refused->{error}, qr/No scripts are permitted yet.*Configure.*server policy file/s, '  ...with an actionable message' );

my $other = model( "scripts:\n  - path: approved.pl\n", undef )->validate_command('$KOHA_CRON_PATH/other.pl');
ok( !$other->{valid}, 'validate_command: an unlisted script is refused' );
like( $other->{error}, qr/approved list/, '  ...with the usual message, since some scripts are permitted' );

# the Configure page still needs to see every script in order to choose from them
is( join( ',', map { $_->{name} } @{ $closed->get_available_scripts( { bypass_filter => 1 } ) } ), 'approved.pl,dangerous.pl,nightly.pl,other.pl', 'bypass_filter still lists every script for the Configure page' );

# --- tier merging unit checks ------------------------------------------------------------
my $s = model( undef, undef );
is_deeply( $s->_merge_policy_tiers( [ { path => 'a.pl' } ], [] ), [ { path => 'a.pl' } ], 'merge: server with an empty library inherits the server entries' );
is_deeply( $s->_merge_policy_tiers( [],                [ { path => 'a.pl' } ] ), [ { path => 'a.pl' } ], 'merge: library with no server is unchanged' );
is_deeply( $s->_merge_policy_tiers( [ { path => 'a.pl' } ], [ { path => 'b.pl' } ] ), [], 'merge: disjoint tiers leave nothing' );

done_testing();
