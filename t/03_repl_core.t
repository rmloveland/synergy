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
        qr/,shell\s+cmd\s+Execute an arbitrary shell command via \/bin\/sh -lc/,
        "help: documents shell"
    );
    is($results->{exit_code}, 0, "help: exits cleanly");
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
      = ($dump_xml =~ /<dump time="[^"]+" session="([^"]+)">/);
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

=head3 Test ,swap command

=cut

{
    # Create 5 test files
    my @test_files;
    for my $i (1 .. 5) {
        my $test_file = "$temp_dir/$i.txt";
        open my $fh, '>', $test_file or die "Cannot create test file $i: $!";
        print $fh "$i.txt\n";
        close $fh;
        push @test_files, $test_file;
    }

    # Push all 5 files onto the stack
    my @push_commands = map {",push $_\n"} @test_files;

    # Test swap: should swap top two elements (4.txt and 5.txt)
    # Stack before: [1.txt, 2.txt, 3.txt, 4.txt, 5.txt]
    # Stack after:  [1.txt, 2.txt, 3.txt, 5.txt, 4.txt]
    my $results
      = run_synergy_session([@push_commands, ",swap\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr{\[3\]: file: '$test_files[4]'},
        "swap: moves 5.txt to second from top of stack"
    );
    like(
        $results->{stdout},
        qr{\* \[4\]: file: '$test_files[3]'}s,
        "swap: 4.txt should be on top of stack"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[2]\E'/,
        "swap: 3.txt remains in middle"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[0]\E'/,
        "swap: 1.txt remains at bottom"
    );
}

=head3 Test ,rot command

=cut

{
    # Create 6 test files for rotation testing
    my @test_files;
    for my $i (1 .. 6) {
        my $test_file = "$temp_dir_simple/$i.txt";
        open my $fh, '>', $test_file or die "Cannot create test file $i: $!";
        print $fh "$i.txt\n";
        close $fh;
        push @test_files, $test_file;
    }

    # Push all 6 files onto the stack
    my @push_commands = map {",push $_\n"} @test_files;

    # Test rot: should move bottom element to top
    # Stack before: [1.txt, 2.txt, 3.txt, 4.txt, 5.txt, 6.txt]
    # Stack after:  [2.txt, 3.txt, 4.txt, 5.txt, 6.txt, 1.txt]
    my $results
      = run_synergy_session([@push_commands, ",rot\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/file: '\Q$test_files[0]\E'/,    # 1.txt should now be at top
        "rot: moves bottom element (1.txt) to top"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[5]\E'.*file: '\Q$test_files[0]\E'/s,
        "rot: 6.txt should be second from top"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[1]\E'/,
        "rot: 2.txt should now be at bottom"
    );
    like(
        $results->{stdout},
        qr/   \[0\]: file: '\Q$test_files[5]\E' contents: 6\.txt/s,
        "rot: 5.txt should not be followed by 6.txt (order changed)"
    );
}

=head3 Test ,swap and ,rot combination

=cut

{
    # Create 4 test files for combination testing
    my @test_files;
    for my $i (1 .. 4) {
        my $test_file = "$temp_dir/$i.txt";
        open my $fh, '>', $test_file or die "Cannot create test file $i: $!";
        print $fh "$i.txt\n";
        close $fh;
        push @test_files, $test_file;
    }

    # Push all 4 files onto the stack
    my @push_commands = map {",push $_\n"} @test_files;

    # Test combination: swap then rot
    # Initial:     [1.txt, 2.txt, 3.txt, 4.txt]
    # After swap:  [1.txt, 2.txt, 4.txt, 3.txt]
    # After rot:   [2.txt, 4.txt, 3.txt, 1.txt]
    my $results = run_synergy_session(
        [@push_commands, ",swap\n", ",rot\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/file: '\Q$test_files[0]\E'/,    # 1.txt should be at top after rot
        "swap+rot: 1.txt at top after combination"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[2]\E'.*file: '\Q$test_files[0]\E'/s,
        "swap+rot: 3.txt second from top"
    );
    like(
        $results->{stdout},
        qr/file: '\Q$test_files[1]\E'/,
        "swap+rot: 2.txt should be at bottom"
    );
}

=head3 Test ,swap on stack with only one element

=cut

{
    # Create 1 test file
    my $test_file = "$temp_dir/single.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "single.txt\n";
    close $fh;

    # Test swap with only one element (should handle gracefully)
    my $results = run_synergy_session(
        [",push $test_file\n", ",swap\n", ",s\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/file: '\Q$test_file\E'/,
        "swap: single element remains unchanged"
    );
    is($results->{exit_code}, 0, "swap: single element exits cleanly");
}

=head3 Test ,rot on empty stack

=cut

{
    # Test rot on empty stack (should handle gracefully)
    my $results = run_synergy_session([",rot\n", ",s\n", ",exit\n",]);

    like($results->{stdout}, qr/\[ \]/, "rot: empty stack remains empty");
    is($results->{exit_code}, 0, "rot: empty stack exits cleanly");
}

=head3 Test ,swap on empty stack

=cut

{
    # Test rot on empty stack (should handle gracefully)
    my $results = run_synergy_session([",swap\n", ",s\n", ",exit\n",]);

    like($results->{stdout}, qr/\[ \]/, "swap: empty stack remains empty");
    is($results->{exit_code}, 0, "swap: empty stack exits cleanly");
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

=head3 Test ,exec command (invalid command)

=cut

{
    my $results
      = run_synergy_session([",exec rm /tmp/somefile\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: Command 'rm' not allowed in ,exec mode/,
        "exec: rejects disallowed commands"
    );
    like(
        $results->{stdout},
        qr/Allowed commands:/,
        "exec: shows list of allowed commands"
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

=head3 Test ,shell command

=cut

{
    my $results = run_synergy_session([",shell printf hello\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/shell: printf hello/,
        "shell: shows command being executed"
    );
    like(
        $results->{stdout},
        qr/shell: output saved to '\/tmp\/synergy_shell_pid_\d+_timestamp_\d+\.\d+\.txt'/,
        "shell: indicates output file location"
    );
    like(
        $results->{stdout},
        qr/COMMAND:\nprintf hello\nOUTPUT:\nhello/,
        "shell: basic output is captured and shown"
    );
    is($results->{exit_code}, 0, "shell: basic command exits cleanly");
}

=head3 Test ,shell command supports pipelines

=cut

{
    my $results = run_synergy_session(
        [",shell printf 'a\\nb\\n' | sed -n 2p\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/COMMAND:\nprintf 'a\\nb\\n' \| sed -n 2p\nOUTPUT:\nb\n/,
        "shell: pipeline syntax is preserved and executed"
    );
    is($results->{exit_code}, 0, "shell: pipeline exits cleanly");
}

=head3 Test ,shell command preserves redirects and stderr merging

=cut

{
    my $merge_file = "$temp_dir/shell_redirect_capture.txt";
    my $results    = run_synergy_session(
        [
            ",shell sh -c 'echo out; echo err 1>&2' > $merge_file 2>&1\n",
            ",shell cat $merge_file\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/shell: cat \Q$merge_file\E/,
        "shell: follow-up cat command executes"
    );
    like(
        $results->{stdout},
        qr/COMMAND:\ncat \Q$merge_file\E\nOUTPUT:\nout\nerr\n/,
        "shell: redirects and stderr merge survive parsing"
    );
    is($results->{exit_code}, 0, "shell: redirect case exits cleanly");
}

=head3 Test ,shell command handles non-zero exit

=cut

{
    my $results = run_synergy_session([",shell false\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/WARNING: Command exited with status 1/,
        "shell: non-zero exit is reported"
    );
    is($results->{exit_code}, 0, "shell: non-zero exit does not kill REPL");
}

=head3 Test ,shell command with no arguments

=cut

{
    my $results = run_synergy_session([",shell\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: Usage: ,shell <cmd>/,
        "shell: empty usage error is shown"
    );
    is($results->{exit_code}, 0, "shell: empty usage exits cleanly");
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
        qr/Allow this git command to run\? \[y\/N\]/,
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


done_testing();

END {
    chdir $original_cwd;
}
