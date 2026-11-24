use Modern::Perl;
use Test::More tests => 15;
use File::Temp qw(tempdir);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script');

my $script = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new( { crontab => {} } );
my $dir    = tempdir( CLEANUP => 1 );

sub parse_content {
    my ( $name, $content ) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die $!;
    print {$fh} $content;
    close $fh;
    return $script->parse_script_options($path);
}

# Verbatim from misc/cronjobs/gather_print_notices.pl: a non-variadic
# positional requirement declared via the trailing args hashref, no
# required named options.
my $gather = parse_content( 'gather_print_notices.pl', <<'PERL');
my ( $opt, $usage ) = Koha::Script->describe_options(
    'Print all waiting print notices to output_directory.

The generated filename will be notices-TODAY.[csv|html|ods], or
notices-TODAY-BRANCHCODE.[csv|html|ods] if --split is given.

%c %o output_directory',
    [ 'split|s',        'split messages into separate files by borrower home library' ],
    [ 'html',           'generate the print notices in a html file (default, if --csv and --ods are not given)' ],
    [ 'csv',            'generate the print notices in a csv file; must be combined with exactly one --letter_code' ],
    [ 'ods',            'generate the print notices in a ods file; must be combined with exactly one --letter_code' ],
    [ 'delimiter|d:s',  'delimiter used when parsing content for --ods (default: comma)' ],
    [ 'letter_code:s@', 'filter print messages by letter_code, repeatable' ],
    [
        'send!', 'change message status from pending to sent after generating files (default: on; --nosend to disable)',
        { default => 1 }
    ],
    [ 'email|e:s@', 'email address to send the generated files to, repeatable' ],
    { args => { min => 1, name => 'output_directory' } },
);
PERL

is_deeply(
    [ map { $_->{name} } @{ $gather->{options} } ],
    [qw(split html csv ods delimiter letter_code send email)],
    'gather_print_notices.pl: all eight options found'
);
is( ( grep { $_->{required} } @{ $gather->{options} } ) + 0, 0, 'gather_print_notices.pl: no named option is required' );
is( scalar @{ $gather->{positional_args} },          1,                  'gather_print_notices.pl: one positional requirement' );
is( $gather->{positional_args}[0]{name},             'output_directory', 'gather_print_notices.pl: positional name' );
is( $gather->{positional_args}[0]{min},              1,                  'gather_print_notices.pl: positional min' );
is( $gather->{positional_args}[0]{variadic},         0,                  'gather_print_notices.pl: not variadic' );

# Verbatim (options only) from misc/cronjobs/update_patrons_category.pl:
# two required options side by side, a hash-valued option (s%), a
# concatenated epilog and a possessive apostrophe inside a double-quoted
# string in the trailing hashref.
my $upc = parse_content( 'update_patrons_category.pl', <<'PERL');
my $opt = Koha::Script->describe_options(
    'Update patrons from one category to another, based on optional filtering criteria. Options are cumulative.

%c %o',
    [ 'from|f=s',        'change patron category from this category (categories.categorycode)', { required => 1 } ],
    [ 'to|t=s',          'change patron category to this category (categories.categorycode)',   { required => 1 } ],
    [ 'branch|b=s',      'only deal with patrons from this library/branch' ],
    [ 'too_old',         'update patron only if above the maximum age range for the "from" category' ],
    [ 'too_young',       'update patron only if below the minimum age range for the "from" category' ],
    [ 'finesover|fo=s',  'only update patrons with fines over this amount' ],
    [ 'finesunder|fu=s', 'only update patrons with fines under this amount' ],
    [ 'regbefore|rb=s',  'only update patrons registered before this date (YYYY-MM-DD)' ],
    [ 'regafter|ra=s',   'only update patrons registered after this date (YYYY-MM-DD)' ],
    [
        'field|d=s%',
        'update patrons where this borrowers column equals this value (repeatable); "null" checks for an unset field'
    ],
    [ 'where=s@',  'a raw WHERE condition, built from borrowers columns, to add to the query (repeatable)' ],
    [ 'verbose|v', 'verbose output' ],
    [ 'confirm|c', 'commit changes to the database; without this, changes are reported but not made' ],
    {
              epilog => "Examples:\n"
            . "  %c --from CATCODE1 --to CATCODE2 --branch BRANCHCODE --confirm\n"
            . "    Update patrons over CATCODE1's maximum age from CATCODE1 to CATCODE2.\n",
    },
);
PERL

is( scalar @{ $upc->{options} }, 13, 'update_patrons_category.pl: all thirteen options found' );
is_deeply(
    [ map { $_->{name} } grep { $_->{required} } @{ $upc->{options} } ],
    [qw(from to)],
    'update_patrons_category.pl: exactly from and to are required'
);
is_deeply( $upc->{positional_args}, [], 'update_patrons_category.pl: no positional requirement' );

# --- detection must be anchored to a real Koha::Script->describe_options call ---

my $plain_with_comment = parse_content( 'comment_mention.pl', <<'PERL');
use Getopt::Long;
# TODO: convert this to Koha::Script->describe_options( ... ) once core lands
GetOptions(
    'verbose|v' => \$verbose,
    'confirm'   => \$confirm,
);
PERL
is_deeply(
    [ map { $_->{name} } @{ $plain_with_comment->{options} } ],
    [qw(verbose confirm)],
    'a comment mentioning describe_options does not divert a GetOptions script'
);

my $plain_with_pod = parse_content( 'pod_mention.pl', <<'PERL');
use Getopt::Long;
GetOptions(
    'verbose|v' => \$verbose,
    'confirm'   => \$confirm,
);

=head1 NAME

pod_mention.pl - see Koha::Script->describe_options( 'x', [ 'bogus=s', 'y' ] )

=cut
PERL
is_deeply(
    [ map { $_->{name} } @{ $plain_with_pod->{options} } ],
    [qw(verbose confirm)],
    'POD mentioning describe_options does not divert a GetOptions script'
);

my $unrelated = parse_content( 'other_class.pl', <<'PERL');
use Getopt::Long;
GetOptions( 'verbose|v' => \$verbose );
my $thing = Some::Other->describe_options( [ 'bogus=s', 'nope' ] );
PERL
is_deeply(
    [ map { $_->{name} } @{ $unrelated->{options} } ],
    ['verbose'],
    'describe_options on some other class is not treated as Koha::Script'
);

my $in_end = parse_content( 'after_end.pl', <<'PERL');
use Getopt::Long;
GetOptions( 'verbose|v' => \$verbose );
__END__
my $opt = Koha::Script->describe_options( 'x', [ 'bogus=s', 'nope' ] );
PERL
is_deeply(
    [ map { $_->{name} } @{ $in_end->{options} } ],
    ['verbose'],
    'a describe_options call after __END__ is ignored'
);

my $one_line = parse_content( 'one_line.pl', <<'PERL');
my $opt = Koha::Script -> describe_options('%c %o', ['hours|h=i', 'h', { required => 1 }]);
PERL
is_deeply(
    [ map { [ $_->{name}, $_->{required} ] } @{ $one_line->{options} } ],
    [ [ 'hours', 1 ] ],
    'whitespace around -> and a single-line call are still recognised'
);
