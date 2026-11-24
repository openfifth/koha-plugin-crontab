use Modern::Perl;
use Test::More;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job');
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => {} } );

# --- a new job (nothing existing) cannot set any variable -------------------
ok( $job->check_environment_change(undef)->{valid},      'absent environment is fine' );
ok( $job->check_environment_change( {} )->{valid},       'empty environment is fine' );
ok( $job->check_environment_change( {}, {} )->{valid},   'empty against empty is fine' );

for my $name (qw(MAILTO TZ LANG FOO KOHA_CRON_PATH KOHA_CONF PERL5OPT LD_PRELOAD PATH)) {
    my $r = $job->check_environment_change( { $name => 'x' } );
    ok( !$r->{valid}, "new job: $name refused" );
    like( $r->{error}, qr/Job-level environment variables are not supported \('\Q$name\E'\).*crontab header/s, '  ...with the reason and the alternative' );
}
ok( !$job->check_environment_change( { MAILTO => '' } )->{valid}, 'an empty value is still a variable being set' );

# --- an existing job can keep or drop its variables, never add or change ----
my %existing = ( MAILTO => 'ops@example.org', TZ => 'Europe/London' );

ok( $job->check_environment_change( {%existing}, {%existing} )->{valid},                     'unchanged environment (the UI round trip) is accepted' );
ok( $job->check_environment_change( { MAILTO => 'ops@example.org' }, {%existing} )->{valid}, 'removing a variable is accepted' );
ok( $job->check_environment_change( {}, {%existing} )->{valid},                              'removing them all is accepted' );
ok( $job->check_environment_change( { MAILTO => '  ops@example.org ' }, {%existing} )->{valid}, 'surrounding whitespace (the UI trims values) is not a change' );

my $changed = $job->check_environment_change( { MAILTO => 'attacker@example.org' }, {%existing} );
ok( !$changed->{valid}, 'changing a value is refused' );
like( $changed->{error}, qr/'MAILTO'/, '  ...naming the variable' );

my $added = $job->check_environment_change( { %existing, PERL5OPT => '-Mevil' }, {%existing} );
ok( !$added->{valid}, 'adding a variable alongside existing ones is refused' );
like( $added->{error}, qr/'PERL5OPT'/, '  ...naming the new one' );

ok( !$job->check_environment_change( { MAILTO => 'ops@example.org' }, {} )->{valid}, 'a job with no variables cannot gain one' );
ok( !$job->check_environment_change( { Mailto => 'ops@example.org' }, {%existing} )->{valid}, 'names are case-sensitive' );

# --- bad shapes ------------------------------------------------------------
for my $bad ( [], 'MAILTO=x', 5 ) {
    my $r = $job->check_environment_change($bad);
    ok( !$r->{valid}, 'a non-object environment is refused' );
}

# --- the environment allowlist machinery is gone ---------------------------------
my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );
ok( !$script->can('get_effective_environment_allowlist'), 'no environment allowlist on Cron::Script' );
ok( !$job->can('env_name_allowed'),                       'no environment allowlist matcher on Cron::Job' );

# --- the shipped defaults file has no environment section ------------------------
my $defaults = $script->get_default_policy_text();
ok( defined $defaults && $defaults =~ /^scripts:/m, 'default-policy.yaml still ships the default scripts' );
unlike( $defaults, qr/^environment:/m, '...and no environment section' );

done_testing();
