# Migrate System Crontab Entries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin migrate an unmanaged ("system") crontab entry into a plugin-managed job in one click, preserving its schedule/command/enabled-state exactly, subject to the same script-allowlist and script-policy (non-repeatable/allowed-hours) rules a brand-new job would face.

**Architecture:** A new `POST /jobs/migrate` endpoint re-locates the target unmanaged entry by exact content match (schedule + command + comments — there is no stable ID for unmanaged entries), runs it through the existing `validate_command`/`check_non_repeatable`/`check_allowed_hours` gates exactly as `add` does, then extracts it from its crontab block (splitting a shared multi-event block if needed, via two new `Cron::Job` methods) and rebuilds it as a normal plugin-managed block via the existing `create_job_block`. The UI adds a "Migrate" button to the System Jobs table that submits immediately (no confirmation dialog) and, on success, switches to the Managed Jobs tab and opens the existing Edit Job modal pre-filled with the new job.

**Tech Stack:** Perl (Modern::Perl), `Config::Crontab` (already bundled), `Scalar::Util` (core Perl, new use in this plugin), Mojolicious REST controllers, vanilla JS/jQuery + Bootstrap 5 templates, Test::More run via `koha-prove` inside a KTD instance.

## Global Constraints

- Migration requires the entry's command to pass `validate_command` (the same script-allowlist gate `add` uses) — there is no override or bypass path.
- `non_repeatable`/`allowed_hours` are enforced exactly as they would be for a brand-new `add`, with the entry-being-migrated excluded from its own duplicate/hours scan (it's about to become "the job", not a competing duplicate of itself).
- Entry identification is by exact match on `schedule` + `command` + `comments` (array, same order) — never a positional index. No match found is a `404`, not an attempt to guess.
- No confirmation dialog in the UI — migration submits immediately on click; the auto-opened Edit Job modal is the review step.
- Defaults on migration: `name` = the matched script's filename; `description` = the entry's original comments (joined, leading `#` stripped) or blank if none. The original schedule, command, and enabled/disabled state are preserved unchanged.
- Full spec: `docs/superpowers/specs/2026-08-11-migrate-system-jobs-design.md` (on the `planning` branch).

---

### Task 1: Entry matching and block-splitting in `Cron::Job`

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/Cron/Job.pm` (add `use Scalar::Util`, three new methods, before the trailing `1;`)
- Test: `t/05-migrate-system-jobs.t` (new)

**Interfaces:**
- Produces: `$job->find_unmanaged_entry($ct, $schedule, $command, $comments)` → `($block, $event)` (both `Config::Crontab` objects) if a matching, non-plugin-managed entry is found, or an empty list `()` otherwise. `$job->entry_matches($entry, $schedule, $command, $comments)` → boolean, where `$entry` is a hashref shaped like one element of `get_all_crontab_entries()`'s return (has `schedule`, `command`, `comments` keys). `$job->extract_event_from_block($ct, $block, $event)` → no return value; mutates `$ct` in place (removes the whole block if `$event` was its only event, otherwise filters just `$event` out of the block's lines).
- Consumes: nothing new — `parse_job_metadata` (existing) for the managed/unmanaged check.

- [ ] **Step 1: Write the failing test**

Create `t/05-migrate-system-jobs.t`:

```perl
use Modern::Perl;
use Test::More tests => 12;
use Config::Crontab;
use Scalar::Util qw(refaddr);

my $plugin_dir = $ENV{KOHA_PLUGIN_DIR} || '.';
unshift @INC, $plugin_dir;

use_ok('Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job');

my $job = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new( { crontab => {} } );

my $ct = Config::Crontab->new();

my $block1 = Config::Crontab::Block->new();
$block1->lines(
    [
        Config::Crontab::Comment->new( -data => '# Nightly backup' ),
        Config::Crontab::Event->new( -datetime => '0 2 * * *', -command => '/usr/local/bin/backup.sh' ),
    ]
);
$ct->last($block1);

my $block2 = Config::Crontab::Block->new();
my $finegen_event = Config::Crontab::Event->new( -datetime => '0 3 * * *', -command => '$KOHA_CRON_PATH/finegen.pl' );
my $overdue_event = Config::Crontab::Event->new( -datetime => '0 4 * * *', -command => '$KOHA_CRON_PATH/overdue_notices.pl' );
$block2->lines(
    [
        Config::Crontab::Comment->new( -data => '# Ansible managed group' ),
        $finegen_event,
        $overdue_event,
    ]
);
$ct->last($block2);

my $block3 = Config::Crontab::Block->new();
$block3->lines(
    [
        Config::Crontab::Comment->new( -data => '# @crontab-manager-id: existing-job-uuid' ),
        Config::Crontab::Comment->new( -data => '# @managed-by: koha-crontab-plugin' ),
        Config::Crontab::Event->new( -datetime => '0 5 * * *', -command => '$KOHA_CRON_PATH/membership_expiry.pl' ),
    ]
);
$ct->last($block3);

# find_unmanaged_entry

my ( $found_block, $found_event ) =
  $job->find_unmanaged_entry( $ct, '0 2 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup'] );
