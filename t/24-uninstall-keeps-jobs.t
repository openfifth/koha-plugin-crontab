use Modern::Perl;
use Test::More tests => 4;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
use lib "$Bin/../lib";

use_ok('Koha::Plugin::Com::OpenFifth::Crontab');

# Uninstalling must leave the crontab (and so the library's scheduled jobs)
# alone. A bare object with no crontab or settings behind it proves uninstall
# does not reach for them: removing jobs would need both.
my $dir  = tempdir( CLEANUP => 1 );
my $file = "$dir/crontab";
my $text = join( "\n", 'KOHA_CRON_PATH=/x', '# @crontab-manager-id: abc', '# @managed-by: koha-crontab-plugin', '0 1 * * * /x/a.pl' ) . "\n";
open my $fh, '>', $file or die $!;
print {$fh} $text;
close $fh;

# (no directory to keep backups in, so no final backup is attempted)
{
    package NoBackupDir;
    our @ISA = ('Koha::Plugin::Com::OpenFifth::Crontab');
    sub persistent_backup_dir { undef }
}
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
ok( Koha::Plugin::Com::OpenFifth::Crontab::uninstall( bless {}, 'NoBackupDir' ),
    'uninstall succeeds without a crontab or settings' );
like( "@warnings", qr/deleted with the plugin/, 'and says that the backups will not survive' );

open $fh, '<', $file or die $!;
local $/;
is( <$fh>, $text, 'a crontab the plugin manages is left as it was' );
