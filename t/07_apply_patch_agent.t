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

my $temp_dir        = tempdir(DIR => $ENV{HOME}, CLEANUP => 1);
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

=head3 Test agent-mode ,apply_patch tolerates marker-like text in file content

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_meta_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh <<'FILECONTENT';
# Legacy example:
# <<<<<< ORIGINAL
# =======
# >>>>>> UPDATED
# Removed nonce example:
# <<< ORIGINAL PATCH_EXAMPLE
# <<< END PATCH PATCH_EXAMPLE
PLACEHOLDER
FILECONTENT
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
PLACEHOLDER
=======
updated_line
>>>>>> UPDATED
,comment AGENT_COMPLETE: meta markers ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test apply_patch meta markers\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch meta-markers: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/agent: apply_patch \Q$test_file\E/,
        "agent apply_patch meta-markers: does not pre-echo apply_patch before result"
    );

    my $patched = slurp($test_file);
    like($patched, qr/updated_line/,
        "agent apply_patch meta-markers: replacement present");
    like(
        $patched,
        qr/<<<<<< ORIGINAL/,
        "agent apply_patch meta-markers: legacy marker text preserved"
    );
    like(
        $patched,
        qr/<<< ORIGINAL PATCH_EXAMPLE/,
        "agent apply_patch meta-markers: removed-protocol marker text preserved"
    );

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch parsing/execution (unquoted payload)

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_unquoted_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "alpha\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
alpha
=======
beta
>>>>>> UPDATED
,comment AGENT_COMPLETE: unquoted apply_patch ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test unquoted apply_patch\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch unquoted: patch applied"
    );
    is($results->{exit_code}, 0, "agent apply_patch unquoted: exits cleanly");

    my $patched = slurp($test_file);
    is($patched, "beta\n",
        "agent apply_patch unquoted: file content updated");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch parsing/execution (quoted payload)

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_quoted_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "one\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file '<<<<<< ORIGINAL
one
=======
two
>>>>>> UPDATED'
,comment AGENT_COMPLETE: quoted apply_patch ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test quoted apply_patch\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch quoted: patch applied"
    );

    my $patched = slurp($test_file);
    is($patched, "two\n", "agent apply_patch quoted: file content updated");

    unlink $test_file;
}

=head3 Test agent-mode parsing with prose + multiple commands + apply_patch

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_multi_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "A\n";
    close $fh;

    my $response = <<EOF;
