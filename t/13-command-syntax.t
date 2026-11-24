use Modern::Perl;
use Test::More;
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

package FakePlugin;
sub new           { my ( $class, $policy ) = @_; return bless { policy => $policy }, $class; }
sub retrieve_data { $_[0]{policy} }
package FakeCrontab;
sub new  { my ( $class, $ct, $plugin ) = @_; return bless { ct => $ct, plugin => $plugin }, $class; }
sub read { $_[0]{ct} }
package main;

my $dir = tempdir( CLEANUP => 1 );
open my $fh, '>', "$dir/approved.pl" or die $!;
print {$fh} "#!/usr/bin/perl\n";
close $fh;

my $ct = Config::Crontab->new();
my $b  = Config::Crontab::Block->new();
$b->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $dir ) ] );
$ct->last($b);
# An empty policy permits no scripts, so the approved fixture script is listed.
my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new( $ct, FakePlugin->new("scripts:\n  - path: approved.pl\n") ) } );

my $p = '$KOHA_CRON_PATH/approved.pl';

# --- commands that must be accepted -------------------------------------
my @good = (
    "$p",
    "$p --hours 24",
    "$p --hours=24 -v",
    "$p --where \"borrowernumber > 5\" --name 'O Brien'",
    "$p --hours 24 >/dev/null 2>&1",
    "$p --hours 24 > /dev/null 2>&1",
    "$p --hours 24 >> /var/log/koha/cron.log 2>&1",
    "$p --hours 24 &> /dev/null",
    "$p --hours 24 2>\$KOHA_LOGS/err.log",
    "$p --dir \${KOHA_DIR}/out",
    $p . ' --fmt ' . chr(92) . ';',
    "$p --date \\%F",
    "$dir/approved.pl --hours 24",
    "$p < /dev/null",
);
for my $cmd (@good) {
    my $r = $script->validate_command($cmd);
    ok( $r->{valid}, "accepts: $cmd" ) or diag( $r->{error} );
}

# --- commands that must be rejected -------------------------------------
my %bad = (
    "$p --hours 24 ; touch /tmp/x"              => qr/';'/,
    "$p --hours 24 && touch /tmp/x"             => qr/'&'/,
    "$p --hours 24 || touch /tmp/x"             => qr/'\|'/,
    "$p --hours 24 | sh"                        => qr/'\|'/,
    "$p --hours 24 &"                           => qr/'&'/,
    "$p --hours \$(id)"                         => qr/substitution/,
    "$p --hours `id`"                           => qr/backtick/,
    "$p --hours \"\$(id)\""                     => qr/substitution/,
    "$p --hours \"`id`\""                       => qr/backtick/,
    "$p --hours \$1"                            => qr/substitution|expansion/,
    "$p --hours \${IFS:-x}"                     => qr/expansion/,
    "$p (id)"                                   => qr/subshell/,
    "$p <(id)"                                  => qr/process substitution/,
    "$p <<EOF"                                  => qr/here-document/,
    "$p >|/tmp/x"                               => qr/'\|'|target/,
    "$p --hours 24\n* * * * * touch /tmp/x"     => qr/single line/,
    "$p --hours 24\r* * * * * touch /tmp/x"     => qr/single line/,
    "$p --hours 24\0"                           => qr/single line/,
    "$p 'unterminated"                          => qr/unterminated/,
    "$p \"unterminated"                         => qr/unterminated/,
    "$p >"                                      => qr/target/,
    "$p trailing\\"                             => qr/backslash/,
    "touch /tmp/x"                              => qr/approved list/,
    "; touch /tmp/x"                            => qr/';'/,
    "\$(id) $p"                                 => qr/substitution/,
);
for my $cmd ( sort keys %bad ) {
    my $r = $script->validate_command($cmd);
    ( my $shown = $cmd ) =~ s/\n/\\n/g;
    $shown =~ s/\r/\\r/g;
    $shown =~ s/\0/\\0/g;
    ok( !$r->{valid}, "rejects: $shown" );
    like( $r->{error} // '', $bad{$cmd}, "  ...with a useful reason" );
}

# --- tokenizer details ---------------------------------------------------
my $t = $script->parse_command(q{a.pl --name 'x y' "p q" r\ s >/dev/null 2>&1});
is_deeply( $t->{words},     [ 'a.pl', '--name', 'x y', 'p q', 'r s' ], 'words: quotes/escapes resolved, redirections excluded' );
is_deeply( $t->{redirects}, [ '> /dev/null', '2>&1' ],                  'redirects captured separately' );

done_testing();