ok( refaddr($found_block) == refaddr($block1), 'finds the single-event block' );
is( $found_event->command, '/usr/local/bin/backup.sh', 'returns the matching event' );

my ( $group_block, $group_event ) =
  $job->find_unmanaged_entry( $ct, '0 3 * * *', '$KOHA_CRON_PATH/finegen.pl', ['# Ansible managed group'] );
ok( refaddr($group_block) == refaddr($block2), 'finds the right block within a multi-event group' );
is( $group_event->command, '$KOHA_CRON_PATH/finegen.pl', 'finds the right event within a multi-event group' );

my @no_match = $job->find_unmanaged_entry( $ct, '0 2 * * *', '/usr/local/bin/backup.sh', ['# Wrong comment'] );
is( scalar(@no_match), 0, 'does not match when comments differ' );

my @managed_no_match =
  $job->find_unmanaged_entry( $ct, '0 5 * * *', '$KOHA_CRON_PATH/membership_expiry.pl',
    [ '# @crontab-manager-id: existing-job-uuid', '# @managed-by: koha-crontab-plugin' ] );
is( scalar(@managed_no_match), 0, 'never matches an already-managed block' );

# entry_matches

ok(
    $job->entry_matches(
        { schedule => '0 2 * * *', command => '/usr/local/bin/backup.sh', comments => ['# Nightly backup'] },
        '0 2 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup']
    ),
    'entry_matches is true for an identical entry'
);
ok(
    !$job->entry_matches(
        { schedule => '0 2 * * *', command => '/usr/local/bin/backup.sh', comments => ['# Nightly backup'] },
        '0 9 * * *', '/usr/local/bin/backup.sh', ['# Nightly backup']
    ),
    'entry_matches is false when the schedule differs'
);

# extract_event_from_block

$job->extract_event_from_block( $ct, $block1, $found_event );
is( scalar( grep { refaddr($_) == refaddr($block1) } $ct->blocks ), 0, 'removes the whole block when it held only one event' );

$job->extract_event_from_block( $ct, $block2, $finegen_event );
my @remaining_events = $block2->select( -type => 'event' );
is( scalar(@remaining_events), 1, 'leaves the sibling event in place' );
is( $remaining_events[0]->command, '$KOHA_CRON_PATH/overdue_notices.pl', 'the surviving event is the correct sibling' );
```

- [ ] **Step 2: Run test to verify it fails**

Run (inside a KTD instance, via the `koha-prove` skill or `docker exec <container> bash -c 'KOHA_PLUGIN_DIR=<mounted-path> prove -v <mounted-path>/t/05-migrate-system-jobs.t'`):
Expected: FAIL — `find_unmanaged_entry` etc. not yet defined.

- [ ] **Step 3: Implement the methods**

In `Cron/Job.pm`, add `use Scalar::Util qw(refaddr);` alongside the existing `use` statements:

```perl
use Modern::Perl;
use POSIX qw(strftime);
use UUID;
use Config::Crontab;
use Scalar::Util qw(refaddr);
```

Add after `update_job_block` (before the trailing `1;`):

```perl
=head2 find_unmanaged_entry

Find an unmanaged (non-plugin) block/event pair matching the given
schedule, command, and comments exactly.

    my ( $block, $event ) = $job->find_unmanaged_entry( $ct, $schedule, $command, $comments );

