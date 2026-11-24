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

sub write_script {
    my ( $name, $body ) = @_;
    open my $fh, '>', "$dir/$name" or die $!;
    print {$fh} "#!/usr/bin/perl\n$body\n";
    close $fh;
}

# Verbatim option/args declarations from core's gather_print_notices.pl and
# runreport.pl (descriptions shortened).
write_script( 'gather_print_notices.pl', <<'PERL');
my ( $opt, $usage ) = Koha::Script->describe_options(
    'Print all waiting print notices to output_directory.

%c %o output_directory',
    [ 'split|s',        'split' ],
    [ 'html',           'html' ],
    [ 'csv',            'csv' ],
    [ 'ods',            'ods' ],
    [ 'delimiter|d:s',  'delimiter' ],
    [ 'letter_code:s@', 'letter_code' ],
    [ 'send!',          'send', { default => 1 } ],
    [ 'email|e:s@',     'email' ],
    { args => { min => 1, name => 'output_directory' } },
);
PERL

write_script( 'runreport.pl', <<'PERL');
my $opt = Koha::Script->describe_options(
    '%c %o reportID [reportID ...]',
    [ 'verbose|v',     'verbose' ],
    [ 'format=s',      'format', { default => 'text' } ],
    [ 'param=s@',      'param' ],
    [ 'sftp-dest-id=i', 'sftp' ],
    {
        epilog => "x",
        args   => { min => 1, name => 'reportID', variadic => 1 },
    },
);
PERL

write_script( 'plain.pl', <<'PERL');
GetOptions( 'verbose|v' => \$verbose );
PERL

write_script( 'two_args.pl', <<'PERL');
my $opt = Koha::Script->describe_options( '%c %o a b', [ 'x', 'x' ], { args => { min => 2, name => 'file' } } );
PERL

my $ct = Config::Crontab->new();
my $b  = Config::Crontab::Block->new();
$b->lines( [ Config::Crontab::Env->new( -name => 'KOHA_CRON_PATH', -value => $dir ) ] );
$ct->last($b);
# An empty policy permits no scripts, so the fixture scripts are listed.
my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => FakeCrontab->new( $ct, FakePlugin->new("scripts:\n  - path: gather_print_notices.pl\n  - path: runreport.pl\n  - path: plain.pl\n  - path: two_args.pl\n") ) } );

sub check {
    my ($command) = @_;
    my $v = $script->validate_command($command);
    die "fixture command not approved: $command ($v->{error})" unless $v->{valid};
    return $script->check_positional_args( $v->{script}, $command );
}

my $g = '$KOHA_CRON_PATH/gather_print_notices.pl';
my $r = '$KOHA_CRON_PATH/runreport.pl';

# --- gather_print_notices.pl: min 1 ---------------------------------------
for my $cmd (
    "$g /tmp/out",
    "$g --html /tmp/out",
    "$g /tmp/out --html",
    "$g --split --csv --letter_code HOLD /tmp/out",
    "$g --delimiter , /tmp/out",
    "$g --delimiter=, /tmp/out",
    "$g -d , /tmp/out",
    "$g -- /tmp/out",
    "$g -- --weird-dir-name",
    "$g --nosend /tmp/out",
    "$g --no-send /tmp/out",
    "$g \"/tmp/my out\"",
    "$g /tmp/out >/dev/null 2>&1",
    "$g /tmp/out a b c",
  )
{
    ok( check($cmd)->{valid}, "accepts: $cmd" );
}

for my $cmd (
    $g,
    "$g --html",
    "$g --html --split",
    "$g >/dev/null 2>&1",
    "$g --delimiter=,",
    "$g --delimiter ,",
    "$g -e",
    "$g --no-send",
    "$g --nosend",
  )
{
    my $res = check($cmd);
    ok( !$res->{valid}, "rejects: $cmd" );
    like( $res->{error} // '', qr/^At least 1 output_directory argument required \(got 0\)$/, '  ...with core\'s wording' );
}

# An optional-value (:s) option takes the next word unless it looks like
# an option -- exactly as Getopt::Long does -- so this "directory" is
# actually the value of --letter_code and the job would die at runtime.
ok( !check("$g --letter_code /tmp/out")->{valid}, 'optional-value option swallows the following word (mirrors Getopt::Long)' );
ok( !check("$g -e a\@b.c")->{valid},               'same for a short alias' );
ok( check("$g --letter_code -- /tmp/out")->{valid}, '-- stops option processing so a following word is a real argument' );

# --- runreport.pl: min 1, variadic ----------------------------------------
ok( check("$r 7")->{valid},                         'runreport: one report id' );
ok( check("$r 7 8 9")->{valid},                     'runreport: several report ids' );
ok( check("$r --format csv 7")->{valid},            'runreport: required-value option consumes its value' );
ok( check("$r --param a=b --param c=d 7")->{valid}, 'runreport: repeatable value option' );
ok( check("$r -v 7")->{valid},                      'runreport: short flag' );
ok( check("$r --sftp-dest-id 3 7")->{valid},        'runreport: integer option' );
ok( !check($r)->{valid},                            'runreport: no report id rejected' );
ok( !check("$r --format csv")->{valid},             'runreport: option value not mistaken for the report id' );
ok( !check("$r --param a=b")->{valid},              'runreport: --param value not mistaken for the report id' );
ok( !check("$r --format=csv -v")->{valid},          'runreport: only options, no report id' );

# --- plural wording and minimums above 1 ----------------------------------
my $t = '$KOHA_CRON_PATH/two_args.pl';
ok( check("$t a b")->{valid}, 'min 2: two args accepted' );
my $two = check("$t a");
ok( !$two->{valid}, 'min 2: one arg rejected' );
is( $two->{error}, 'At least 2 file arguments required (got 1)', 'min 2: plural wording' );

# --- scripts with no declared requirement always pass ---------------------
ok( check('$KOHA_CRON_PATH/plain.pl')->{valid},            'plain GetOptions script: no positional requirement' );
ok( check('$KOHA_CRON_PATH/plain.pl --verbose')->{valid},  'plain GetOptions script with options' );

# --- not a perl script / no script ----------------------------------------
ok( $script->check_positional_args( undef, 'x' )->{valid},                        'no script info: passes (nothing to enforce)' );
ok( $script->check_positional_args( { type => 'shell', path => "$dir/x.sh" }, 'x' )->{valid}, 'shell script: passes' );

done_testing();
