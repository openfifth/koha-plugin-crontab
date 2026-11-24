use Modern::Perl;
use Test::More;
use CGI;
use JSON qw(decode_json);
use YAML::XS qw(Load);
use Path::Tiny qw(path);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

my $package_json  = decode_json( path($plugin_dir)->child('package.json')->slurp );
my $plugin_module = $package_json->{plugin}->{module};
use_ok($plugin_module);

# configure() renders a template and reads/writes plugin storage; stub those
# so the test only exercises the decision about whether a request is a save.
package FakeTemplate;
sub new    { bless {}, shift }
sub param  { }
sub output { 'rendered' }
package main;

my ( $rendered, $went_home, @stored );
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${plugin_module}::get_template"}  = sub { FakeTemplate->new };
    *{"${plugin_module}::output_html"}   = sub { $rendered++ };
    *{"${plugin_module}::go_home"}       = sub { $went_home++ };
    *{"${plugin_module}::store_data"}    = sub { push @stored, $_[1] };
    *{"${plugin_module}::retrieve_data"} = sub { undef };
}

sub run_configure {
    my ( $method, %params ) = @_;
    local $ENV{REQUEST_METHOD} = $method;
    my $cgi    = CGI->new( {%params} );
    my $plugin = $plugin_module->new( { cgi => $cgi } );

    # Constructing the plugin runs its install/seed logic against the stubbed
    # storage; only count what configure() itself does.
    ( $rendered, $went_home, @stored ) = ( 0, 0 );
    $plugin->configure;
    return { rendered => $rendered, went_home => $went_home, stored => [@stored] };
}

my %attack = (
    backup_retention => 77,
    enable_logging   => 'No',
    user_allowlist   => '',
    script_policy    => '{"scripts":[{"path":"runreport.pl"}]}',
);

# --- the cross-site attack shapes: nothing may be stored ----------------------
for my $case (
    [ 'GET with save=1 (the original attack)',        'GET',  { %attack, save => 1 } ],
    [ 'GET with op=cud-save',                         'GET',  { %attack, op => 'cud-save' } ],
    [ 'GET with both save=1 and op=cud-save',         'GET',  { %attack, save => 1, op => 'cud-save' } ],
    [ 'HEAD with op=cud-save',                        'HEAD', { %attack, op => 'cud-save' } ],
    [ 'POST with the old save=1 parameter and no op', 'POST', { %attack, save => 1 } ],
    [ 'POST with a different op',                     'POST', { %attack, op => 'cud-delete' } ],
    [ 'POST with a non-cud op',                       'POST', { %attack, op => 'save' } ],
    [ 'POST with no parameters at all',               'POST', {} ],
  )
{
    my ( $name, $method, $params ) = @$case;
    my $r = run_configure( $method, %$params );
    is_deeply( $r->{stored}, [], "$name: nothing stored" );
    is( $r->{went_home}, 0, "$name: not treated as a save" );
    is( $r->{rendered},  1, "$name: renders the form instead" );
}

# --- the one genuine shape: POST with op=cud-save -----------------------------------
my $ok = run_configure( 'POST', %attack, backup_retention => 500, op => 'cud-save' );
is( $ok->{went_home}, 1, 'POST with op=cud-save is a save' );
is( $ok->{rendered},  0, '...and does not also render the form' );
is( scalar @{ $ok->{stored} }, 1, '...and stores the settings once' );
is( $ok->{stored}[0]{backup_retention}, 10, 'an out-of-range backup retention falls back to the default' );

my $ok2 = run_configure( 'POST', %attack, backup_retention => 25, op => 'cud-save' );
is( $ok2->{stored}[0]{backup_retention}, 25, 'a valid backup retention is stored' );
is_deeply( [ map { $_->{path} } @{ Load( $ok2->{stored}[0]{script_policy} )->{scripts} } ], ['runreport.pl'], 'the submitted script policy is stored' );

done_testing();
