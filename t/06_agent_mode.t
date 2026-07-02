#!/usr/bin/env perl

use strict;
use warnings;
use feature qw/ say /;
use Data::Dumper;
use lib 't/lib';
use Test::More;
use File::Slurp qw/ slurp /;
use File::Temp  qw(tempdir);
use JSON::PP    qw(decode_json);
use Cwd         qw(abs_path getcwd);
use Synergy::Test::Runner
  qw(run_synergy_file_session run_synergy_session setup_test_env write_fake_curl);

use constant OFFLINE_MODE => 1;

my $temp_dir        = tempdir(CLEANUP => 1);
my $temp_dir_simple = q[/tmp];
my $original_cwd    = abs_path();
my $shared_env      = setup_test_env(
    log_dir       => $temp_dir,
    dump_dir      => $temp_dir,
    seed_api_keys => 1,
);

my $cwd            = getcwd;
my $synergy_root   = $shared_env->{root};
my $SYNERGY_SCRIPT = $shared_env->{synergy_script};

if (OFFLINE_MODE) {
    my $curl_dir = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    $ENV{SYNERGY_CURL_CAPTURE_DIR} = $temp_dir
      unless exists $ENV{SYNERGY_CURL_CAPTURE_DIR};
}

my $bell = chr 7;

=head3 Test agent mode auto-pushes AGENTS.md from working directory into context

=cut

{
    my $agent_dir = "$temp_dir/agent_autopush_agents_$$";
    mkdir $agent_dir or die "Cannot create agent test dir: $!";

    my $agents_file = "$agent_dir/AGENTS.md";
    open my $afh, '>', $agents_file or die "Cannot create AGENTS.md: $!";
    print $afh "Auto agent instructions.\nSecond line.\n";
    close $afh;
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec ls\n,comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",cd $agent_dir\n", ",agent autopush agents check\n",
            ",s\n",             ",exit\n"
        ]
    );

    is($results->{exit_code}, 0,
        "agent AGENTS auto-push: agent mode completes");
    like(
        $results->{stdout},
        qr/file: '\Q$agents_file\E'/,
        "agent AGENTS auto-push: AGENTS.md file is in context stack"
    );
    like(
        $results->{stdout},
        qr/contents: Auto agent instructions\. Second line\./,
        "agent AGENTS auto-push: AGENTS.md contents are visible in stack preview"
    );
}

=head3 Test agent mode does not auto-push when AGENTS.md is absent

=cut

{
    my $agent_dir = "$temp_dir/agent_autopush_no_agents_$$";
    mkdir $agent_dir or die "Cannot create agent test dir: $!";
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec ls\n,comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",cd $agent_dir\n", ",agent no agents file check\n",
            ",s\n",             ",exit\n"
        ]
    );

    is($results->{exit_code}, 0,
        "agent AGENTS auto-push missing: agent mode completes");
    like($results->{stdout}, qr/\[\s*\]/,
        "agent AGENTS auto-push missing: context stack remains empty");
    unlike($results->{stdout}, qr/AGENTS\.md/,
        "agent AGENTS auto-push missing: no AGENTS.md context output");
}

=head3 Test agent mode warns but accepts AGENT_COMPLETE with no commands

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = ",comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent premature complete guard\n", ",exit\n"]);

    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: done/,
        "agent no-command completion: control marker is not printed"
    );
    like(
        $results->{stdout},
        qr/WARNING: agent completed without running any commands/,
        "agent no-command completion: warns when completing without commands"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: repeated premature AGENT_COMPLETE replies; stopping agent mode/,
        "agent no-command completion: no repeated premature completion error"
    );
    is($results->{exit_code}, 0,
        "agent no-command completion: exits cleanly");
}

=head3 Test agent completion preserves bare multiline summary text

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = join("\n",
        "The current uncommitted changes are:",
        "- README.pod updates the usage notes.",
        "- deed.pl changes prompt handling.",
        ",comment AGENT_COMPLETE",
    );
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent multiline completion summary\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/The current uncommitted changes are:\n- README\.pod updates the usage notes\.\n- deed\.pl changes prompt handling\./,
        "agent multiline completion: preserves bare trailing summary lines"
    );
    is($results->{exit_code}, 0, "agent multiline completion: exits cleanly");
}

