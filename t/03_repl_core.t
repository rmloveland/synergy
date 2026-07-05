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

=head3 Test REPL rings bell before prompt after assistant replies

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = "BELL_REPLY";

    my $results
      = run_synergy_file_session(["ring bell after reply\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/BELL_REPLY.*\Q$bell\E> /s,
        "bell reply: rings before returning to prompt after assistant output"
    );
    is($results->{exit_code}, 0, "bell reply: exits cleanly");
}

=head3 Test REPL does not ring bell after command-mode turns

=cut

{
    my $results
      = run_synergy_file_session([",comment bell command\n", ",exit\n"]);

    unlike(
        $results->{stdout},
        qr/comment: bell command.*\Q$bell\E> /s,
        "bell command: does not ring before returning to prompt after REPL command"
    );
    is($results->{exit_code}, 0, "bell command: exits cleanly");
}

=head3 Test ,help command

=cut

{
    my $results = run_synergy_session([",help\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/This is Synergy\. You are interacting with the command processor\./,
        "help: displays intro"
    );
    like(
        $results->{stdout},
        qr/,collect\s+Compact conversation history into a handoff summary/,
        "help: documents collect"
    );
    like(
        $results->{stdout},
        qr/,collect\s+Compact conversation history into a handoff summary/,
        "help: documents collect"
    );
    like(
        $results->{stdout},
        qr/,edit\s+file\.txt\s+Open file\.txt in \$EDITOR/,
        "help: documents edit"
    );
    like(
        $results->{stdout},
        qr/,exec\s+cmd\s+Execute a command, or a '\|' pipeline of commands/,
        "help: documents exec pipelines"
    );
    unlike($results->{stdout}, qr/,shell\s+cmd/, "help: ,shell is gone");
    is($results->{exit_code}, 0, "help: exits cleanly");
}

=head3 Test dispatch fallback: comma lines never reach the assistant

Any line whose first non-blank character is a comma is a command.
,? and bare , work only via the help fallback, and unknown commands
(including arguments with characters the old dispatch character class
rejected) must print help rather than being sent to the assistant.

=cut

{
    my $results = run_synergy_session(
        [",?\n", ",\n", ",bogus 50% + ~x & y\n", ",exit\n"],
        undef, {SYNERGY_OFFLINE_RESPONSE => 'ASSISTANT_SENTINEL_REPLY'},
    );

    my @help_intros
      = ($results->{stdout}
          =~ /(This is Synergy\. You are interacting with the command processor\.)/g
      );
    is(scalar @help_intros,
        3, "dispatch: ',?', bare ',', and unknown command each print help");
    unlike($results->{stdout}, qr/ASSISTANT_SENTINEL_REPLY/,
        "dispatch: comma lines are never sent to the assistant");
    is($results->{exit_code}, 0, "dispatch: fallback exits cleanly");
}

=head3 Test ,exec passes formerly-truncated metacharacters verbatim

The old dispatch character class silently dropped %, +, ~, and & from
command arguments. Pin that the generic dispatch passes them through,
and that quoted shell operators are ordinary argument text.

=cut

{
    my $results
      = run_synergy_session([",exec echo '50% + ~x & y'\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/^50% \+ ~x & y$/m,
        "exec: % + ~ & survive dispatch and reach the command verbatim"
    );
    is($results->{exit_code}, 0, "exec: metacharacter case exits cleanly");
}

=head3 Test ,collect command

=cut

{
    my $curl_dir = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{OPENAI_API_KEY}           = 'test-openai-key';
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $curl_dir;
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"output_text":"Compacted handoff summary"}';

    my $results = run_synergy_session(
        [
            ",comment first constraint: keep patches small\n",
            ",comment next step: add e2e coverage\n",
            ",collect\n",
            ",history\n",
            ",exit\n",
        ]
    );

    my $body_path = "$curl_dir/req_1_body.json";
    my $req_body  = -f $body_path ? slurp($body_path) : '';

    ok(-f $body_path, "collect: issues a compaction request");
    like(
        $results->{stdout},
        qr/collect: conversation history compacted into a handoff summary/,
        "collect: reports success"
    );
    like(
        $results->{stdout},
        qr/\[0\]: COLLECTED CONTEXT:\nCompacted handoff summary/s,
        "collect: replaces history with collected summary"
    );
    unlike($results->{stdout}, qr/\[1\]:/,
        "collect: history contains a single collected entry");
    like(
        $req_body,
        qr/CONTEXT CHECKPOINT COMPACTION/,
        "collect: request includes codex compaction prompt"
    );
    like(
        $req_body,
        qr/Current progress and key decisions made/,
        "collect: request includes compaction prompt detail"
    );
    like(
        $req_body,
        qr/first constraint: keep patches small/,
        "collect: request includes earlier conversation state"
    );
    like(
        $req_body,
        qr/next step: add e2e coverage/,
        "collect: request includes later conversation state"
    );
    like(
        $req_body,
        qr/Return only the handoff summary text/,
        "collect: request includes collect instruction"
    );
    is($results->{exit_code}, 0, "collect: exits cleanly");
}

=head3 Test automatic compaction triggers on the token threshold

When the last server-reported prompt size crosses the compaction
threshold, the next turn must first run a compaction call and rewrite
the history to the summary plus retained verbatim user messages,
dropping assistant replies. The turn after compaction must not
re-trigger (the check waits for fresh server-reported usage).

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my %env = (
        SYNERGY_CURL_CAPTURE_DIR   => $capture_dir,
        PATH                       => "$curl_dir:$ENV{PATH}",
        OPENAI_API_KEY             => 'OPENAI_KEY_TEST',
        SYNERGY_AUTOCOMPACT_TOKENS => 1000,
        SYNERGY_CURL_FAKE_BODY_1   =>
          '{"output_text":"FIRST_REPLY","usage":{"input_tokens":50000,"output_tokens":10}}',
        SYNERGY_CURL_FAKE_BODY_2 =>
          '{"output_text":"HANDOFF_SUMMARY","usage":{"input_tokens":90,"output_tokens":10}}',
        SYNERGY_CURL_FAKE_BODY_3 =>
          '{"output_text":"SECOND_REPLY","usage":{"input_tokens":120,"output_tokens":10}}',
    );

    my $results = run_synergy_session(
        [
            ",model gpt-5\n",
            "remember the magic word xyzzy\n",
            "what is the magic word\n",
            ",exit\n"
        ],
        undef,
        \%env,
    );
    is($results->{exit_code}, 0, "autocompact: session exits cleanly");

    like(
        $results->{stdout},
        qr/collect: auto-compacting conversation history \(50000 tokens >= 1000 token threshold\)/,
        "autocompact: trigger reports measured tokens and threshold"
    );
    like(
        $results->{stdout},
        qr/collect: conversation history compacted into a handoff summary/,
        "autocompact: compaction runs"
    );
    like(
        $results->{stdout},
        qr/NOTE: Long threads and repeated compactions reduce model accuracy/,
        "autocompact: advisory is printed"
    );

    my @bodies = sort glob("$capture_dir/req_*_body.json");
    is(scalar @bodies,
        3, "autocompact: turn, compaction call, turn - and no re-trigger");

    my $compaction = decode_json(slurp($bodies[1]));
    like(
        $compaction->{input}[0]{content},
        qr/CONTEXT CHECKPOINT COMPACTION/,
        "autocompact: compaction call uses the checkpoint prompt"
    );

    my $after   = decode_json(slurp($bodies[2]));
    my @content = map { $_->{content} // '' } @{$after->{input}};
    ok(
        (grep {/^COLLECTED CONTEXT:\nHANDOFF_SUMMARY/} @content),
        "autocompact: rewritten history leads with the summary"
    );
    ok(
        (grep { $_ eq 'remember the magic word xyzzy' } @content),
        "autocompact: recent user message retained verbatim"
    );
    ok(!(grep {/FIRST_REPLY/} @content),
        "autocompact: prior assistant reply dropped from history");
}

=head3 Test automatic compaction can be disabled

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my %env = (
        SYNERGY_CURL_CAPTURE_DIR   => $capture_dir,
        PATH                       => "$curl_dir:$ENV{PATH}",
        OPENAI_API_KEY             => 'OPENAI_KEY_TEST',
        SYNERGY_AUTOCOMPACT_TOKENS => 0,
        SYNERGY_CURL_FAKE_BODY_1   =>
          '{"output_text":"REPLY_A","usage":{"input_tokens":50000,"output_tokens":10}}',
        SYNERGY_CURL_FAKE_BODY_2 =>
          '{"output_text":"REPLY_B","usage":{"input_tokens":51000,"output_tokens":10}}',
    );

    my $results
      = run_synergy_session(
        [",model gpt-5\n", "turn a\n", "turn b\n", ",exit\n"],
        undef, \%env,);
    is($results->{exit_code}, 0, "autocompact off: session exits cleanly");

    unlike(
        $results->{stdout},
        qr/auto-compacting conversation history/,
        "autocompact off: threshold zero disables the check"
    );
    my @bodies = glob("$capture_dir/req_*_body.json");
    is(scalar @bodies, 2, "autocompact off: no compaction call made");
}

