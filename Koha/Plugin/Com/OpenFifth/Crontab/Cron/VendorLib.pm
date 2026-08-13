package Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;

use Modern::Perl;
use Module::Metadata;

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib - bundled Config::Crontab bootstrap

=head1 SYNOPSIS

    use Koha::Plugin::Com::OpenFifth::Crontab::Cron::VendorLib;
    use Config::Crontab;

=head1 DESCRIPTION

Puts this plugin's bundled copy of C<Config::Crontab> onto C<@INC> if a real
one isn't already available. C<@INC> changes are process-global, but every
file in this plugin that uses C<Config::Crontab> must be independently
loadable -- e.g. under an isolated C<perl -c> syntax check -- so this can't
rely on being loaded as a side effect of the main plugin module. Any file
that does C<use Config::Crontab;> must C<use> this module first.

=cut

## Suppress redefinition warnings from bundled Config::Crontab.
## These occur when install_plugins.pl loads plugins multiple times
## with nocache => 1, forcing module recompilation.
$SIG{__WARN__} = sub {
    my $msg = shift;
    return if $msg =~ /(?:Subroutine|Constant subroutine) .* redefined at .*Config\/Crontab\.pm/;
    CORE::warn($msg);
};

unless ( eval { require Config::Crontab; 1 } ) {
    my $path = Module::Metadata->find_module_by_name('Koha::Plugin::Com::OpenFifth::Crontab');
    $path =~ s{[.]pm$}{/lib}xms;
    unshift @INC, $path;
}

1;