=head3 Test agent completion rings bell before returning to REPL prompt

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = ",comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results
      = run_synergy_file_session([",agent bell completion\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/\Q$bell\E> /s,
        "agent bell: rings before returning to REPL prompt after completion"
    );
    is($results->{exit_code}, 0, "agent bell: exits cleanly");
}

=head3 Test agent mode prints prose output instead of ignoring it

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = join("\n",
        "I'll inspect the files first.",
        ",comment AGENT_COMPLETE: done",
    );
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent prose output\n", ",history\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/I'll inspect the files first\./,
        "agent prose output: bare prose is printed"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: invalid agent output/,
        "agent prose output: bare prose is not a parser error"
    );
    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: done/,
        "agent prose output: control marker is not printed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: comment: I'll inspect the files first\./,
        "agent prose output: bare prose is saved as a comment"
    );
    is($results->{exit_code}, 0, "agent prose output: exits cleanly");
}

=head3 Test agent mode still reports unknown comma commands

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = join("\n", ",bogus nope", ",comment AGENT_COMPLETE: done",);
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent unknown command output\n", ",history\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/AGENT ERROR: Unknown command ',bogus'/,
        "agent unknown command: comma command errors are still reported"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: AGENT ERROR: Unknown command ',bogus'/,
        "agent unknown command: error is saved to conversation history"
    );
    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: done/,
        "agent unknown command: control marker is not printed"
    );
    is($results->{exit_code}, 0, "agent unknown command: exits cleanly");
}

=head3 Test agent mode prints markdown fences as prose

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = join("\n", '```', ",exec ls", '```', ",comment AGENT_COMPLETE: done",
      );
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent invalid fenced output\n", ",history\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/```\nexec: ls/s,
        "agent fenced output: opening fence is printed as prose"
    );
    like(
        $results->{stdout},
        qr/exec: ls.*```\n/s,
        "agent fenced output: closing fence is printed as prose"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: invalid agent output/,
        "agent fenced output: fences are not parser errors"
    );
    like($results->{stdout}, qr/exec: ls/,
        "agent fenced output: valid command inside still executes");
    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: done/,
        "agent fenced output: control marker is not printed"
    );
    is($results->{exit_code}, 0, "agent fenced output: exits cleanly");
}

=head3 Test agent mode accepts multiline report comments

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = join("\n",
        "The recent commits improve agent reliability.",
        "",
        "- malformed output now produces feedback",
        "- the next-turn prompt is stricter",
        ",comment AGENT_COMPLETE: evaluated commits",
    );
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent report on recent commits\n", ",history\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/The recent commits improve agent reliability\.\n\n- malformed output now produces feedback\n- the next-turn prompt is stricter/,
        "agent multiline report comment: bare continuation lines are printed"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: invalid agent output/,
        "agent multiline report comment: continuation lines are not parser errors"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: comment: The recent commits improve agent reliability\.\n\n- malformed output now produces feedback\n- the next-turn prompt is stricter/,
        "agent multiline report comment: continuation lines are saved in history"
    );
    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: evaluated commits/,
        "agent multiline report comment: control marker is not printed"
    );
    is($results->{exit_code}, 0,
        "agent multiline report comment: exits cleanly");
}

=head3 Test agent loop runs multiple turns before AGENT_COMPLETE

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY_1}
      = '{"choices":[{"message":{"content":",comment planning\n,exec ls"}}]}';
    local $ENV{SYNERGY_CURL_FAKE_BODY_2}
      = '{"choices":[{"message":{"content":",comment AGENT_COMPLETE: done on second turn"}}]}';
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",model gpt-5\n", ",agent multi-turn loop check\n", ",exit\n"]);

    like($results->{stdout}, qr/planning/,
        "agent multi-turn loop: first turn comment executed");
    like($results->{stdout}, qr/exec: ls/,
        "agent multi-turn loop: first turn command executed");
    unlike(
        $results->{stdout},
        qr/agent: exec ls/,
        "agent multi-turn loop: does not pre-echo exec before command output"
    );
    unlike(
        $results->{stdout},
        qr/AGENT_COMPLETE: done on second turn/,
        "agent multi-turn loop: completion marker is not printed"
    );
    is($results->{exit_code}, 0, "agent multi-turn loop: exits cleanly");

    my @body_files = glob("$capture_dir/req_*_body.json");
    is(scalar(@body_files), 2,
        "agent multi-turn loop: two assistant calls captured");
}

