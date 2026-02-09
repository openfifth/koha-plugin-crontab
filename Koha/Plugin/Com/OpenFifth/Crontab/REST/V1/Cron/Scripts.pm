use utf8;

package Koha::Plugin::Com::OpenFifth::Crontab::REST::V1::Cron::Scripts;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use Koha::Plugin::Com::OpenFifth::Crontab;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::File;
use Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script;
use Try::Tiny;

=head1 NAME

Koha::Plugin::Com::OpenFifth::Crontab::REST::V1::Cron::Scripts

=head1 API

=head2 Class Methods

=head3 list

List all available scripts from KOHA_CRON_PATH

=cut

sub list {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    try {
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $script_model =
          Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
          );

        # Check if bypass_filter parameter is provided (for configuration page)
        my $bypass_filter = $c->validation->param('bypass_filter') || 0;
        my $options = $bypass_filter ? { bypass_filter => 1 } : {};

        my $scripts = $script_model->get_available_scripts($options);

        return $c->render(
            status  => 200,
            openapi => { scripts => $scripts }
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch scripts: $_" }
        );
    };
}

=head3 get

Get detailed documentation and options for a specific script

=cut

sub get {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    my $script_name = $c->validation->param('name');

    try {
        my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $script_model =
          Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
          );

        # Get all scripts and find the requested one
        my $scripts = $script_model->get_available_scripts();
        my ($script) = grep { $_->{name} eq $script_name } @$scripts;

        unless ($script) {
            return $c->render(
                status  => 404,
                openapi => { error => "Script not found" }
            );
        }

        # Parse documentation and options
        my $doc    = $script_model->parse_script_documentation( $script->{path} );
        my $parsed = $script_model->parse_script_options( $script->{path} );

        return $c->render(
            status  => 200,
            openapi => {
                name            => $script->{name},
                path            => $script->{relative_path},
                type            => $script->{type},
                description     => $doc->{name_brief} || '',
                usage_text      => $doc->{usage_text} || '',
                options         => $parsed->{options},
                positional_args => $parsed->{positional_args},
            }
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch script details: $_" }
        );
    };
}

=head2 Internal Methods

=head3 _check_user_allowlist

Check if the current user is authorized to use the plugin

=cut

sub _check_user_allowlist {
    my ($c) = @_;

    # Check if user is logged in
    my $userenv = C4::Context->userenv;
    unless ( $userenv && $userenv->{number} ) {
        return $c->render(
            status  => 401,
            openapi => { error => "Authentication required" }
        );
    }

    # Superlibrarians always have access
    my $is_superlibrarian = $userenv->{flags} && $userenv->{flags} == 1;
    return undef if $is_superlibrarian;

    # Check allowlist if configured
    my $plugin         = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
    my $user_allowlist = $plugin->retrieve_data('user_allowlist');

    if ($user_allowlist) {
        my @borrowernumbers = split( /\s*,\s*/, $user_allowlist );
        my $bn              = $userenv->{number};

        if ( grep( /^$bn$/, @borrowernumbers ) ) {
            return undef;
        }
        else {
            return $c->render(
                status  => 401,
                openapi =>
                  { error => "You are not authorised to use this plugin" }
            );
        }
    }

    # If no allowlist is configured, allow access
    return undef;
}

1;
