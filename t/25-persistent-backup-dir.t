use Modern::Perl;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::File');

# Koha deletes a plugin's directory when it is uninstalled, so backups are kept
# somewhere else (persistent_backup_dir) and the old location is still read.
package FakePlugin;
sub new                   { my ( $c, %a ) = @_; bless {%a}, $c }
sub mbf_dir               { $_[0]{dir} }
sub retrieve_data         { 50 }
sub persistent_backup_dir { $_[0]{persistent} }
package main;

my $dir        = tempdir( CLEANUP => 1 );
my $plugin_own = "$dir/plugin";
my $keep       = "$dir/keep/koha-crontab-plugin";
make_path( "$plugin_own/backups", $keep );
my $cron = "$dir/crontab";

sub write_cron { open my $fh, '>', $cron or die $!; print {$fh} $_[0]; close $fh }
sub slurp      { open my $fh, '<', $_[0] or die $!; local $/; scalar <$fh> }

# A backup made by an older version, under the plugin's directory
my $old = 'crontab_backup_2026-01-01_00-00-00';
open my $fh, '>', "$plugin_own/backups/$old" or die $!;
print {$fh} "0 0 * * * /old\n";
close $fh;

write_cron("0 1 * * * /one\n");
my $file = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
    { plugin => FakePlugin->new( dir => $plugin_own, persistent => $keep ), cron_file => $cron, lockfile => "$dir/lock" } );

is( $file->{backup_dir}, $keep, 'new backups go to the persistent directory' );

ok( $file->backup_crontab, 'a backup is taken' );
sub backups_in { opendir( my $dh, $_[0] ) or return (); return grep { /^crontab_backup_/ } readdir $dh }
my @in_keep = backups_in($keep);
is( scalar @in_keep, 1, 'it was written outside the plugin directory' );
my @in_plugin = backups_in("$plugin_own/backups");
is_deeply( \@in_plugin, [$old], 'nothing new was written under the plugin directory' );

my %names = map { $_->{name} => 1 } @{ $file->list_backups };
ok( $names{$old},         'a backup from the old location is still listed' );
ok( $names{ $in_keep[0] }, 'and so is the new one' );
is( slurp( $file->backup_path($old) ), "0 0 * * * /old\n", 'an old backup can still be read' );

# After "uninstall" the plugin directory is gone: only the persistent copy is left
system( 'rm', '-rf', $plugin_own );
my $after = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
    { plugin => FakePlugin->new( dir => $plugin_own, persistent => $keep ), cron_file => $cron, lockfile => "$dir/lock" } );
my @left = map { $_->{name} } @{ $after->list_backups };
is_deeply( \@left, \@in_keep, 'backups kept outside the plugin survive its removal' );

# No suitable directory: fall back to the plugin's own, as before
my $own = "$dir/plugin2";
make_path($own);
my $fallback = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => FakePlugin->new( dir => $own ), cron_file => $cron, lockfile => "$dir/lock" } );
is( $fallback->{backup_dir}, "$own/backups", 'without a persistent directory backups stay under the plugin' );

# persistent_backup_dir itself: koha-crontab-plugin under the configured
# backupdir, else .crontab_backups beside upload_path
{
    no warnings qw(redefine once);
    my %configured;
    local *C4::Context::config = sub { $configured{ $_[1] } };
    my $pbd = sub { Koha::Plugin::Com::OpenFifth::Crontab::Cron::File::persistent_backup_dir() };

    make_path( "$dir/spool", "$dir/instance/uploads" );
    %configured = ( backupdir => "$dir/spool", upload_path => "$dir/instance/uploads" );
    is( $pbd->(), "$dir/spool/koha-crontab-plugin", 'the directory is created under the configured backupdir' );
    ok( -d "$dir/spool/koha-crontab-plugin", '...and exists' );

    # backupdir not writable (root-owned on some installs): the instance directory
    %configured = ( backupdir => "$dir/not-there", upload_path => "$dir/instance/uploads" );
    is( $pbd->(), "$dir/instance/.crontab_backups", 'a backupdir that is not there falls back to the instance directory' );
    ok( -d "$dir/instance/.crontab_backups", '...which is created' );

    %configured = ( upload_path => "$dir/instance/uploads/" );
    is( $pbd->(), "$dir/instance/.crontab_backups", 'a trailing slash on upload_path makes no difference' );

    %configured = ( backupdir => "$dir/not-there", upload_path => "$dir/no-instance/uploads" );
    is( $pbd->(), undef, 'neither location usable: no persistent directory' );

    %configured = ();
    is( $pbd->(), undef, 'nothing configured: no persistent directory' );

    %configured = ( backupdir => 'relative/path', upload_path => 'relative/uploads' );
    is( $pbd->(), undef, 'relative paths are not used' );
}

done_testing;
