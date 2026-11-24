use Modern::Perl;
use Test::More tests => 12;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');
my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );
my $dir    = tempdir( CLEANUP => 1 );

sub parse {
    my ( $name, $content ) = @_;
    open my $fh, '>', "$dir/$name" or die $!;
    print {$fh} $content;
    close $fh;
    return $script->parse_script_options("$dir/$name");
}

# A script on Koha::Script->describe_options: its required flags are authoritative
my $converted = parse( 'converted.pl', <<'PERL');
my $opt = Koha::Script->describe_options(
    '%c %o',
    [ 'hours|h=i', 'hours', { required => 1 } ],
    [ 'verbose|v', 'verbose' ],
);
PERL
is( $converted->{uses_describe_options}, 1, 'describe_options script: uses_describe_options is set' );
is_deeply( [ map { $_->{name} . ':' . $_->{required} } @{ $converted->{options} } ], [ 'hours:1', 'verbose:0' ], 'describe_options script: required flags come from the script' );

# A plain GetOptions script: no reliable required-ness
my $plain = parse( 'plain.pl', <<'PERL');
use Getopt::Long;
GetOptions( 'hours|h=i' => \$hours, 'verbose|v' => \$verbose );
PERL
is( $plain->{uses_describe_options}, 0, 'GetOptions script: uses_describe_options is false' );
is_deeply( [ map { $_->{required} } @{ $plain->{options} } ], [ 0, 0 ], 'GetOptions script: nothing is required' );

# A mention of describe_options in a comment does not count
my $comment = parse( 'comment.pl', <<'PERL');
# TODO: convert to Koha::Script->describe_options( ... )
use Getopt::Long;
GetOptions( 'verbose|v' => \$verbose );
PERL
is( $comment->{uses_describe_options}, 0, 'a describe_options mention in a comment does not set uses_describe_options' );

# No options at all, and unreadable files, still carry the key
my $none = parse( 'none.pl', "print 'hi';\n" );
is( $none->{uses_describe_options}, 0,  'a script with no options: uses_describe_options is false' );
is_deeply( $none->{options}, [], 'a script with no options: no options' );

my $missing = $script->parse_script_options("$dir/does-not-exist.pl");
is( $missing->{uses_describe_options}, 0, 'a missing file: uses_describe_options is false' );
is_deeply( $missing->{options}, [], 'a missing file: no options' );

# Real-world shape: a required option plus a positional args block
my $both = parse( 'both.pl', <<'PERL');
my $opt = Koha::Script->describe_options(
    '%c %o dir',
    [ 'split|s', 'split' ],
    { args => { min => 1, name => 'dir' } },
);
PERL
is( $both->{uses_describe_options}, 1, 'describe_options with a positional args block: uses_describe_options is set' );
is( scalar @{ $both->{positional_args} }, 1, '...and the positional requirement is reported' );