=head3 Test ,pwd command

=cut

{
    my $results = run_synergy_session([",pwd\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/pwd: \Q$original_cwd\E/,
        "pwd: displays current working directory"
    );
}

=head3 Test ,cd command

=cut

{
    my $results
      = run_synergy_session([",cd $temp_dir\n", ",pwd\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/cwd set to: '\Q$temp_dir\E'/,
        "cd: changes directory"
    );
    like(
        $results->{stdout},
        qr/pwd: \Q$temp_dir\E/,
        "cd: new directory reflected by pwd"
    );
}

=head3 Test ,cd command (failure - non-existent directory)

=cut

{
    my $non_existent_dir = "$temp_dir/non_existent_dir_123";
    my $results = run_synergy_session([",cd $non_existent_dir\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Directory '\Q$non_existent_dir\E' not found/,
        "cd: handles non-existent directory"
    );
    is($results->{exit_code}, 0, "cd: non-existent dir exits cleanly")
      ;    # Should still exit cleanly
}

=head3 Test ,edit command

=cut

{
    my $edit_target = "$temp_dir/edit_target.txt";
    my $editor_stub = "$temp_dir/fake_editor_success.pl";

    open my $fh, '>', $editor_stub or die "Cannot create fake editor: $!";
    print $fh <<'EOF';
#!/usr/bin/env perl
use strict;
use warnings;

my $path = shift @ARGV;
open my $out, '>>', $path or die "Cannot open target file: $!";
print {$out} "edited by fake editor\n";
close $out;
EOF
    close $fh;
    chmod 0755, $editor_stub or die "Cannot chmod fake editor: $!";

    my $results = run_synergy_session(
        [",edit $edit_target\n", ",history\n", ",exit\n"],
        $SYNERGY_SCRIPT, {EDITOR => "$^X $editor_stub"},
    );

    like(
        $results->{stdout},
        qr/edit: opened '\Q$edit_target\E'/,
        "edit: opens file through EDITOR"
    );
    like(
        $results->{stdout},
        qr/\[\d+\]: edit: \Q$edit_target\E/,
        "edit: successful command is recorded in history"
    );
    like(
        slurp($edit_target),
        qr/edited by fake editor/,
        "edit: launched editor received target path"
    );
    is($results->{exit_code}, 0, "edit: exits cleanly");
}

=head3 Test ,edit command (failure - EDITOR unset)

=cut

{
    my $edit_target = "$temp_dir/edit_missing_editor.txt";
    my $results     = run_synergy_session([",edit $edit_target\n", ",exit\n"],
        $SYNERGY_SCRIPT, {}, ['EDITOR'],);

    like(
        $results->{stdout},
        qr/ERROR: EDITOR is not set/,
        "edit: requires EDITOR"
    );
    is($results->{exit_code}, 0, "edit: missing EDITOR exits cleanly");
}

=head3 Test ,push command (file) and ,s (show stack)

=cut

{
    my $test_file = "$temp_dir/test_push_file.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "Test file content.\nLine 2.\n";
    close $fh;

    my $results
      = run_synergy_session([",push $test_file\n", ",s\n", ",exit\n",]);
    like(
        $results->{stdout},
        qr/file: '\Q$test_file\E'/,
        "push: adds file to context stack"
    );
    like(
        $results->{stdout},
        qr/contents: Test file content\. Line 2\./,
        "s: shows file content preview"
    );
}

=head3 Test ,dump and ,load commands

=cut

{
    my $dump_file   = "$temp_dir/test_dump.xml";
    my $test_file_1 = "$temp_dir/dump_file_1.txt";
    my $test_file_2 = "$temp_dir/dump_file_2.txt";
    open my $fh1, '>', $test_file_1 or die "Cannot create test file 1: $!";
    print $fh1 "Content A.\n";
    close $fh1;
    open my $fh2, '>', $test_file_2 or die "Cannot create test file 2: $!";
    print $fh2 "Content B.\n";
    close $fh2;

    my $cmds = [
        ",push $test_file_1\n",
        ",push $test_file_2\n",
        ",dump $dump_file\n",
        ",exit\n",
    ];

    unless (OFFLINE_MODE) {
        push @$cmds, "Initial AI query.\n";
    }

    # First session: push files, dump state
    my $session1_results = run_synergy_session($cmds, $SYNERGY_SCRIPT,);

    ok(-f $dump_file, "dump: creates the dump file");

    # Second session: load state, verify
    my $session2_results
      = run_synergy_session(
        [",load $dump_file\n", ",s\n", ",history\n", ",exit\n",],
        $SYNERGY_SCRIPT);

    like(
        $session2_results->{stdout},
        qr/Loading dump file '\Q$dump_file\E'/,
        "load: indicates loading"
    );
    like(
        $session2_results->{stdout},
        qr/file: '\Q$test_file_1\E'/,
        "load: restores context stack (file 1)"
    );
    like(
        $session2_results->{stdout},
        qr/file: '\Q$test_file_2\E'/,
        "load: restores context stack (file 2)"
    );
    unless (OFFLINE_MODE) {
        like(
            $session2_results->{stdout},
            qr/Initial AI query/,
            "load: restores conversation history"
        );
    }

    my $dump_xml = slurp($dump_file);
    my ($loaded_session_id)
      = ($dump_xml =~ /<dump time="[^"]+" session="([^"]+)"/);
    ok($loaded_session_id, "load: dump file exposes session id");

    my $pre_marker       = "pre-load log marker $$";
    my $post_marker      = "post-load log marker $$";
    my %logs_before      = map { $_ => 1 } glob("$temp_dir/chats-*.txt");
    my $session3_results = run_synergy_session(
        [
            ",comment $pre_marker\n",
            ",load $dump_file\n",
            ",comment $post_marker\n",
            ",exit\n",
        ],
        $SYNERGY_SCRIPT
    );

    my @new_logs = grep { !$logs_before{$_} } glob("$temp_dir/chats-*.txt");
    ok(@new_logs >= 1, "load: session produced at least one new logfile");
    my ($startup_logfile) = grep { slurp($_) =~ /\Q$pre_marker\E/ } @new_logs;
    ok($startup_logfile, "load: startup logfile path captured");

    my $loaded_logfile = "$temp_dir/chats-$loaded_session_id.txt";
    isnt($startup_logfile, $loaded_logfile,
        "load: loaded session logfile differs from second process startup logfile"
    );
    ok(-f $loaded_logfile, "load: loaded session logfile exists");
    like(slurp($loaded_logfile), qr/\Q$post_marker\E/,
        "load: post-load logging goes to loaded session logfile");
    like(slurp($startup_logfile), qr/\Q$pre_marker\E/,
        "load: pre-load marker stays in startup logfile");
    unlike(slurp($startup_logfile), qr/\Q$post_marker\E/,
        "load: post-load marker does not stay in pre-load logfile");
}

=head3 Test ,drop command (various positions)

=cut

{
    # Create 5 test files
    my @test_files;
    for my $i (1 .. 5) {
        my $test_file = "$temp_dir_simple/drop_test_file_$i.txt";
        open my $fh, '>', $test_file or die "Cannot create test file $i: $!";
        print $fh "Content of file $i.\n";
        close $fh;
        push @test_files, $test_file;
    }

    # Push all 5 files onto the stack
    my @push_commands = map {",push $_\n"} @test_files;

    # Case 1: Drop top file (index 4, last pushed)
    my $results1 = run_synergy_session(
        [
            @push_commands, ",drop\n",    # Should drop top element
            ",s\n",         ",exit\n",
        ]
    );

    like(
        $results1->{stdout},
        qr/Dropped top element: file: '\Q$test_files[4]\E'/,
        "drop: removes top element when no args given"
    );
    unlike(
        $results1->{stdout},
        qr/\* \[4\]: file: '\Q$test_files[4]\E'.*Content of file 5\./s,
        "drop: top file no longer in stack after drop"
    );
    like(
        $results1->{stdout},
        qr/\* \[3\]: file: '\Q$test_files[3]\E'.*Content of file 4\./s,
        "drop: file 4 is now at top after dropping file 5"
    );

    # Case 2: Drop bottom file (index 0)
    my $results2 = run_synergy_session(
        [
            @push_commands,
            ",drop 0\n",    # Drop first element (bottom of stack)
            ",s\n", ",exit\n",
        ]
    );

    like(
        $results2->{stdout},
        qr/Dropped 1 element\(s\):/,
        "drop: confirms dropping 1 element by index"
    );
    like(
        $results2->{stdout},
        qr/\[0\]: file: '\Q$test_files[0]\E'/,
        "drop: shows which element was dropped"
    );
    like(
        $results2->{stdout},
        qr/\[0\]: file: '\Q$test_files[1]\E'.*Content of file 2\./s,
        "drop: bottom file no longer in stack"
    );
    like(
        $results2->{stdout},
        qr/file: '\Q$test_files[1]\E'/,
        "drop: remaining files still in stack"
    );

    # Case 3: Drop middle file (index 2)
    my $results3 = run_synergy_session(
        [
            @push_commands, ",drop 2\n",    # Drop middle element
            ",s\n",         ",exit\n",
        ]
    );

    like(
        $results3->{stdout},
        qr/\[2\]: file: '\Q$test_files[2]\E'/,
        "drop: shows middle element was dropped"
    );
    unlike(
        $results3->{stdout},
        qr/   \[2\] file: '\Q$test_files[2]\E'.*Content of file 3/s,
        "drop: middle file no longer in stack"
    );
    like(
        $results3->{stdout},
        qr/file: '\Q$test_files[1]\E'/,
        "drop: files before dropped element remain"
    );
    like(
        $results3->{stdout},
        qr/file: '\Q$test_files[3]\E'/,
        "drop: files after dropped element remain"
    );

    # Case 4: Drop invalid index
    my $results4 = run_synergy_session(
        [
            @push_commands, ",drop 10\n",    # Invalid index
            ",exit\n",
        ]
    );

    like(
        $results4->{stdout},
        qr/Index out of range: 10 \(valid range: 0-4\)/,
        "drop: handles invalid index gracefully"
    );

    # Case 5: Drop from empty stack
    my $results5 = run_synergy_session(
        [
            ",drop\n",    # Try to drop from empty stack
            ",exit\n",
        ]
    );

    like(
        $results5->{stdout},
        qr/Stack is empty, nothing to drop\./,
        "drop: handles empty stack gracefully"
    );
}

=head3 Test ,dump and ,load roundtrip (version 1 and version 2 formats)

=cut

{
    # Test v1 format loading (plain text XML)
    my $v1_dump_file
      = "$ENV{SYNERGY_ROOT}/t/data/20250313-perl-number-triangle.xml";

    # Verify the v1 file exists
    ok(-f $v1_dump_file, "v1 dump file exists");

    # Load v1 dump and verify format characteristics
    my $session1_results = run_synergy_session(
        [",load $v1_dump_file\n", ",s\n", ",history\n", ",exit\n",]);

    like(
        $session1_results->{stdout},
        qr/Loading dump file '\Q$v1_dump_file\E'/,
        "load v1: indicates loading"
    );
    like($session1_results->{stdout},
        qr/file: '/, "load v1: restores file context");
    like(
        $session1_results->{stdout},
        qr/what is the actual highest sum from the example/,
        "load v1: restores conversation history"
    );

    # Verify v1 format characteristics by reading the XML directly
    my $v1_content = slurp($v1_dump_file);
    unlike($v1_content, qr/encoding="base64"/,
        "v1 format: does not use base64 encoding attributes");
    unlike($v1_content, qr/<dump[^>]*session=/,
        "v1 format: does not have session attribute on dump element");
    like(
        $v1_content,
        qr/please write some code in perl to find the highest sum of a number triangle/,
        "v1 format: contains plain text conversation"
    );

    # Test v2 format loading (base64 encoded XML)
    my $v2_dump_file
      = "$ENV{SYNERGY_ROOT}/t/data/20250609-sqlchecker-use-random-database.xml";

    # Verify the v2 file exists
    ok(-f $v2_dump_file, "v2 dump file exists");

    # Load v2 dump and verify format characteristics
    my $session2_results = run_synergy_session(
        [",load $v2_dump_file\n", ",s\n", ",history\n", ",exit\n",]);

    like(
        $session2_results->{stdout},
        qr/Loading dump file '\Q$v2_dump_file\E'/,
        "load v2: indicates loading"
    );
    like($session2_results->{stdout},
        qr/file: '/, "load v2: restores file context");
    like(
        $session2_results->{stdout},
        qr/please update the attached script/,
        "load v2: restores conversation history"
    );

    # Verify v2 format characteristics by reading the XML directly
    my $v2_content = slurp($v2_dump_file);
    like($v2_content, qr/encoding="base64"/,
        "v2 format: uses base64 encoding attributes");
    like(
        $v2_content,
        qr/<dump[^>]*session="[^"]+"/s,
        "v2 format: has session attribute on dump element"
    );
    like(
        $v2_content,
        qr/<prompt[^>]*encoding="base64"/s,
        "v2 format: has encoding attribute on prompt element"
    );
    unlike(
        $v2_content,
        qr/please update the attached script/,
        "v2 format: conversation is base64 encoded"
    );

    # Test that session ID is preserved during load
    like(
        $session1_results->{stdout},
        qr/WARNING: No session ID found in '\Q$v1_dump_file\E'/,
        "v1 roundtrip: session IDs did not exist yet"
    );
    like(
        $session2_results->{stdout},
        qr/Loading session ID.*ok/,
        "v2 roundtrip: session ID preserved"
    );

    # Test cross-version compatibility: ensure both formats can be loaded
    my $session3_results = run_synergy_session(
        [",reset\n", ",load $v1_dump_file\n", ",s\n", ",exit\n",]);

    like(
        $session3_results->{stdout},
        qr/Loading dump file '\Q$v1_dump_file\E'/,
        "cross-compat: v1 format loads"
    );
    like($session3_results->{stdout},
        qr/file: '/, "cross-compat: v1 file context restored");

    my $session4_results = run_synergy_session(
        [",reset\n", ",load $v2_dump_file\n", ",s\n", ",exit\n",]);

    like(
        $session4_results->{stdout},
        qr/Loading dump file '\Q$v2_dump_file\E'/,
        "cross-compat: v2 format loads"
    );
    like($session4_results->{stdout},
        qr/file: '/, "cross-compat: v2 file context restored");
}

=head3 Test ,exec command (basic functionality)

=cut

{
    # Create a test file with some content to search
    my $test_file = "$temp_dir/exec_test_file.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "sub fn_one {\n";
    print $fh "    return 1;\n";
    print $fh "}\n";
    print $fh "sub fn_two {\n";
    print $fh "    return 2;\n";
    print $fh "}\n";
    print $fh "not a sub line\n";
    close $fh;

    my $results = run_synergy_session(
        [",exec rg -n sub $test_file\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/exec: rg -n sub/,
        "exec: shows command being executed"
    );
    like(
        $results->{stdout},
        qr/exec: output saved to '\/tmp\/synergy_exec_pid_\d+_timestamp_\d+\.\d+\.txt'/,
        "exec: indicates output file location"
    );
    like(
        $results->{stdout},
        qr/COMMAND:\nrg -n sub $test_file\nOUTPUT:\n1:sub fn_one \{\n4:sub fn_two \{\n7:not a sub line/,
        "exec: output file is printed to convo stdout"
    );
    like(
        $results->{stdout},
        qr/OUTPUT:\n1:sub fn_one/,
        "exec: convo stdout contains rg output (line 1)"
    );
}

=head3 Test ,exec command (blocked command)

The deny tier applies to everyone, human or agent.

=cut

{
    my $results
      = run_synergy_session([",exec rm /tmp/somefile\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: Command 'rm' is not permitted in ,exec/,
        "exec: rejects blocked commands"
    );
    unlike(
        $results->{stdout},
        qr/exec: output saved to/,
        "exec: blocked command is not executed"
    );
}

=head3 Test ,exec command (quoted args, regex metachars, and sed scripts)

These cases used to fail due to naive `split / /` parsing and/or a broad
"shell metacharacters" filter. With `shellwords` parsing + list-form exec,
they should work.

=cut

{
    # Create a test file with some content to search/sed
    my $test_file = "$temp_dir/exec_metachar_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "fn_one\n";
    print $fh "fn_two\n";
    print $fh "other\n";
    close $fh;

    # rg regex with grouping + alternation + end-anchor
    my $results1 = run_synergy_session(
        [",exec rg -n '(fn_one|fn_two)\$' $test_file\n", ",exit\n",]);

    like($results1->{stdout}, qr/1:fn_one\n2:fn_two/,
        'exec: rg grouping/alternation/$ anchor works (quoted arg preserved)'
    );

    # sed with two commands separated by ';' inside a quoted script
    my $results2
      = run_synergy_session(
        [",exec sed -e 's/fn_/FN_/;s/other/OTHER/' $test_file\n", ",exit\n",]
      );

    like($results2->{stdout}, qr/FN_one\nFN_two\nOTHER/,
        "exec: sed script containing ';' works (quoted arg preserved)");
}

=head3 Test ,exec command (no arguments)

=cut

{
    my $results = run_synergy_session([",exec\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: No command provided to ,exec/,
        "exec: handles missing command gracefully"
    );
}

=head3 Test ,exec runs commands outside the allowlist for the human

The confirm tier needs no prompt on the human path: typing the
command is the approval.

=cut

{
    my $results = run_synergy_session([",exec printf hello\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/exec: printf hello/,
        "exec: shows command being executed"
    );
    like(
        $results->{stdout},
        qr/exec: output saved to '\/tmp\/synergy_exec_pid_\d+_timestamp_\d+\.\d+\.txt'/,
        "exec: indicates output file location"
    );
    like(
        $results->{stdout},
        qr/COMMAND:\nprintf hello\nOUTPUT:\nhello/,
        "exec: confirm-tier command runs without prompting the human"
    );
    is($results->{exit_code}, 0, "exec: basic command exits cleanly");
}

=head3 Test ,exec command supports pipelines

=cut

{
    my $results = run_synergy_session(
        [",exec printf 'a\\nb\\n' | sed -n 2p\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/COMMAND:\nprintf a\\nb\\n \| sed -n 2p\nOUTPUT:\nb\n/,
        "exec: pipeline is executed segment by segment"
    );
    is($results->{exit_code}, 0, "exec: pipeline exits cleanly");
}

=head3 Test ,exec command rejects redirection

=cut

{
    my $redirect_file = "$temp_dir/exec_redirect_capture.txt";
    my $results       = run_synergy_session(
        [",exec printf hello > $redirect_file\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: shell operator '>' is not supported in ,exec \(only '\|' pipelines\)/,
        "exec: redirection is rejected with a specific error"
    );
    ok(!-e $redirect_file, "exec: rejected redirect creates no file");
    is($results->{exit_code}, 0, "exec: redirect rejection exits cleanly");
}

=head3 Test ,exec command handles non-zero exit

=cut

{
    my $results = run_synergy_session([",exec false\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/WARNING: Command exited with status 1/,
        "exec: non-zero exit is reported"
    );
    is($results->{exit_code}, 0, "exec: non-zero exit does not kill REPL");
}

=head3 Test ,shell command is gone

=cut

{
    my $results = run_synergy_session([",shell printf hello\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/This is Synergy\. You are interacting with the command processor\./,
        "shell: removed command falls through to help"
    );
    unlike($results->{stdout}, qr/^hello$/m,
        "shell: removed command is not executed");
    is($results->{exit_code}, 0, "shell: removed command exits cleanly");
}

=head3 Test ,exec command (command with no output)

=cut

{
    my $results = run_synergy_session(
        [",exec rg nonexistent /dev/null\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/WARNING: Command exited with status \d+/,
        "exec: handles commands with non-zero exit status"
    );
}

=head3 Test ,exec command (file operations)

=cut

{
    # Test with ls command
    my $results = run_synergy_session(
        [",exec ls $temp_dir_simple\n", ",s\n", ",exit\n",]);

    like($results->{stdout}, qr/exec: ls/, "exec: ls command executes");
    like(
        $results->{stdout},
        qr/COMMAND:\nls \/tmp\nOUTPUT:\n1\.txt\n2\.txt\n3\.txt\n4\.txt\n5\.txt\n6\.txt/,
        "exec: ls output printed to convo stdout"
    );
}

=head3 Test ,history pager uses tempfile-backed pager with explicit fallback

=cut

{
    my $src = slurp($SYNERGY_SCRIPT);
    like(
        $src,
        qr/tempfile\('synergy_pager_XXXX', TMPDIR => 1, SUFFIX => '\.txt'\)/,
        "history pager: writes output to a temp file"
    );
    like(
        $src,
        qr/unless \(-t STDIN && -t STDOUT\)/,
        "history pager: only pages when both stdin and stdout are ttys"
    );
    like(
        $src,
        qr/my \@pager_argv = \('less'\);/,
        "history pager: uses hardcoded less pager"
    );
    unlike($src, qr/\$ENV\{PAGER\}/,
        "history pager: does not consult PAGER env var");
    like(
        $src,
        qr/WARNING: pager failed/,
        "history pager: warns before direct-print fallback on pager failure"
    );
    like(
        $src,
        qr/print \$text.*return.*my \$ok = eval/s,
        "history pager: retains direct-print path for non-interactive sessions"
    );
    unlike(
        $src,
        qr/if \(!\$ok\) \{\s*# Soft failure:.*silent fallback/s,
        "history pager: no longer falls back silently when pager invocation fails"
    );
    like(
        $src,
        qr/This avoids readline\/pipe interactions.*saw EOF after the pager exits\./s,
        "history pager: source documents why tempfile paging is used"
    );
}

=head3 Test ,exec command (git runs directly in user mode)

=cut

{
    my $results = run_synergy_session([",exec git status\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/COMMAND:\ngit status/,
        "exec git: runs git directly in user mode"
    );
    unlike(
        $results->{stdout},
        qr/Allow this git command to run\?/,
        "exec git: no longer prompts for confirmation in user mode"
    );
    unlike(
        $results->{stdout},
        qr/INFO: git command cancelled by user/,
        "exec git: no longer cancels based on a user confirmation prompt"
    );
}

=head3 Test ,exec command integration with other stack commands

=cut

{
    # Create test file
    my $test_file = "$temp_dir/stack_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\nline2\nline3\n";
    close $fh;

    my $results = run_synergy_session(
        [
            ",exec wc -l $test_file\n",      # Should show "3"
            ",exec rg line $test_file\n",    # Should show all lines
            ",s\n",                          # Show stack
            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/3 \Q$test_file\E/,
        "exec: wc output captured correctly"
    );
    like($results->{stdout}, qr/line1.*line2.*line3/s,
        "exec: rg output captured correctly");
}

=head3 Test ,push carries real UTF-8 into the request, not '?' scrub

Regression for the encoding pipeline: pushed UTF-8 files used to be
byte-scrubbed to '?' placeholders, so the model never saw the real
content (and could only echo '?'s back into patches).

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $utf8_file = "$temp_dir/push_utf8_$$.txt";
    open my $ufh, '>', $utf8_file or die "Cannot create $utf8_file: $!";
    print {$ufh} "marker \xe2\x80\x9cquoted\xe2\x80\x9d \xe2\x97\x8f end\n";
    close $ufh;

    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";

    my $results = run_synergy_session(
        [",push $utf8_file\n", "utf8 push probe\n", ",exit\n"]);

    is($results->{exit_code}, 0, "push utf8: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "push utf8: captured request body");
    my $body = decode_json(slurp($body_file));
    my ($context_msg)
      = grep { ($_->{content} // '') =~ /Relevant file\/context state/ }
      @{$body->{input}};
    ok($context_msg, "push utf8: context message present");
    like(
        $context_msg->{content},
        qr/marker \x{201c}quoted\x{201d} \x{25cf} end/,
        "push utf8: real characters reach the request"
    );
    unlike(
        $context_msg->{content},
        qr/marker \?+quoted/,
        "push utf8: no '?' scrub in the request"
    );
}

=head3 Test ,exec output keeps real UTF-8

=cut

{
    my $utf8_file = "$temp_dir/exec_utf8_$$.txt";
    open my $ufh, '>', $utf8_file or die "Cannot create $utf8_file: $!";
    print {$ufh} "arrow \xe2\x94\x80\xe2\x96\xb6 done\n";
    close $ufh;

    my $results = run_synergy_session([",exec cat $utf8_file\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/arrow \xe2\x94\x80\xe2\x96\xb6 done/,
        "exec utf8: command output shows real characters"
    );
    unlike(
        $results->{stdout},
        qr/arrow \?+ done/,
        "exec utf8: command output is not scrubbed to '?'"
    );
}

=head3 Test ,push falls back to '?' scrub for non-UTF-8 (binary) files

=cut

{
    my $binary_file = "$temp_dir/push_binary_$$.dat";
    open my $bfh, '>', $binary_file or die "Cannot create $binary_file: $!";
    print {$bfh} "head \xff\xfe\x01 tail\n";
    close $bfh;

    my $results
      = run_synergy_session([",push $binary_file\n", ",peek 0\n", ",exit\n"]);

    is($results->{exit_code}, 0, "push binary: exits cleanly");

    # \xff and \xfe are scrubbed; \x01 is ASCII and passes through.
    like(
        $results->{stdout},
        qr/head \?\?\x01 tail/,
        "push binary: invalid UTF-8 falls back to '?' placeholders"
    );
    unlike($results->{stdout}, qr/\xff/,
        "push binary: raw invalid bytes do not reach the terminal");
}

=head3 Test stale pushed-file detection: announce once, never rewrite

A pushed text file is a snapshot; when the disk copy changes, both
workers get a NOTE (once per on-disk version) telling them to
,drop + ,push. The stack entry itself is never rewritten.

=cut

{
    my $stale_file = "$temp_dir/stale_detect_$$.txt";
    open my $sfh, '>', $stale_file or die "Cannot create $stale_file: $!";
    print {$sfh} "original content line\n";
    close $sfh;

    my $results = run_synergy_session(
        [
            ",push $stale_file\n",
            "first stale probe\n",
            ",exec perl -i -pe 's/original/CHANGED/' $stale_file\n",
            "second stale probe\n",
            "third stale probe\n",
            ",peek 0\n",
            ",history\n",
            ",exit\n",
        ]
    );

    is($results->{exit_code}, 0, "stale detect: exits cleanly");

    # Announced exactly once live, and once more when ,history
    # replays the conversation entry; a third occurrence would mean
    # the dedupe failed.
    my @notes = $results->{stdout}
      =~ /(NOTE: context entry \[0\] for '\Q$stale_file\E' is stale \(file changed on disk\))/g;
    is(scalar @notes,
        2, "stale detect: announced once live and recorded once in history");
    like(
        $results->{stdout},
        qr/,drop 0 then ,push \Q$stale_file\E to refresh/,
        "stale detect: note names the explicit refresh commands"
    );
    like(
        $results->{stdout},
        qr/contents: original content line/,
        "stale detect: context entry is never rewritten behind the workers' backs"
    );
}

done_testing();

END {
    chdir $original_cwd;
}
