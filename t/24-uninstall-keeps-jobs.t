use Modern::Perl;
use Test::More tests => 3;
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

ok( Koha::Plugin::Com::OpenFifth::Crontab::uninstall( bless {}, 'Koha::Plugin::Com::OpenFifth::Crontab' ),
    'uninstall succeeds without a crontab or settings' );

open $fh, '<', $file or die $!;
local $/;
is( <$fh>, $text, 'a crontab the plugin manages is left as it was' );
