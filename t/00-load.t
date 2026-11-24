use Modern::Perl;
use Test::More tests => 5;
use Test::Exception;
use JSON::MaybeXS qw(decode_json);
use Path::Tiny qw(path);

# Get the plugin directory path
my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $package_json_path = path($plugin_dir)->child('package.json');

# Add plugin directory to @INC
unshift @INC, $plugin_dir;

# Read package.json
my $package_json = decode_json($package_json_path->slurp);
my $plugin_module = $package_json->{plugin}->{module};
my $expected_version = $package_json->{version};

# Test module loading
use_ok($plugin_module);

# Test instantiation
my $plugin;
lives_ok { $plugin = $plugin_module->new() } 'Plugin can be instantiated';

# Test version
is($plugin->{metadata}->{version}, $expected_version, 'Plugin version matches package.json');

# Test licence metadata
is($plugin->{metadata}->{license}, 'AGPL-3.0-or-later', 'Plugin declares its licence in metadata');
like($plugin->{metadata}->{description}, qr/AGPL-3\.0-or-later/, 'Licence is visible in the description shown in Koha');
