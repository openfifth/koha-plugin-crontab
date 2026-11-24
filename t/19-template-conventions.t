use Modern::Perl;
use Test::More;
use Path::Tiny qw(path);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
my $dir        = path($plugin_dir)->child('Koha/Plugin/Com/OpenFifth/Crontab');

# Every page must go through core's plugin wrapper and stay CSP-safe, so a
# page can't quietly drift back to a hand-built skeleton or an inline script
# a Content-Security-Policy would block.
for my $name (qw(crontab.tt configure.tt access_denied.tt)) {
    my $tt = $dir->child($name)->slurp_utf8;

    like( $tt, qr/\[% WRAPPER 'wrapper-staff-tool-plugin\.inc' %\]/, "$name: uses core's staff plugin wrapper" );
    like( $tt, qr/\[% SET method = '(?:admin|configure)' %\]/,       "$name: sets the wrapper's method" );
    like( $tt, qr/\[% SET plugin_title = /,                           "$name: sets the wrapper's plugin_title" );

    for my $skeleton (qw(doc-head-open.inc doc-head-close.inc intranet-bottom.inc admin-menu.inc)) {
        unlike( $tt, qr/\Q$skeleton\E/, "$name: does not hand-build the page with $skeleton" );
    }
    unlike( $tt, qr/MACRO jsinclude/, "$name: does not define jsinclude (the wrapper replaces it)" );
    unlike( $tt, qr/<body\b/,         "$name: does not open its own <body>" );

    my @untagged = grep { !/nonce=/ } $tt =~ /(<(?:script|style)\b[^>]*>)/g;
    is_deeply( \@untagged, [], "$name: every inline <script> and <style> carries a CSP nonce" );

    unlike( $tt, qr/\s on(?:click|change|submit|input|keyup|keydown|load)\s*=/i, "$name: no inline event handlers (blocked by CSP)" );
}

# Pages that submit forms must POST with a CSRF token and a cud- op.
my $configure = $dir->child('configure.tt')->slurp_utf8;
my @forms     = $configure =~ /(<form\b[^>]*>)/g;
ok( scalar @forms, 'configure.tt has a form' );
like( $_, qr/method="post"/i, "configure.tt: form submits by POST ($_)" ) for @forms;
like( $configure, qr/\[% INCLUDE 'csrf-token\.inc' %\]/,             'configure.tt: form carries a CSRF token' );
like( $configure, qr/name="op" value="cud-save"/,                    'configure.tt: form uses op=cud-save' );
unlike( $configure, qr/name="save"/,                                  'configure.tt: no state-changing save=1 parameter' );

# State-changing REST calls from the admin page must send the CSRF header.
my $crontab = $dir->child('crontab.tt')->slurp_utf8;
like( $crontab, qr/setRequestHeader\('CSRF-TOKEN'/, 'crontab.tt: sends the CSRF-TOKEN header on unsafe API requests' );
unlike( $crontab, qr/id="add-env-var"/,             'crontab.tt: offers no way to add a job-level environment variable' );

done_testing();
