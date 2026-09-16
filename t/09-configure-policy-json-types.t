use Modern::Perl;
use Test::More tests => 6;
use JSON::MaybeXS qw(decode_json);
use Path::Tiny qw(path);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $package_json = path($plugin_dir)->child('package.json');
unshift @INC, $plugin_dir;

my $plugin_module = decode_json( $package_json->slurp )->{plugin}->{module};
use_ok($plugin_module);
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::File');
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $plugin = $plugin_module->new();
$plugin->store_data(
    {
        script_policy => "scripts:\n"
          . "  - path: batch/report.pl\n"
          . "    non_repeatable: 0\n"
          . "  - path: finegen.pl\n"
          . "    non_repeatable: 1\n",
    }
);

my $crontab      = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new( { plugin => $plugin } );
my $script_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => $crontab } );

# This is the exact method configure()'s GET path calls to build the
# script_policy template param -- pinning it here catches a regression to
# a bare YAML::XS::Load()+encode_json() round-trip, which serializes
# non_repeatable as the JSON string "0"/"1" (both truthy in JS) instead of
# a real JSON number, making the "Non-repeatable" checkbox always render
# checked regardless of the stored value.
my $json = $plugin->_library_policy_json($script_model);

like( $json, qr/"non_repeatable":0\b/,  'false non_repeatable serializes as an unquoted JSON 0' );
like( $json, qr/"non_repeatable":1\b/,  'true non_repeatable serializes as an unquoted JSON 1' );
unlike( $json, qr/"non_repeatable":"0"/, 'false non_repeatable is never a JSON string "0"' );

$plugin->store_data( { script_policy => undef } );
