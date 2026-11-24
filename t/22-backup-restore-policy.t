use Modern::Perl;
use Test::More;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::File');
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job');
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup');

# No server policy file, whatever the instance's koha-conf.xml says
{
    no warnings 'redefine';
    *Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script::_server_policy_text = sub { return };
}

package FakePlugin;
sub new           { my ( $c, %a ) = @_; bless {%a}, $c }
sub mbf_dir       { $_[0]{dir} }
sub retrieve_data { my ( $s, $k ) = @_; return $s->{data}{$k} }
package main;

my $dir  = tempdir( CLEANUP => 1 );
my $cron = "$dir/crontab";
my $bin  = "$dir/bin";
mkdir $bin;

sub write_file { my ( $f, $text ) = @_; open my $fh, '>', $f or die $!; print {$fh} $text; close $fh }
sub slurp      { open my $fh, '<', $_[0] or die $!; local $/; scalar <$fh> }

write_file( "$bin/approved.pl", "#!/usr/bin/perl\nuse Getopt::Long;\nGetOptions( 'x' => \\\$x );\n" );
write_file( "$bin/evil.pl",     "#!/usr/bin/perl\n" );
write_file( "$bin/nonrep.pl",   "#!/usr/bin/perl\n" );
write_file( "$bin/strict.pl",   "my \$opt = Koha::Script->describe_options( '%c %o', [ 'hours|h=i', 'hours', { required => 1 } ] );\n" );

my $policy = "scripts:\n  - path: approved.pl\n  - path: strict.pl\n  - path: nonrep.pl\n    non_repeatable: true\n";
my $plugin = FakePlugin->new( dir => $dir, data => { script_policy => $policy, backup_retention => 50 } );
my $file   = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $plugin, cron_file => $cron, lockfile => "$dir/lock" } );
my $job    = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => $file } );
my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $file } );
my $backup = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Backup->new( { crontab => $file, job => $job, script => $script } );

my $header = "KOHA_CRON_PATH=$bin\n\n";

# The script model finds scripts through KOHA_CRON_PATH in the live crontab
write_file( $cron, $header );

# A job block exactly as the plugin writes it
sub job_block {
    my ( $id, $name, $command, %o ) = @_;
    my $env = join '', map { "$_=$o{env}{$_}\n" } sort keys %{ $o{env} || {} };
    return "# \@crontab-manager-id: $id\n# \@name: $name\n# \@managed-by: koha-crontab-plugin\n$env"
        . ( $o{disabled} ? '#' : '' ) . "0 3 * * * $command\n\n";
}

sub candidate {
    my ($text) = @_;
    my $ct = Config::Crontab->new();
    $ct->mode('block');
    write_file( "$dir/candidate", $text );
    $ct->read( -file => "$dir/candidate" );
    return $ct;
}