=head3 Test agent mode asks before running git and records denial

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec git rev-parse --is-inside-work-tree\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent git deny check\n", "n\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/agent requests git: git rev-parse --is-inside-work-tree/,
        "agent git deny: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this git command to run\? \[y\/N\]/,
        "agent git deny: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/AGENT INFO: git command denied by user/,
        "agent git deny: denial message shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: git rev-parse --is-inside-work-tree/,
        "agent git deny: command was not executed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: AGENT INFO: git command denied by user/,
        "agent git deny: denial recorded in history"
    );
}

=head3 Test agent mode can run git after approval

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec git rev-parse --is-inside-work-tree\n,comment AGENT_COMPLETE: allowed";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent git allow check\n", "y\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/agent requests git: git rev-parse --is-inside-work-tree/,
        "agent git allow: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this git command to run\? \[y\/N\]/,
        "agent git allow: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/exec: git rev-parse --is-inside-work-tree/,
        "agent git allow: command executed after approval"
    );
    is($results->{exit_code}, 0, "agent git allow: agent completes cleanly");
}

=head3 Test blocked git subcommands are denied regardless of yolo

=cut

{
    my @cases = (
        [
            'push --force',
            'git push --force origin main',
            'git push --force is not permitted'
        ],
        [
            'push -f with -C',
            "git -C $temp_dir push -f origin main",
            'git push --force is not permitted'
        ],
        [
            'push --force-with-lease',
            'git push --force-with-lease origin main',
            'git push --force-with-lease is not permitted'
        ],
        [
            'push --delete',
            'git push --delete origin old-branch',
            'git push --delete is not permitted'
        ],
        [
            'push force refspec',
            'git push origin +main',
            'git push force refspec is not permitted'
        ],
        [
            'push delete refspec',
            'git push origin :old-branch',
            'git push delete refspec is not permitted'
        ],
        [
            'push --mirror',
            'git push --mirror origin',
            'git push --mirror is not permitted'
        ],
        [
            'push --prune',
            'git push --prune origin',
            'git push --prune is not permitted'
        ],
        ['rebase', 'git rebase main', 'git rebase is not permitted'],
        [
            'rebase with -C',
            "git -C $temp_dir rebase main",
            'git rebase is not permitted'
        ],
        [
            'reset --hard',
            'git reset --hard HEAD~1',
            'git reset --hard is not permitted'
        ],
        [
            'commit --amend',
            'git commit --amend --no-edit',
            'git commit --amend is not permitted'
        ],
        [
            'branch -D',
            'git branch -D old-branch',
            'git branch -D is not permitted'
        ],
        ['clean -f', 'git clean -fd', 'git clean -f is not permitted'],
    );

    for my $case (@cases) {
        my ($label, $cmd, $expected_msg) = @$case;
        local $ENV{SYNERGY_OFFLINE_RESPONSE}
          = ",exec $cmd\n,comment AGENT_COMPLETE: done";
        local $ENV{SYNERGY_AGENT_FAST} = 1;

        my $results = run_synergy_file_session(
            [",yolo\n", ",agent blocked git $label\n", ",exit\n"]);

        like($results->{stdout}, qr/\Q$expected_msg\E/,
            "blocked git ($label): denied with specific message even in yolo mode"
        );
        unlike(
            $results->{stdout},
            qr/exec: \Q$cmd\E/,
            "blocked git ($label): command was not executed"
        );
    }
}

=head3 Test normal git push is not hard-blocked

=cut

