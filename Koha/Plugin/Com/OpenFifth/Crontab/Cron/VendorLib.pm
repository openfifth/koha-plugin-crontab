# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright 2023-2026 Open Fifth and contributors
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

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
