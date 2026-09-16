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

my @expected_paths = (
    'runreport.pl',
    'cleanup_database.pl',
    'longoverdue.pl',
    'update_patrons_category.pl',
    'process_message_queue.pl',
    'gather_print_notices.pl',
    'holds/holds_reminder.pl',
);

# Fresh install: no script_policy configured yet
my $plugin = $plugin_module->new();
$plugin->store_data( { script_policy => undef } );

$plugin->install();

my $seeded_yaml = $plugin->retrieve_data('script_policy');
ok( defined $seeded_yaml, 'install() seeds a script_policy when none was configured' );

my $seeded_data = Load($seeded_yaml);
my @seeded_paths = map { $_->{path} } @{ $seeded_data->{scripts} };
is_deeply(
    [ sort @seeded_paths ],
    [ sort @expected_paths ],
    'install() seeds exactly the expected default allowlist'
);

# Already-configured install is left untouched
my $custom_yaml = "scripts:\n  - path: batch/custom_report.pl\n";
$plugin->store_data( { script_policy => $custom_yaml } );

$plugin->install();

is(
    $plugin->retrieve_data('script_policy'),
    $custom_yaml,
    'install() does not overwrite an already-configured script_policy'
);

# Clean up so this test file doesn't leak state into other test runs
$plugin->store_data( { script_policy => undef } );
is( $plugin->retrieve_data('script_policy'), undef, 'test cleanup clears script_policy' );