sub errors_for { my ( $text, $current ) = @_; return $backup->restore_errors( candidate($text), candidate( $current // $header ) ) }

# --- a restorable version -----------------------------------------------------------------------
is( errors_for( $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl --x' ) ), undef, 'a version whose jobs all pass can be restored' );
is( errors_for($header),                                                                          undef, 'a version with no managed jobs can be restored' );

# --- enabled jobs must pass today's command and policy checks ----------------------------------
my $e = errors_for( $header . job_block( 'e1', 'Gone script', '$KOHA_CRON_PATH/evil.pl' ) );
like( $e, qr/can't be restored.*'Gone script'.*approved list/s, 'an enabled job for a script the policy no longer permits blocks the restore' );

$e = errors_for( $header . job_block( 'c1', 'Chained', '$KOHA_CRON_PATH/approved.pl --x ; touch /tmp/pwned' ) );
like( $e, qr/'Chained'.*unsupported shell syntax/s, 'an enabled job with chained shell syntax blocks the restore' );

$e = errors_for( $header . job_block( 's1', 'Strict', '$KOHA_CRON_PATH/strict.pl' ) );
like( $e, qr/'Strict'.*hours/s, 'an enabled job missing an option its script requires blocks the restore' );
is( errors_for( $header . job_block( 's2', 'Strict ok', '$KOHA_CRON_PATH/strict.pl --hours 5' ) ), undef, '...and passes once it has it' );

$e = errors_for( $header . job_block( 'n1', 'First', '$KOHA_CRON_PATH/nonrep.pl' ) . job_block( 'n2', 'Second', '$KOHA_CRON_PATH/nonrep.pl' ) );
like( $e, qr/non-repeatable/s, 'two enabled jobs of a non-repeatable script block the restore' );
is( errors_for( $header . job_block( 'n1', 'First', '$KOHA_CRON_PATH/nonrep.pl' ) ), undef, 'one is fine' );

# --- disabled jobs are only checked when they are enabled -------------------------------------------
is( errors_for( $header . job_block( 'd1', 'Disabled gone', '$KOHA_CRON_PATH/evil.pl', disabled => 1 ) ), undef, 'a disabled job for a script no longer permitted does not block (enabling re-checks)' );

# --- the environment rule ----------------------------------------------------------------------------------------
$e = errors_for( $header . job_block( 'v1', 'Has env', '$KOHA_CRON_PATH/approved.pl', env => { MAILTO => 'a@b.c' } ) );
like( $e, qr/'Has env'.*environment variables are not supported/s, 'a restore cannot bring back an environment variable the job no longer has' );

my $with_env = $header . job_block( 'v1', 'Has env', '$KOHA_CRON_PATH/approved.pl', env => { MAILTO => 'a@b.c' } );
is( errors_for( $with_env, $with_env ), undef, 'a job that still has the same variable can be restored' );
is( errors_for( $header . job_block( 'v1', 'Has env', '$KOHA_CRON_PATH/approved.pl' ), $with_env ), undef, 'removing a variable is fine' );
$e = errors_for( $header . job_block( 'v1', 'Has env', '$KOHA_CRON_PATH/approved.pl', env => { MAILTO => 'evil@b.c' } ), $with_env );
ok( defined $e, 'a restore cannot change a variable\'s value' );
$e = errors_for( $header . job_block( 'v9', 'Another', '$KOHA_CRON_PATH/approved.pl', env => { PERL5OPT => '-Mevil' } ), $with_env );
ok( defined $e, 'nor add a variable to a job that is not in the current crontab' );

# --- system entries are the system's own ----------------------------------------------------------------------------------
is( errors_for( $header . "# system\n0 4 * * * /usr/bin/anything --goes ; and so does this\n\n" . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) ), undef,
    'entries the plugin does not manage are restored as they were' );

# --- reporting ------------------------------------------------------------------------------------------------------------------
my $many = $header . join( '', map { job_block( "x$_", "Bad $_", '$KOHA_CRON_PATH/evil.pl' ) } 1 .. 8 );
$e = errors_for($many);
like( $e, qr/'Bad 1'/, 'errors name the jobs' );
like( $e, qr/\(and 3 more\)/, 'a long list of problems is cut off, saying how many more there are' );
unlike( $e, qr/'Bad 8'/, '...without listing them all' );
like( errors_for( $header . job_block( 'e1', 'One', '$KOHA_CRON_PATH/evil.pl' ) ), qr/contains a job that/, 'singular wording for one job' );

# --- versions -----------------------------------------------------------------------------------------------------------------------
write_file( $cron, $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) );
my $b1 = $file->backup_crontab;
write_file( $cron, $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) . job_block( 'a2', 'Off', '$KOHA_CRON_PATH/approved.pl', disabled => 1 ) );
my $b2 = $file->backup_crontab;

my $v = $backup->versions;
is( scalar @$v, 2, 'two different states are two versions' );
is( $v->[0]{name}, ( split m{/}, $b2 )[-1], 'newest first' );
is( $v->[0]{jobs}, 2, 'versions count plugin-managed jobs' );
is( $v->[0]{enabled_jobs}, 1, '...and enabled ones' );
is( $v->[0]{entries}, 2, '...and cron lines' );
is( $v->[1]{jobs}, 1, 'the older version has one job' );
ok( $v->[0]{current}, 'the newest version matches the crontab as it is' );
ok( !$v->[1]{current}, 'an older one does not' );
ok( $v->[0]{size} > 0 && $v->[0]{timestamp} && $v->[0]{display} =~ /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/, 'size, timestamp and display are filled in' );
is( $v->[0]{copies}, 1, 'a single backup is one copy' );

# identical consecutive backups (older installs wrote the same state twice) are one version
write_file( "$dir/backups/crontab_backup_2000-01-01_00-00-00", slurp("$dir/backups/" . $v->[1]{name}) );
write_file( "$dir/backups/crontab_backup_2000-01-01_00-00-01", slurp("$dir/backups/" . $v->[1]{name}) );
my $v2 = $backup->versions;
is( scalar @$v2, 2, 'duplicate-content backups collapse into one version' );
is( $v2->[1]{copies}, 3, '...and the version says how many copies there are' );

# --- content ------------------------------------------------------------------------------------------------------------------------
is( $backup->content('current')->{content}, candidate( slurp($cron) )->dump, 'content of the current crontab' );
is( $backup->content( $v->[1]{name} )->{content}, candidate( $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) )->dump, 'content of a version' );
is( $backup->content('crontab_backup_2099-01-01_00-00-00'), undef, 'content of a version that does not exist' );
is( $backup->content('../crontab'), undef, 'content refuses a name that is not a version' );

# --- restore end to end -------------------------------------------------------------------------------------------------------------------
my $r = $backup->restore( $v->[1]{name} );
ok( $r->{success}, 'restoring an acceptable version works' ) or diag $r->{error};
is( candidate( slurp($cron) )->dump, candidate( $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) )->dump, 'the crontab is that version' );

# a version that has become unacceptable is refused, and nothing changes
write_file( $cron, $header . job_block( 'a1', 'Approved job', '$KOHA_CRON_PATH/approved.pl' ) );
write_file( "$dir/backups/crontab_backup_2030-01-01_00-00-00", $header . job_block( 'z1', 'Sneaky', '$KOHA_CRON_PATH/approved.pl ; touch /tmp/pwned' ) );
my $live = slurp($cron);
my $refused = $backup->restore('crontab_backup_2030-01-01_00-00-00');
ok( !$refused->{success}, 'a version with a job that fails today\'s checks is refused' );
like( $refused->{error}, qr/'Sneaky'/, '...naming the job' );
is( slurp($cron), $live, '...and the crontab is untouched' );

my $nf = $backup->restore('crontab_backup_2099-01-01_00-00-00');
ok( !$nf->{success} && $nf->{not_found}, 'restoring a version that does not exist is not found' );

done_testing();