$comments is an arrayref of raw comment line strings, in the same order
$block->select(-type => 'comment') returns them (i.e. as returned by
get_all_crontab_entries's 'comments' field for this entry).

Returns ($block, $event) if found, or an empty list if not. Never matches a
block that's already plugin-managed.

=cut

sub find_unmanaged_entry {
    my ( $self, $ct, $schedule, $command, $comments ) = @_;

    $comments ||= [];

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        my $is_managed =
             $metadata
          && $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';
        next if $is_managed;

        my @block_comments = map { $_->data } $block->select( -type => 'comment' );
        next unless _comments_match( \@block_comments, $comments );

        for my $event ( $block->select( -type => 'event' ) ) {
            next unless $event->datetime eq $schedule && $event->command eq $command;
            return ( $block, $event );
        }
    }

    return ();
}

=head2 entry_matches

Check whether a get_all_crontab_entries()-shaped entry matches the given
schedule, command, and comments exactly.

    my $matches = $job->entry_matches( $entry, $schedule, $command, $comments );

=cut

sub entry_matches {
    my ( $self, $entry, $schedule, $command, $comments ) = @_;

    return 0 unless $entry->{schedule} eq $schedule && $entry->{command} eq $command;
    return _comments_match( $entry->{comments} || [], $comments || [] );
}

=head2 extract_event_from_block

Remove a single event from a block, preserving any sibling events and the
block's own comments. If the event is the block's only event, the entire
block is removed from the crontab instead.

    $job->extract_event_from_block( $ct, $block, $event );

=cut

sub extract_event_from_block {
    my ( $self, $ct, $block, $event ) = @_;

    my @events = $block->select( -type => 'event' );

    if ( scalar(@events) <= 1 ) {
        $ct->remove($block);
        return;
    }

    my $target_addr      = refaddr($event);
    my @remaining_lines = grep { refaddr($_) != $target_addr } $block->lines;
    $block->lines( \@remaining_lines );

    return;
}

=head2 _comments_match

Compare two arrayrefs of raw comment line strings for exact equality
(same length, same strings, same order).

=cut