{
    my $push_probe_dir = tempdir(CLEANUP => 1);
    my $cmd            = "git -C $push_probe_dir push origin main";
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec $cmd\n,comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",yolo\n", ",agent normal git push probe\n", ",exit\n"]);

    unlike(
        $results->{stdout},
        qr/is not permitted/,
        "normal git push: not hard-blocked by destructive git policy"
    );
    like(
        $results->{stdout},
        qr/exec: \Q$cmd\E/,
        "normal git push: command reaches execution path"
    );
}

=head3 Test normal git push without git-level options is not hard-blocked

=cut

{
    my $push_probe_dir = tempdir(CLEANUP => 1);
    my $cmd            = "git push origin main";
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec $cmd\n,comment AGENT_COMPLETE: done";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",cd $push_probe_dir\n",                ",yolo\n",
            ",agent normal plain git push probe\n", ",exit\n"
        ]
    );

    unlike(
        $results->{stdout},
        qr/is not permitted/,
        "normal plain git push: not hard-blocked by destructive git policy"
    );
    like(
        $results->{stdout},
        qr/exec: \Q$cmd\E/,
        "normal plain git push: command reaches execution path"
    );
}

=head3 Test safe git subcommands still work normally

=cut

{
    # Read-only commands only; these run for real so must be safe
    my @cases = (
        ['status',      'git status --short'],
        ['log',         'git log --oneline -5'],
        ['diff',        'git diff HEAD'],
        ['show',        'git show --stat HEAD'],
        ['branch list', 'git branch -v'],
        ['remote',      'git remote -v'],
    );

    for my $case (@cases) {
        my ($label, $cmd) = @$case;
        local $ENV{SYNERGY_OFFLINE_RESPONSE}
          = ",exec $cmd\n,comment AGENT_COMPLETE: done";
        local $ENV{SYNERGY_AGENT_FAST} = 1;

        my $results = run_synergy_file_session(
            [",yolo\n", ",agent safe git $label\n", ",exit\n"]);

        unlike(
            $results->{stdout},
            qr/is not permitted/,
            "safe git ($label): not blocked"
        );
        like(
            $results->{stdout},
            qr/exec: \Q$cmd\E/,
            "safe git ($label): command executed"
        );
    }
}

=head3 Test ,yolo enables auto-approve so git runs without prompting

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec git rev-parse --is-inside-work-tree\n,comment AGENT_COMPLETE: yolo";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",yolo\n", ",agent git yolo check\n", ",exit\n"]);

    unlike(
        $results->{stdout},
        qr/Allow this git command to run\? \[y\/N\]/,
        "yolo mode: git runs without confirmation prompt"
    );
    unlike(
        $results->{stdout},
        qr/AGENT INFO: auto-approved:/,
        "yolo mode: auto-approve info line suppressed"
    );
    like(
        $results->{stdout},
        qr/exec: git rev-parse --is-inside-work-tree/,
        "yolo mode: git command executed"
    );
    is($results->{exit_code}, 0, "yolo mode: agent completes cleanly");
}

=head3 Test ,yolo toggles back off

=cut

{
    my $results = run_synergy_file_session([",yolo\n", ",yolo\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/Agent auto-approve mode: ON/,
        "yolo toggle: first toggle turns ON"
    );
    like(
        $results->{stdout},
        qr/Agent auto-approve mode: OFF/,
        "yolo toggle: second toggle turns OFF"
    );
}

=head3 Test agent mode rejects unquoted multi-word git commit messages

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec git commit -m Add replace review navigation and undo status\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent git commit quoting check\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: git commit message arguments must be quoted; use git commit -m "subject" -m "body" or git commit -F file/,
        "agent git commit quoting: surfaces targeted parse error"
    );
    unlike(
        $results->{stdout},
        qr/Allow this git command to run\? \[y\/N\]/,
        "agent git commit quoting: does not prompt for approval"
    );
    unlike(
        $results->{stdout},
        qr/exec: git commit -m Add replace review navigation and undo status/,
        "agent git commit quoting: invalid command is not executed"
    );
}

