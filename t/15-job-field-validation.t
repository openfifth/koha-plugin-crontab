use Modern::Perl;
use Test::More;

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job');

my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => {} } );

my %base = (
    name        => 'Nightly cleanup',
    description => 'Removes old sessions',
    schedule    => '0 3 * * *',
    command     => '$KOHA_CRON_PATH/cleanup_database.pl --sessions',
);

ok( $job->validate_job_fields( \%base )->{valid}, 'ordinary job fields are valid' );
ok( $job->validate_job_fields( { %base, environment => { MY_VAR => 'x y', _OTHER1 => '' } } )->{valid}, 'well-formed environment is valid (shape only; see check_environment_change)' );
ok( $job->validate_job_fields( {} )->{valid}, 'absent fields are not checked' );

# --- newline / control characters in any single-line field ---------------
for my $field (qw(name description schedule command)) {
    for my $bad ( "a\nb", "a\rb", "a\0b" ) {
        ( my $shown = $bad ) =~ s/\n/\\n/;
        $shown =~ s/\r/\\r/;
        $shown =~ s/\0/\\0/;
        my $r = $job->validate_job_fields( { %base, $field => $bad } );
        ok( !$r->{valid}, "rejects '$shown' in $field" );
        like( $r->{error}, qr/\Q$field\E.*single line/, '  ...naming the field' );
    }
}

ok( !$job->validate_job_fields( { %base, name        => 'x' x 256 } )->{valid},  'name over 255 chars rejected' );
ok(  $job->validate_job_fields( { %base, name        => 'x' x 255 } )->{valid},  'name of 255 chars accepted' );
ok( !$job->validate_job_fields( { %base, description => 'x' x 2001 } )->{valid}, 'description over 2000 chars rejected' );
ok( !$job->validate_job_fields( { %base, name => [] } )->{valid},                'non-string name rejected' );

# --- environment ----------------------------------------------------------
for my $name ( "A\nB", "FOO=1", "1ABC", "A B", "", "A-B", "A.B" ) {
    ( my $shown = $name ) =~ s/\n/\\n/;
    ok( !$job->validate_job_fields( { %base, environment => { $name => 'x' } } )->{valid}, "rejects variable name '$shown'" );
}
ok( !$job->validate_job_fields( { %base, environment => { FOO => "x\ny" } } )->{valid}, 'rejects newline in environment value' );
ok( !$job->validate_job_fields( { %base, environment => { FOO => undef } } )->{valid},  'rejects undef environment value' );
ok( !$job->validate_job_fields( { %base, environment => [] } )->{valid},               'rejects non-object environment' );


# --- create_job_block is a last line of defence ---------------------------
for my $case (
    [ name        => "ok\n* * * * * touch /tmp/p1" ],
    [ description => "ok\n* * * * * touch /tmp/p2" ],
    [ command     => "\$KOHA_CRON_PATH/a.pl\n* * * * * touch /tmp/p3" ],
    [ schedule    => "0 1 * * *\n* * * * * touch /tmp/p4" ],
  )
{
    my ( $field, $value ) = @$case;
    my $block = eval { $job->create_job_block( { id => 'abc', %base, $field => $value } ) };
    ok( !$block, "create_job_block refuses a newline in $field" );
    like( $@, qr/Refusing to write unsafe job data/, '  ...with a clear error' );
}
ok( !eval { $job->create_job_block( { id => 'abc', %base, environment => { "X\n* * * * * touch /tmp/p5\nY" => 'v' } } ) }, 'create_job_block refuses an injecting environment name' );
ok( !eval { $job->create_job_block( { id => 'abc', %base, environment => { FOO => "v\n* * * * * touch /tmp/p6" } } ) },  'create_job_block refuses an injecting environment value' );

# A good job still produces exactly one event and no stray lines
my $block = $job->create_job_block( { id => 'abc', %base, environment => { MY_VAR => 'v' } } );
my $ct    = Config::Crontab->new();
$ct->last($block);
my $dump = $ct->dump;
my @event_lines = grep { /^[0-9*]/ } split /\n/, $dump;
is( scalar @event_lines, 1, 'a valid job dumps exactly one event line' );
like( $dump, qr/^MY_VAR=v$/m, 'and its environment line' );

# update_job_block goes through create_job_block, so it is covered too
ok( !eval { $job->update_job_block( $block, { name => "x\n* * * * * touch /tmp/p7" } ) }, 'update_job_block refuses a newline in name' );

done_testing();
