#!/usr/bin/env perl

use strict;
use warnings;
use JSON::PP;

# Load Koha environment
BEGIN {
    my $koha_cron_path = '/usr/share/koha/bin/cronjobs';
    if (-d $koha_cron_path) {
        push @INC, '/usr/share/koha';
    }
}

# Setup the plugin
my $plugin_dir = '/home/martin/Projects/koha/plugins/koha-plugin-crontab';
push @INC, $plugin_dir;
push @INC, "$plugin_dir/lib";

require Koha::Plugin::Com::OpenFifth::Crontab;

my $plugin = Koha::Plugin::Com::OpenFifth::Crontab->new();

# Set a temporary script policy with required_options
my $policy = {
    path => 'longoverdue.pl',
    required_options => ['maxdays'],
    allowed_hours => '',
    non_repeatable => 0
};

$plugin->store_data({
    script_policy => JSON::PP::encode_json([$policy])
});

print "Policy set to require 'maxdays' for longoverdue.pl\n";