=head3 Test agent mode asks before running generic commands and records denial

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec jira-create-issue DOC 'document the foo'\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",agent generic command deny check\n", "n\n",
            ",history\n",                          ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/agent requests command: jira-create-issue DOC document the foo/,
        "agent generic deny: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent generic deny: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/AGENT INFO: command denied by user/,
        "agent generic deny: denial message shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: jira-create-issue DOC document the foo/,
        "agent generic deny: command was not executed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: AGENT INFO: command denied by user/,
        "agent generic deny: denial recorded in history"
    );
}

=head3 Test agent mode can run generic commands after approval

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec jira-create-issue DOC 'document the foo'\n,comment AGENT_COMPLETE: allowed";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent generic command allow check\n", "y\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/agent requests command: jira-create-issue DOC document the foo/,
        "agent generic allow: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent generic allow: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/exec: jira-create-issue DOC document the foo/,
        "agent generic allow: command executed after approval"
    );
    is($results->{exit_code}, 0,
        "agent generic allow: agent completes cleanly");
}

=head3 Test agent mode blocks never-allowed commands without prompting

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec rm -f /tmp/agent-block-test\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent policy deny rm check\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/AGENT INFO: command denied by policy: rm/,
        "agent deny rm: policy denial message shown"
    );
    unlike(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent deny rm: no confirmation prompt shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: rm -f \/tmp\/agent-block-test/,
        "agent deny rm: command was not executed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: AGENT INFO: command denied by policy: rm/,
        "agent deny rm: denial recorded in history"
    );
}

=head3 Test agent mode blocks basename-normalized denied commands

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec /bin/rm -f /tmp/agent-block-test\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent policy deny basename check\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/AGENT INFO: command denied by policy: \/bin\/rm/,
        "agent deny basename: policy denial uses original command token"
    );
    unlike(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent deny basename: no confirmation prompt shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: \/bin\/rm -f \/tmp\/agent-block-test/,
        "agent deny basename: command was not executed"
    );
}

=head3 Test agent mode blocks shell wrappers without prompting

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec bash -lc 'echo nope'\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",agent policy deny shell wrapper check\n", ",history\n",
            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/AGENT INFO: command denied by policy: bash/,
        "agent deny shell wrapper: policy denial message shown"
    );
    unlike(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent deny shell wrapper: no confirmation prompt shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: bash -lc echo nope/,
        "agent deny shell wrapper: command was not executed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: AGENT INFO: command denied by policy: bash/,
        "agent deny shell wrapper: denial recorded in history"
    );
}

=head3 Test agent mode rejects ,shell explicitly

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",shell printf nope\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent shell reject check\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: ,shell is not available in agent mode/,
        "agent shell: explicit rejection message shown"
    );
    unlike(
        $results->{stdout},
        qr/shell: printf nope/,
        "agent shell: command was not executed"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: ERROR: ,shell is not available in agent mode/,
        "agent shell: rejection recorded in history"
    );
}

=head3 Test agent mode asks before running perl one-liners

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec perl -e 'print qq[hi from perl\\n]'\n,comment AGENT_COMPLETE: denied";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent perl deny check\n", "n\n", ",history\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/agent requests command: perl -e print qq\[hi from perl\\n\]/,
        "agent perl deny: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent perl deny: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/AGENT INFO: command denied by user/,
        "agent perl deny: denial message shown"
    );
    unlike(
        $results->{stdout},
        qr/exec: perl -e print qq\[hi from perl\\n\]/,
        "agent perl deny: command was not executed"
    );
}

=head3 Test agent mode can run perl one-liners after approval

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE}
      = ",exec perl -e 'print qq[hi from perl\\n]'\n,comment AGENT_COMPLETE: allowed";
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",agent perl allow check\n", "y\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/agent requests command: perl -e print qq\[hi from perl\\n\]/,
        "agent perl allow: request line shown before approval"
    );
    like(
        $results->{stdout},
        qr/Allow this command to run\? \[y\/N\]/,
        "agent perl allow: confirmation prompt shown"
    );
    like(
        $results->{stdout},
        qr/exec: perl -e print qq\[hi from perl\\n\]/,
        "agent perl allow: command executed after approval"
    );
    like(
        $results->{stdout},
        qr/hi from perl/,
        "agent perl allow: perl output captured"
    );
}