sub _comments_match {
    my ( $a, $b ) = @_;

    return 0 unless scalar(@$a) == scalar(@$b);
    for my $i ( 0 .. $#$a ) {
        return 0 unless $a->[$i] eq $b->[$i];
    }
    return 1;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2.
Expected: PASS (12/12).

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/Cron/Job.pm t/05-migrate-system-jobs.t
git commit -m "feat: add entry-matching and block-splitting helpers for job migration"
```

---

### Task 2: `POST /jobs/migrate` endpoint

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm` (add `migrate` action, before the `Internal Methods` section)
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json` (new `/jobs/migrate` top-level path)

**Interfaces:**
- Consumes: `$job_model->find_unmanaged_entry`, `$job_model->entry_matches`, `$job_model->extract_event_from_block` (Task 1); `$script_model->validate_command`, `check_non_repeatable`, `check_allowed_hours` (existing, from the script-policy feature); `$job_model->get_all_crontab_entries`, `generate_job_id`, `create_job_block` (existing).
- Produces: `POST /api/v1/contrib/crontab/jobs/migrate` — `201` with the same response shape as `add`, `400` for allowlist/policy violations (same error shapes `add` uses), `404` (`{error: "Entry not found"}`) if no matching unmanaged entry exists, `500` on unexpected errors.

There is no automated test for REST controllers in this repo (same posture as every prior REST-touching task) — verified manually against a running KTD instance in Step 3.

- [ ] **Step 1: Add the `migrate` action**

In `Jobs.pm`, add after the `add` sub (before `=head3 update`):

```perl
=head3 migrate

Migrate an unmanaged (system) crontab entry into a plugin-managed job

=cut

sub migrate {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = _check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::OpenFifth::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $body = $c->req->json;

    for my $field (qw/schedule command/) {
        unless ( $body->{$field} ) {
            return $c->render(
                status  => 400,
                openapi => { error => "Missing required field: $field" }
            );
        }
    }

    my $comments = $body->{comments} || [];

    try {
        my $crontab = Koha::Plugin::Com::OpenFifth::Crontab::Cron::File->new(
            { plugin => $plugin, }
        );
        my $job_model = Koha::Plugin::Com::OpenFifth::Crontab::Cron::Job->new(
            { crontab => $crontab }
        );
        my $script_model =
          Koha::Plugin::Com::OpenFifth::Crontab::Cron::Script->new(
            { crontab => $crontab }
          );

        # Validate command uses approved script, exactly as `add` does
        my $validation = $script_model->validate_command( $body->{command} );
        unless ( $validation->{valid} ) {
            return $c->render(
                status  => 400,
                openapi => { error => $validation->{error} }
            );
        }

        if ( my $policy = $validation->{policy} ) {
            my $all_entries = $job_model->get_all_crontab_entries();

            # Exclude the entry being migrated from its own duplicate/hours scan
            my @other_entries =
              grep { !$job_model->entry_matches( $_, $body->{schedule}, $body->{command}, $comments ) }
              @$all_entries;

            if ( $policy->{non_repeatable} ) {
                my $check = $script_model->check_non_repeatable( $validation->{script}, \@other_entries, undef );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }

            if ( $policy->{allowed_hours} ) {
                my $check = $script_model->check_allowed_hours( $policy->{allowed_hours}, $body->{schedule} );
                unless ( $check->{valid} ) {
                    return $c->render( status => 400, openapi => { error => $check->{error} } );
                }
            }
        }

        my $job_id      = $job_model->generate_job_id();
        my $now         = strftime( "%Y-%m-%d %H:%M:%S", localtime );
        my $description = join( "\n", map { my $line = $_; $line =~ s/^\s*#\s?//; $line } @$comments );
        my $migrated_job;

        my $result = $crontab->safely_modify_crontab(
            sub {
                my ($ct) = @_;

                my ( $block, $event ) =
                  $job_model->find_unmanaged_entry( $ct, $body->{schedule}, $body->{command}, $comments );
                unless ($block) {
                    die "Entry not found";
                }

                my $was_enabled = $event->active ? 1 : 0;

                $job_model->extract_event_from_block( $ct, $block, $event );

                my $new_block = $job_model->create_job_block(
                    {
                        id          => $job_id,
                        name        => $validation->{script}->{name},
                        description => $description,
                        schedule    => $body->{schedule},
                        command     => $body->{command},
                        enabled     => $was_enabled,
                        created     => $now,
                        updated     => $now,
                    }
                );

                $ct->last($new_block);

                $migrated_job = {
                    name    => $validation->{script}->{name},
                    enabled => $was_enabled,
                };

                return 1;
            }
        );

        unless ( $result->{success} ) {
            if ( $result->{error} =~ /Entry not found/ ) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Entry not found" }
                );
            }
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'ADD', $job_id,
            "CrontabPlugin: Migrated system job to managed job '" . $migrated_job->{name} . "'" )
          if $logging;

        return $c->render(
            status  => 201,
            openapi => {
                id          => $job_id,
                name        => $migrated_job->{name},
                description => $description,
                schedule    => $body->{schedule},
                command     => $body->{command},
                enabled     => $migrated_job->{enabled}
                ? Mojo::JSON->true
                : Mojo::JSON->false,
                environment => {},
                created_at  => $now,
                updated_at  => $now
            }
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to migrate job: $_" }
        );
    };
}
```

- [ ] **Step 2: Add the openapi path**

In `api/openapi.json`, add a new top-level key `/jobs/migrate` (place it after `/jobs/{job_id}/disable` and before `/backup`, keeping jobs-related paths grouped):

```json
  "/jobs/migrate": {
    "post": {
      "x-mojo-to": "Com::OpenFifth::Crontab::REST::V1::Cron::Jobs#migrate",
      "operationId": "migrateCrontabJob",
      "tags": [
        "cronjobs"
      ],
      "produces": [
        "application/json"
      ],
      "consumes": [
        "application/json"
      ],
      "parameters": [
        {
          "name": "body",
          "in": "body",
          "required": true,
          "description": "Identifies the exact unmanaged crontab entry to migrate",
          "schema": {
            "type": "object",
            "required": [
              "schedule",
              "command"
            ],
            "properties": {
              "schedule": {
                "type": "string",
                "description": "Cron schedule expression of the entry to migrate"
              },
              "command": {
                "type": "string",
                "description": "Command of the entry to migrate. Must use a script from the approved scripts list."
              },
              "comments": {
                "type": "array",
                "description": "Raw comment lines above the entry, as returned by /crontab/all, used to uniquely identify it",
                "items": {
                  "type": "string"
                }
              }
            }
          }
        }
      ],
      "responses": {
        "201": {
          "description": "Entry migrated to a managed job successfully",
          "schema": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "description": "Unique job identifier"
              },
              "name": {
                "type": "string",
                "description": "Human-readable job name"
              },
              "description": {
                "type": "string",
                "description": "Optional job description"
              },
              "schedule": {
                "type": "string",
                "description": "Cron schedule expression"
              },
              "command": {
                "type": "string",
                "description": "Command to execute"
              },
              "enabled": {
                "type": "boolean",
                "description": "Whether the job is enabled"
              },
              "environment": {
                "type": "object",
                "description": "Environment variables for the job"
              },
              "created_at": {
                "description": "Job creation timestamp"
              },
              "updated_at": {
                "description": "Job last update timestamp"
              }
            }
          }
        },
        "400": {
          "description": "Bad request"
        },
        "401": {
          "description": "Authentication required"
        },
        "403": {
          "description": "Access forbidden"
        },
        "404": {
          "description": "Entry not found"
        },
        "500": {
          "description": "Internal server error"
        }
      }
    }
  },