I will edit the file now.
,comment before
,apply_patch $test_file <<<<<< ORIGINAL
A
=======
B
>>>>>> UPDATED
Post-edit prose that should be ignored.
,comment after
,comment AGENT_COMPLETE: multi-command apply_patch ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test multi command apply_patch\n", ",exit\n"]);

    like($results->{stdout}, qr/before/,
        "agent parser: executes comment before apply_patch");
    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent parser: executes apply_patch in mixed prose/commands"
    );
    like($results->{stdout}, qr/after/,
        "agent parser: executes comment after apply_patch");

    my $patched = slurp($test_file);
    is($patched, "B\n",
        "agent parser: apply_patch changed file in mixed prose/commands");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch is single-hunk only

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_single_hunk_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "alpha\nmiddle\nomega\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
alpha
=======
ALPHA
>>>>>> UPDATED
<<<<<< ORIGINAL
omega
=======
OMEGA
>>>>>> UPDATED
,comment AGENT_COMPLETE: single-hunk apply_patch ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test single-hunk apply_patch\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch single-hunk: first hunk applied"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR:/,
        "agent apply_patch single-hunk: no parser errors"
    );

    my $patched = slurp($test_file);
    is($patched, "ALPHA\nmiddle\nomega\n",
        "agent apply_patch single-hunk: trailing hunk-like text ignored");
    unlike($patched, qr/OMEGA/,
        "agent apply_patch single-hunk: later hunk replacement not applied");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch tolerant terminator with trailing text

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_trailing_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "x\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file '<<<<<< ORIGINAL
x
=======
y
>>>>>> UPDATED' trailing words that should be ignored
,comment AGENT_COMPLETE: trailing terminator tolerated
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test trailing apply_patch terminator\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch trailing terminator: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: Incomplete ,apply_patch/,
        "agent apply_patch trailing terminator: no incomplete parser error"
    );

    my $patched = slurp($test_file);
    is($patched, "y\n",
        "agent apply_patch trailing terminator: file content updated");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch accepts variable-width fences

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_variable_fences_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "x\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<< ORIGINAL
x
========
y
>>>>>>>> UPDATED trailing words still ignored
,comment AGENT_COMPLETE: variable-width fences tolerated
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test variable-width apply_patch fences\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch variable-fences: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/AGENT ERROR: Incomplete ,apply_patch/,
        "agent apply_patch variable-fences: no incomplete parser error"
    );

    is(slurp($test_file), "y\n",
        "agent apply_patch variable-fences: file content updated");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch fallback: line-ending normalization

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_line_endings_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "alpha\r\nbeta\r\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
alpha
beta
=======
alpha
BETA
>>>>>> UPDATED
,comment AGENT_COMPLETE: line ending fallback ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test line-ending fallback\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch line-endings fallback: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/WARNING: Search text not found/,
        "agent apply_patch line-endings fallback: no search-miss warning"
    );

    my $patched = slurp($test_file);
    like($patched, qr/BETA/,
        "agent apply_patch line-endings fallback: updated content present");

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch fallback: whitespace-tolerant unique match

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_ws_fuzzy_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "my    value\t=   42;\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
my value = 42;
=======
my value = 99;
>>>>>> UPDATED
,comment AGENT_COMPLETE: ws fallback ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results
      = run_synergy_file_session([",agent test ws fallback\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch ws-fuzzy fallback: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/WARNING: Search text not found/,
        "agent apply_patch ws-fuzzy fallback: no search-miss warning"
    );

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/my value = 99;/,
        "agent apply_patch ws-fuzzy fallback: updated content present"
    );

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch fallback: anchor-window unique span

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_anchor_window_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "start anchor\nmiddle actual line\nend anchor\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
start anchor
middle model guessed line
end anchor
=======
start anchor
middle updated line
end anchor
>>>>>> UPDATED
,comment AGENT_COMPLETE: anchor fallback ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test anchor-window fallback\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch anchor-window fallback: patch applied"
    );
    unlike(
        $results->{stdout},
        qr/WARNING: Search text not found/,
        "agent apply_patch anchor-window fallback: no search-miss warning"
    );

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/middle updated line/,
        "agent apply_patch anchor-window fallback: updated content present"
    );

    unlink $test_file;
}

=head3 Test agent-mode ,apply_patch diagnostics on search-miss include pass details

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_diag_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "unrelated text\n";
    close $fh;

    my $response = <<EOF;
,apply_patch $test_file <<<<<< ORIGINAL
line one not present
line two not present
=======
replacement text
>>>>>> UPDATED
,comment AGENT_COMPLETE: diagnostics case
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test diagnostics on miss\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/WARNING: Search text not found/,
        "agent apply_patch diagnostics: warning emitted on miss"
    );
    like(
        $results->{stdout},
        qr/apply_patch diagnostics: chars=\d+ lines=\d+ .* attempted_passes=/s,
        "agent apply_patch diagnostics: includes chars/lines and attempted passes"
    );
    like(
        $results->{stdout},
        qr/attempted_passes=exact=0, line_endings=.* ws_fuzzy=.* anchor_window=/,
        "agent apply_patch diagnostics: includes per-pass outcomes"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        "unrelated text\n",
        "agent apply_patch diagnostics: file unchanged after failed match"
    );

    unlink $test_file;
}

=head3 Test agent-mode incomplete ,apply_patch payload emits deterministic error

=cut

{
    my $test_file = "$temp_dir/agent_apply_patch_incomplete_$$.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "x\n";
    close $fh;

    my $response = <<EOF;
,comment AGENT_COMPLETE: stop after testing incomplete apply_patch
,apply_patch $test_file <<<<<< ORIGINAL
x
=======
y
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $results = run_synergy_file_session(
        [",agent test incomplete apply_patch\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/AGENT ERROR: Incomplete ,apply_patch for '\Q$test_file\E': missing '>>>>>> UPDATED' terminator/,
        "agent apply_patch incomplete: emits deterministic parser error"
    );
    unlike(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "agent apply_patch incomplete: does not invoke apply_patch handler"
    );

    my $patched = slurp($test_file);
    is($patched, "x\n",
        "agent apply_patch incomplete: file remains unchanged");
    like(
        $results->{stdout},
        qr/WARNING: agent completed without running any commands/,
        "agent apply_patch incomplete: warns when completing after parser-only failure"
    );

    unlink $test_file;
}


done_testing();

END {
    chdir $original_cwd;
}