=head3 Test agent prompt/message split for cache-friendly prefixing

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"choices":[{"message":{"content":",exec ls\n,comment AGENT_COMPLETE: done"}}]}';
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [",model gpt-5\n", ",agent cache-ordering-check\n", ",exit\n"]);

    is($results->{exit_code}, 0, "agent prompt ordering: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "agent prompt ordering: captured OpenAI request body");

    my $body = decode_json(slurp($body_file));
    my $sys  = $body->{input}[0]{content} // '';

    my $static_idx
      = index($sys, "**OPERATIONAL GUIDELINES for SYNERGY Agent Mode:**");

    ok($static_idx >= 0,
        "agent prompt ordering: static guidelines block exists");
    unlike(
        $sys,
        qr/Here is the history of the conversation to this point/,
        "agent prompt ordering: dynamic conversation block no longer lives in system prompt"
    );
    unlike(
        $sys,
        qr/Relevant file\/context state/,
        "agent prompt ordering: dynamic context block no longer lives in system prompt"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{content} // '') =~ /Agent task and environment:/
                  && ($_->{content} // '')
                  =~ /cache-ordering-check/
            } @{$body->{input}}
        ),
        "agent prompt ordering: task and environment sent as user message"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{content} // '') =~ /Relevant file\/context state/
                  && ($_->{content} // '')
                  =~ /AGENTS\.md/
            } @{$body->{input}}
        ),
        "agent prompt ordering: file context sent as user message"
    );
    ok(
        !(
            grep { ($_->{content} // '') =~ /agent: cache-ordering-check/ }
            @{$body->{input}}
        ),
        "agent prompt ordering: synthetic task history omitted from message stream"
    );
    like(
        $body->{input}[-1]{content} // '',
        qr/Agent next turn:/,
        "agent prompt ordering: current turn prompt is final message"
    );
    like(
        $body->{input}[-1]{content} // '',
        qr/Bare prose is allowed for user-visible commentary, answers, reviews, and reports/,
        "agent prompt ordering: next-turn prompt permits visible prose"
    );
    like(
        $body->{input}[-1]{content} // '',
        qr/run a relevant check \(usually an automated test\)/,
        "agent prompt ordering: next-turn prompt asks for relevant automated checks"
    );
    like(
        $body->{input}[-1]{content} // '',
        qr/AGENT_COMPLETE is a private control marker and will not be printed/,
        "agent prompt ordering: completion marker is private"
    );
    like(
        $body->{input}[-1]{content} // '',
        qr/Do not recap progress that is already visible/,
        "agent prompt ordering: discourages duplicate recap"
    );
    unlike(
        $body->{input}[-1]{content} // '',
        qr/Every non-empty line must start at column 0/,
        "agent prompt ordering: old strict every-line command contract is removed"
    );
    unlike(
        $body->{input}[-1]{content} // '',
        qr/Please consider our overall task and current progress/,
        "agent prompt ordering: old generic next-turn prompt is removed"
    );
    is($body->{reasoning}{effort}, "high",
        "agent prompt ordering: OpenAI agent requests use high reasoning effort"
    );
}

=head3 Test agent prompt/message split for Anthropic

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":",exec ls\n,comment AGENT_COMPLETE: done"}]}';
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",model claude-sonnet\n",
            ",agent anthropic-cache-ordering-check\n",
            ",exit\n"
        ]
    );

    is($results->{exit_code}, 0,
        "agent prompt ordering anthropic: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "agent prompt ordering anthropic: captured request body");

    my $body = decode_json(slurp($body_file));
    my $sys
      = ref($body->{system}) eq 'ARRAY'
      ? ($body->{system}[0]{text} // '')
      : ($body->{system} // '');

    ok(
        index($sys, "**OPERATIONAL GUIDELINES for SYNERGY Agent Mode:**")
          >= 0,
        "agent prompt ordering anthropic: static guidelines block exists"
    );
    unlike(
        $sys,
        qr/Here is the history of the conversation to this point/,
        "agent prompt ordering anthropic: dynamic conversation block no longer lives in system prompt"
    );
    unlike(
        $sys,
        qr/Relevant file\/context state/,
        "agent prompt ordering anthropic: dynamic context block no longer lives in system prompt"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{content} // '') =~ /Agent task and environment:/
                  && ($_->{content} // '')
                  =~ /anthropic-cache-ordering-check/
            } @{$body->{messages}}
        ),
        "agent prompt ordering anthropic: task and environment sent as user message"
    );
    my ($context_index, $context_block);
    for my $i (0 .. $#{$body->{messages}}) {
        my $message = $body->{messages}[$i];
        my $content = $message->{content};
        if (ref($content) eq 'ARRAY' && ($message->{role} // '') eq 'user') {
            for my $block (@$content) {
                next unless ref($block) eq 'HASH';
                next
                  unless ($block->{text} // '')
                  =~ /Relevant file\/context state/;
                next unless ($block->{text} // '') =~ /AGENTS\.md/;
                $context_index = $i;
                $context_block = $block;
                last;
            }
        }
    }
    ok($context_block,
        "agent prompt ordering anthropic: file context sent as content block"
    );
    is_deeply(
        $context_block->{cache_control},
        {type => 'ephemeral'},
        "agent prompt ordering anthropic: context block has cache control"
    );
    ok(
        !(
            grep {
                ($_->{content} // '')
                  =~ /agent: anthropic-cache-ordering-check/
            } @{$body->{messages}}
        ),
        "agent prompt ordering anthropic: synthetic task history omitted from message stream"
    );
    like(
        $body->{messages}[-1]{content} // '',
        qr/Agent next turn:/,
        "agent prompt ordering anthropic: current turn prompt is final message"
    );
    is($body->{thinking}{type},
        "adaptive",
        "agent prompt ordering anthropic: thinking enabled for agent mode");
    is($body->{output_config}{effort}, "high",
        "agent prompt ordering anthropic: high effort retained for agent mode"
    );
}

=head3 Test agent prompt/message split for Gemini

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{GEMINI_API_KEY}           = "GEMINI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"candidates":[{"content":{"parts":[{"text":",exec ls\n,comment AGENT_COMPLETE: done"}]}}]}';
    local $ENV{SYNERGY_AGENT_FAST} = 1;

    my $results = run_synergy_file_session(
        [
            ",model gemini-flash\n",
            ",agent gemini-cache-ordering-check\n",
            ",exit\n"
        ]
    );

    is($results->{exit_code}, 0,
        "agent prompt ordering gemini: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "agent prompt ordering gemini: captured request body");

    my $body = decode_json(slurp($body_file));
    my $sys  = $body->{contents}[0]{parts}[0]{text} // '';

    ok(
        index($sys, "**OPERATIONAL GUIDELINES for SYNERGY Agent Mode:**")
          >= 0,
        "agent prompt ordering gemini: static guidelines block exists"
    );
    unlike(
        $sys,
        qr/Here is the history of the conversation to this point/,
        "agent prompt ordering gemini: dynamic conversation block no longer lives in system prompt"
    );
    unlike(
        $sys,
        qr/Relevant file\/context state/,
        "agent prompt ordering gemini: dynamic context block no longer lives in system prompt"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{parts}[0]{text} // '')
                  =~ /Agent task and environment:/
                  && ($_->{parts}[0]{text} // '')
                  =~ /gemini-cache-ordering-check/
            } @{$body->{contents}}
        ),
        "agent prompt ordering gemini: task and environment sent as user message"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{parts}[0]{text} // '')
                  =~ /Relevant file\/context state/
                  && ($_->{parts}[0]{text} // '')
                  =~ /AGENTS\.md/
            } @{$body->{contents}}
        ),
        "agent prompt ordering gemini: file context sent as user message"
    );
    ok(
        !(
            grep {
                ($_->{parts}[0]{text} // '')
                  =~ /agent: gemini-cache-ordering-check/
            } @{$body->{contents}}
        ),
        "agent prompt ordering gemini: synthetic task history omitted from message stream"
    );
    like(
        $body->{contents}[-1]{parts}[0]{text} // '',
        qr/Agent next turn:/,
        "agent prompt ordering gemini: current turn prompt is final message"
    );
}


done_testing();

END {
    chdir $original_cwd;
}