```

(Note the trailing comma — this key is being inserted between two existing keys in the path map, not appended last.)

- [ ] **Step 3: Manually verify against a running KTD instance**

With a KTD instance running (`kd up` or `ktd --single-plugin <repo-path> up -d`) and this plugin enabled:

1. Add a system-only crontab line by hand (e.g. via `docker exec <container> bash -c "echo '0 2 * * * /bin/true' >> <crontab-file>"` or by editing the crontab the plugin manages directly) that uses a script the allowlist approves (e.g. `$KOHA_CRON_PATH/advance_notices.pl`), with a comment line above it.
2. `GET /api/v1/contrib/crontab/crontab/all`, find that entry, and `POST /api/v1/contrib/crontab/jobs/migrate` with its exact `schedule`/`command`/`comments`. Confirm `201` and that the response's `name` matches the script's filename and `description` matches the stripped comment text.
3. `GET /api/v1/contrib/crontab/crontab/all` again — confirm the entry no longer appears as unmanaged (`managed: false`), and `GET /api/v1/contrib/crontab/jobs` shows it as a managed job with the original schedule/enabled-state intact.
4. Repeat with a command that does NOT match any approved script — confirm `400` with the same error `add` gives for an unapproved command.
5. Repeat the migrate call a second time with the same (now-already-migrated) schedule/command/comments — confirm `404` (`"Entry not found"`), since it's no longer an unmanaged entry.
6. If a `non_repeatable` or `allowed_hours` policy is active on the target script, confirm migrating a schedule that would violate it is rejected with `400`, and a compliant one succeeds.
7. Manually add a crontab block with two event lines sharing one comment header, migrate one of them, and confirm the other survives untouched in its original block with the original comment.

- [ ] **Step 4: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/REST/V1/Cron/Jobs.pm \
        Koha/Plugin/Com/OpenFifth/Crontab/api/openapi.json
git commit -m "feat: add endpoint to migrate a system crontab entry to a managed job"
```

---

### Task 3: "Migrate" button and auto-opened edit modal

**Files:**
- Modify: `Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt`

**Interfaces:**
- Consumes: `POST /api/v1/contrib/crontab/jobs/migrate` (Task 2); reuses the existing `openJobModal(jobId)` function unchanged (already fetches and populates the Edit Job modal from a job id).

