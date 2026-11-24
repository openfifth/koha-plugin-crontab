use Modern::Perl;
use Test::More;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;
unshift @INC, "$plugin_dir/Koha/Plugin/Com/OpenFifth/Crontab/lib";

require Config::Crontab;
use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job');

my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => {} } );
my $dir = tempdir( CLEANUP => 1 );

# Write a block the way the plugin does, then read it back from text, as the
# plugin does on every request.
sub roundtrip {
    my (%data) = @_;
    my $block = $job->create_job_block( { id => 'j1', schedule => '0 6 * * *', command => '$KOHA_CRON_PATH/runreport.pl 1', enabled => 0, %data } );
    my $ct = Config::Crontab->new();
    $ct->last($block);
    open my $fh, '>', "$dir/ct" or die $!;
    print {$fh} $ct->dump;
    close $fh;

    my $read = Config::Crontab->new();
    $read->mode('block');
    $read->read( -file => "$dir/ct" );
    return $read;
}

# --- "=" in a name or description used to read back as empty ----------------------------------
my $ct   = roundtrip( name => 'Nightly a=b report', description => 'Marks lost after --lost 30=1' );
my ($j)  = @{ $job->get_plugin_managed_jobs($ct) };
is( $j->{name},        'Nightly a=b report',            'a name containing = reads back intact' );
is( $j->{description}, 'Marks lost after --lost 30=1', 'a description containing = reads back intact' );
is_deeply( $j->{environment}, {}, '...and is not mistaken for a job environment variable' );
is( $j->{schedule}, '0 6 * * *', 'the schedule is still read' );
is( $j->{enabled},  0,           'a disabled job is still disabled' );

# several "=" and awkward spacing
$ct = roundtrip( name => 'a=b=c', description => 'x = y' );
($j) = @{ $job->get_plugin_managed_jobs($ct) };
is( $j->{name},        'a=b=c', 'several = in a name' );

# Config::Crontab keeps only the name and value of what it takes for an
# environment line, so spaces around the "=" can't be recovered: "x = y" comes
# back as "x=y". A known, small normalisation; the alternative was losing the
# whole description.
is( $j->{description}, 'x=y', 'spaces around = in a description are normalised (the rest is kept)' );

# a name without "=" is unaffected
$ct = roundtrip( name => 'Plain name', description => 'plain' );
($j) = @{ $job->get_plugin_managed_jobs($ct) };
is( $j->{name}, 'Plain name', 'a name without = is as before' );

# --- environment: only active assignments count ----------------------------------------------------
$ct = roundtrip( name => 'With env', description => 'a=b', environment => { MAILTO => 'ops@example.org' } );
($j) = @{ $job->get_plugin_managed_jobs($ct) };
is_deeply( $j->{environment}, { MAILTO => 'ops@example.org' }, 'a real variable is reported, the = in the description is not' );

my ($block) = $ct->blocks;
is_deeply( $job->block_environment($block), { MAILTO => 'ops@example.org' }, 'block_environment reports only active assignments' );

# --- saving again keeps the name and description ----------------------------------------------------
$ct = roundtrip( name => 'Nightly a=b report', description => 'x=y' );
($block) = $ct->blocks;
ok( $job->update_job_block( $block, { schedule => '30 7 * * *' } ), 'a job with = in its name can be updated' );
my $after = Config::Crontab->new();
$after->last($block);
open my $fh, '>', "$dir/ct2" or die $!;
print {$fh} $after->dump;
close $fh;
my $reread = Config::Crontab->new();
$reread->mode('block');
$reread->read( -file => "$dir/ct2" );
($j) = @{ $job->get_plugin_managed_jobs($reread) };
is( $j->{name},        'Nightly a=b report', 'the name survives an update' );
is( $j->{description}, 'x=y',                'the description survives an update' );
is( $j->{schedule},    '30 7 * * *',         'the update applied' );
is_deeply( $j->{environment}, {}, 'and the update did not turn the metadata into environment variables' );

# --- restore validation no longer trips on such a job ------------------------------------------------------
my $fields = $job->validate_job_fields($j);
ok( $fields->{valid}, 'the job passes field validation (it used to fail on a bogus environment variable name)' );

done_testing();
