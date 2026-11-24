use Modern::Perl;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::File');

# A plugin stand-in: all File needs is a directory to keep backups in and the
# retention setting.
package FakePlugin;
sub new           { my ( $c, %a ) = @_; bless {%a}, $c }
sub mbf_dir       { $_[0]{dir} }
sub retrieve_data { $_[0]{retention} }
package main;

my $dir  = tempdir( CLEANUP => 1 );
my $cron = "$dir/crontab";    # the "live" crontab: a temp file, never the real one

sub write_cron { open my $fh, '>', $cron or die $!; print {$fh} $_[0]; close $fh }
sub read_cron  { open my $fh, '<', $cron or die $!; local $/; scalar <$fh> }
sub slurp      { open my $fh, '<', $_[0] or die $!; local $/; scalar <$fh> }

my $plugin = FakePlugin->new( dir => $dir, retention => 50 );
my $file   = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $plugin, cron_file => $cron, lockfile => "$dir/lock" } );
my $backups = "$dir/backups";

sub names { map { $_->{name} } @{ $file->list_backups } }

my $v1 = "0 1 * * * /bin/one\n";
my $v2 = "0 2 * * * /bin/two\n";
my $v3 = "0 3 * * * /bin/three\n";

# --- creating versions ---------------------------------------------------------------
write_cron($v1);
my $b1 = $file->backup_crontab;
like( $b1, qr{/crontab_backup_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$}, 'a backup is named by its timestamp' );
is( slurp($b1), $v1, 'a backup holds the crontab as it was' );

is( $file->backup_crontab, $b1, 'an unchanged crontab reuses the newest backup instead of writing another' );
is( scalar( () = names() ), 1, '...so there is still one version' );

write_cron($v2);
my $b2 = $file->backup_crontab;
isnt( $b2, $b1, 'a changed crontab gets a new backup, even within the same second' );
like( $b2, qr/_2$/, '...named with a suffix so the first is not overwritten' );
is( slurp($b1), $v1, 'the earlier backup is untouched' );
is( slurp($b2), $v2, 'the new backup holds the new state' );
is_deeply( [ names() ], [ map { ( split m{/}, $_ )[-1] } ( $b2, $b1 ) ], 'versions list newest first, including same-second suffixes' );

write_cron($v3);
my $b3 = $file->backup_crontab;
like( $b3, qr/_3$/, 'a third state in the same second gets the next suffix' );
is( ( names() )[0], ( split m{/}, $b3 )[-1], 'and sorts first (numerically, not as text)' );

# --- listing is strict ----------------------------------------------------------------------
for my $junk ( 'crontab_backup_notes', 'crontab_backup_2026-11-24_16-41-23.txt', 'crontab_backup_2026-11-24_16-41-23_x', 'other_file' ) {
    open my $fh, '>', "$backups/$junk" or die $!;
    print {$fh} "x";
    close $fh;
}
is( scalar( () = names() ), 3, 'files that are not backups are not listed' );

# --- names become paths only through backup_path -----------------------------------------------
my $good = ( names() )[0];
is( $file->backup_path($good), "$backups/$good", 'backup_path: a real backup name gives its path' );
for my $bad ( '../etc/passwd', "$good/../x", "../$good", '/etc/passwd', 'crontab_backup_2026-11-24_16-41-23', "$good\n", "$good ", '', undef, [], 'current' ) {
    is( $file->backup_path($bad), undef, 'backup_path refuses ' . ( defined $bad ? ( ref $bad ? 'a reference' : "'" . ( $bad =~ s/\n/\\n/gr ) . "'" ) : 'undef' ) );
}
is( $file->backup_path('crontab_backup_2099-01-01_00-00-00'), undef, 'backup_path: a well-formed name with no file is undef' );

# --- the rollback restores the backup, not the live crontab -----------------------------------
# restore_crontab used to read the live crontab instead of the backup file, so
# "restoring" changed nothing.
write_cron($v1);
write_cron($v3);
ok( $file->restore_crontab($b1), 'restore_crontab succeeds' );
is( read_cron(), $v1, 'restore_crontab puts the BACKUP content back (it used to rewrite the live crontab)' );

# --- safely_modify_crontab: pre-backup reported, failure rolls back ------------------------------------
write_cron($v1);
my $r = $file->safely_modify_crontab( sub { 1 } );
ok( $r->{success}, 'safely_modify_crontab succeeds for a no-op change' );
ok( $r->{pre_backup}, '...and reports the pre-change backup' );

write_cron($v1);
my $failed = $file->safely_modify_crontab( sub { my ($ct) = @_; $ct->last( Config::Crontab::Block->new( -data => "5 5 * * * /bin/added\n" ) ); die "boom\n" } );
ok( !$failed->{success}, 'a failing change reports failure' );
is( read_cron(), $v1, '...and leaves the crontab as it was' );

# --- restore_backup -----------------------------------------------------------------------------------
my $keep = scalar( () = names() );
write_cron($v3);
my $name2 = ( split m{/}, $b2 )[-1];
my $res = $file->restore_backup($name2);
ok( $res->{success}, 'restore_backup succeeds' ) or diag $res->{error};
is( $res->{restored_from}, $name2, '...and says what it restored' );
is( read_cron(), $v2, '...the crontab is now that version' );
ok( ( grep { slurp("$backups/$_") eq $v3 } names() ), '...and the state it replaced was saved as a version first, so the restore can be undone' );

# a validator can refuse, and then nothing is touched
write_cron($v3);
my $before = join ',', names();
my @seen;
my $refused = $file->restore_backup( $name2, sub { @seen = @_; return 'not allowed' } );
ok( !$refused->{success}, 'a validator can refuse a restore' );
is( $refused->{error}, 'not allowed', '...with its reason' );
is( read_cron(), $v3, '...leaving the crontab alone' );
is( join( ',', names() ), $before, '...without writing any backup' );
is( scalar @seen, 2, 'the validator gets the candidate and the current crontab' );
is( $seen[0]->dump, $v2, '...the first is the version being restored' );
is( $seen[1]->dump, $v3, '...the second is what is live now' );

my $allowed = $file->restore_backup( $name2, sub { return } );
ok( $allowed->{success}, 'a validator that returns nothing allows the restore' );

# unknown or malformed names
for my $bad ( 'crontab_backup_2099-01-01_00-00-00', '../x', 'current', '' ) {
    my $nf = $file->restore_backup($bad);
    ok( !$nf->{success} && $nf->{not_found}, "restore_backup: '$bad' is not found" );
}

# --- retention counts versions, so unchanged states don't use it up ------------------------------------
my $dir2   = tempdir( CLEANUP => 1 );
my $cron2  = "$dir2/crontab";
my $file2  = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => FakePlugin->new( dir => $dir2, retention => 3 ), cron_file => $cron2, lockfile => "$dir2/lock" } );
for my $n ( 1 .. 6 ) {
    open my $fh, '>', $cron2 or die $!;
    print {$fh} "0 $n * * * /bin/n$n\n";
    close $fh;
    $file2->backup_crontab;
    $file2->backup_crontab;    # unchanged: must not take a second slot
}
is( scalar @{ $file2->list_backups }, 3, 'retention keeps the configured number of distinct versions' );
is( slurp( $file2->{backup_dir} . '/' . $file2->list_backups->[0]{name} ), "0 6 * * * /bin/n6\n", '...the newest ones' );

done_testing();
