use Modern::Perl;
use Test::More tests => 5;
use JSON::MaybeXS qw(decode_json);
use Path::Tiny qw(path);
use YAML::XS qw(Load);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $package_json = decode_json( path($plugin_dir)->child('package.json')->slurp );
my $plugin_module = $package_json->{plugin}->{module};

unshift @INC, $plugin_dir;
use_ok($plugin_module);

my $plugin = $plugin_module->new();

my $yaml = $plugin->_convert_legacy_allowlist_text("batch/report.pl\nfinegen.pl\n");
like( $yaml, qr/path:\s*batch\/report\.pl/, 'first legacy pattern converted into the scripts list' );
like( $yaml, qr/path:\s*finegen\.pl/, 'second legacy pattern converted' );

$plugin->store_data(
    {
        script_allowlist      => "batch/report.pl\nfinegen.pl\n",
        script_policy          => undef,
        __INSTALLED_VERSION__ => '0.0.1',
    }
);

my $upgraded = $plugin_module->new();    # constructor runs upgrade() since installed version is behind

my $migrated_data = Load( $upgraded->retrieve_data('script_policy') );
is( scalar @{ $migrated_data->{scripts} }, 2, 'upgrade() migrates both legacy patterns' );
is( $upgraded->retrieve_data('script_allowlist'), undef, 'upgrade() clears the legacy key' );