No automated test (template + JS, no test harness for this plugin's UI exists). Verified manually in Step 4.

- [ ] **Step 1: Add an Actions column to the System Jobs table**

Replace:

```html
                                <table class="table table-striped" id="system_jobs_table">
                                    <thead>
                                        <tr>
                                            <th>Status</th>
                                            <th>Schedule</th>
                                            <th>Command</th>
                                            <th>Comments</th>
                                        </tr>
                                    </thead>
                                    <tbody id="system_jobs_tbody">
                                        <!-- System jobs will be loaded dynamically -->
                                    </tbody>
                                </table>
```

with:

```html
                                <table class="table table-striped" id="system_jobs_table">
                                    <thead>
                                        <tr>
                                            <th>Status</th>
                                            <th>Schedule</th>
                                            <th>Command</th>
                                            <th>Comments</th>
                                            <th>Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody id="system_jobs_tbody">
                                        <!-- System jobs will be loaded dynamically -->
                                    </tbody>
                                </table>
```

Also update the info alert just above it — replace:

```html
                                <div class="alert alert-info">
                                    <i class="fa fa-info-circle"></i> These jobs are managed outside this plugin (e.g., by Ansible, manually, or other tools).
                                    They are displayed as <strong>read-only</strong> for your reference to avoid scheduling conflicts.
                                </div>
```

with:

```html
                                <div class="alert alert-info">
                                    <i class="fa fa-info-circle"></i> These jobs are managed outside this plugin (e.g., by Ansible, manually, or other tools).
                                    They are shown for reference to avoid scheduling conflicts. Jobs using an approved script can be <strong>migrated</strong> into plugin management.
                                </div>
```

- [ ] **Step 2: Disable sorting on the new Actions column**

Replace:

```javascript
            systemJobsTable = $('#system_jobs_table').DataTable({
                "paging": true,
                "lengthChange": true,
                "searching": true,
                "ordering": true,
                "info": true,
                "autoWidth": false
            });
```

with:

```javascript
            systemJobsTable = $('#system_jobs_table').DataTable({
                "paging": true,
                "lengthChange": true,
                "searching": true,
                "ordering": true,
                "info": true,
                "autoWidth": false,
                "columnDefs": [
                    { "orderable": false, "targets": -1 } // Disable sorting on Actions column
                ]
            });
```

- [ ] **Step 3: Render the Migrate button and add the extra empty-state cell**

Replace:

```javascript
            if (systemJobs.length === 0) {
                systemJobsTable.row.add([
                    '<span class="text-muted">-</span>',
                    '<span class="text-muted">-</span>',
                    '<span class="text-muted">No system jobs found</span>',
                    '<span class="text-muted">-</span>'
                ]);
            } else {
                systemJobs.forEach(function(entry) {
                    let statusBadge = entry.enabled
                        ? '<span class="badge bg-success">Enabled</span>'
                        : '<span class="badge bg-secondary">Disabled</span>';

                    let comments = '';
                    if (entry.comments && entry.comments.length > 0) {
                        comments = entry.comments.map(c => '<div class="text-muted small">' + c + '</div>').join('');
                    } else {
                        comments = '<span class="text-muted">No comments</span>';
                    }

                    // Build command cell with documentation button if it's a Perl script
                    let scriptInfo = extractScriptInfo(entry.command);
                    let commandHtml = '<div><code>' + escapeHtml(entry.command) + '</code>';
                    if (scriptInfo.isPerlScript) {
                        // Escape command for use in data attribute
                        let escapedCommand = entry.command.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
                        commandHtml += ' <button class="btn btn-xs btn-info view-doc-btn ms-1" data-command="' + escapedCommand + '" title="View documentation"><i class="fa fa-book"></i></button>';
                    }
                    commandHtml += '</div>';

                    systemJobsTable.row.add([
                        statusBadge,
                        '<code class="schedule-preview">' + entry.schedule + '</code>',
                        commandHtml,
                        comments
                    ]);
                });
            }
```

with:

```javascript
            if (systemJobs.length === 0) {
                systemJobsTable.row.add([
                    '<span class="text-muted">-</span>',
                    '<span class="text-muted">-</span>',
                    '<span class="text-muted">No system jobs found</span>',
                    '<span class="text-muted">-</span>',
                    '<span class="text-muted">-</span>'
                ]);
            } else {
                systemJobs.forEach(function(entry) {
                    let statusBadge = entry.enabled
                        ? '<span class="badge bg-success">Enabled</span>'
                        : '<span class="badge bg-secondary">Disabled</span>';

                    let comments = '';
                    if (entry.comments && entry.comments.length > 0) {
                        comments = entry.comments.map(c => '<div class="text-muted small">' + c + '</div>').join('');
                    } else {
                        comments = '<span class="text-muted">No comments</span>';
                    }

                    // Build command cell with documentation button if it's a Perl script
                    let scriptInfo = extractScriptInfo(entry.command);
                    let commandHtml = '<div><code>' + escapeHtml(entry.command) + '</code>';
                    if (scriptInfo.isPerlScript) {
                        // Escape command for use in data attribute
                        let escapedCommand = entry.command.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
                        commandHtml += ' <button class="btn btn-xs btn-info view-doc-btn ms-1" data-command="' + escapedCommand + '" title="View documentation"><i class="fa fa-book"></i></button>';
                    }
                    commandHtml += '</div>';

                    let escapedScheduleAttr = entry.schedule.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
                    let escapedCommandAttr = entry.command.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
                    let commentsAttr = encodeURIComponent(JSON.stringify(entry.comments || []));
                    let migrateHtml = '<button class="btn btn-xs btn-success migrate-job" data-schedule="' + escapedScheduleAttr + '" data-command="' + escapedCommandAttr + '" data-comments="' + commentsAttr + '">' +
                        '<i class="fa fa-arrow-right"></i> Migrate</button>';

                    systemJobsTable.row.add([
                        statusBadge,
                        '<code class="schedule-preview">' + entry.schedule + '</code>',
                        commandHtml,
                        comments,
                        migrateHtml
                    ]);
                });
            }
```

- [ ] **Step 4: Bind the Migrate button and handle the response**

Replace:

```javascript
            // Bind action handlers for system jobs doc buttons
            $('.view-doc-btn').off('click').on('click', function() {
                let command = $(this).attr('data-command');
                viewScriptDocumentation(command);
            });
        }
```

with:

```javascript
            // Bind action handlers for system jobs doc buttons
            $('.view-doc-btn').off('click').on('click', function() {
                let command = $(this).attr('data-command');
                viewScriptDocumentation(command);
            });

            $('.migrate-job').off('click').on('click', function() {
                let schedule = $(this).attr('data-schedule');
                let command = $(this).attr('data-command');
                let comments = JSON.parse(decodeURIComponent($(this).attr('data-comments')));

                $.ajax({
                    url: '/api/v1/contrib/crontab/jobs/migrate',
                    method: 'POST',
                    data: JSON.stringify({ schedule: schedule, command: command, comments: comments }),
                    contentType: 'application/json',
                    success: function(job) {
                        showMessage('System job migrated to a managed job', 'success');
                        loadJobs();
                        loadAllCrontabEntries();
                        new bootstrap.Tab(document.getElementById('managed-tab')).show();
                        openJobModal(job.id);
                    },
                    error: function(xhr, status, error) {
                        let message = 'Failed to migrate job';
                        if (xhr.responseJSON && xhr.responseJSON.error) {
                            message += ': ' + xhr.responseJSON.error;
                        }
                        showMessage(message, 'danger');
                    }
                });
            });
        }
```

- [ ] **Step 5: Manually verify against a running KTD instance**

With a KTD instance running and a system entry present that uses an approved script (per Task 2 Step 3's setup):

1. Open the plugin's admin page, System Jobs tab. Confirm the row shows a "Migrate" button in a new Actions column.
2. Click it. Confirm: a success message appears, the entry disappears from the System Jobs tab, the view switches to the Managed Jobs tab, and the Edit Job modal opens automatically pre-filled with the migrated job's name (the script's filename), description (from the original comments, if any), schedule, and command.
3. Click Migrate on an entry whose command isn't an approved script (if one exists in the test crontab). Confirm the error message from the server appears via the existing danger-alert pattern, and the entry remains in the System Jobs tab.
4. Migrate one line out of a multi-event shared block (per Task 2 Step 3.7) and confirm the sibling entry still renders correctly, unaffected, in the System Jobs tab afterward.

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugin/Com/OpenFifth/Crontab/crontab.tt
git commit -m "feat: add migrate button to the system jobs table"
```

---

### Task 4: Changelog

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added` (append to the existing list if the script-policy feature's entries are still there, or create the section if not):

```markdown
- Migrate a system (unmanaged) crontab entry into a plugin-managed job directly from the System Jobs tab, preserving its schedule, command, and enabled state
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for system job migration"
```
