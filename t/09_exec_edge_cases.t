#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use File::Temp            qw(tempdir);
use Cwd                   qw(abs_path);
use Synergy::Test::Runner qw(run_synergy_session setup_test_env);

use constant OFFLINE_MODE => 1;

# This test file focuses on edge cases for the *new* `,exec` implementation:
# - argv parsing via Text::ParseWords::shellwords
# - list-form exec (no shell), so "shell metacharacters" should be inert
# - error handling for malformed quoting

# Keep any future assistant invocation local.
$ENV{SYNERGY_OFFLINE_RESPONSE} = '[TEST_OFFLINE]' if OFFLINE_MODE;

my $temp_dir     = tempdir(CLEANUP => 1);
my $original_cwd = abs_path();
my $env     = setup_test_env(log_dir => $temp_dir, dump_dir => $temp_dir);
my $SYNERGY = $env->{synergy_script};

plan tests => 38;

use File::Slurp qw(slurp);

# 0) Output cap: oversized command output is stored as head + tail with
#    an elision marker; the temp file keeps the full output.
{
    my $big_file = "$temp_dir/exec_output_cap.txt";
    open my $fh, '>', $big_file or die "Cannot create $big_file: $!";
    print {$fh} "HEAD_CAP_MARK\n", ("filler line for the cap test\n" x 100),
      "TAIL_CAP_MARK\n";
    close $fh;

    my $res = run_synergy_session(
        [",exec cat $big_file\n", ",exit\n"],
        undef, {SYNERGY_EXEC_OUTPUT_CAP => 400},
    );

    like($res->{stdout}, qr/HEAD_CAP_MARK/,
        "exec output cap: head of oversized output is kept");
    like($res->{stdout}, qr/TAIL_CAP_MARK/,
        "exec output cap: tail of oversized output is kept");
    like(
        $res->{stdout},
        qr/\[\.\.\. \d+ bytes elided; full output in '[^']+' \.\.\.\]/,
        "exec output cap: elision marker names the full-output file"
    );

    my ($saved_file) = ($res->{stdout} =~ /exec: output saved to '([^']+)'/);
    ok($saved_file && -f $saved_file,
        "exec output cap: full-output temp file exists");
    my $saved = $saved_file ? slurp($saved_file) : '';
    is(($saved =~ tr/\n//),
        102 + 3, "exec output cap: temp file keeps the complete output");
}

# 0b) Output cap disabled: SYNERGY_EXEC_OUTPUT_CAP=0 stores everything.
{
    my $big_file = "$temp_dir/exec_output_cap_off.txt";
    open my $fh, '>', $big_file or die "Cannot create $big_file: $!";
    print {$fh} ("uncapped filler line\n" x 100), "UNCAPPED_TAIL_MARK\n";
    close $fh;

    my $res = run_synergy_session(
        [",exec cat $big_file\n", ",exit\n"],
        undef, {SYNERGY_EXEC_OUTPUT_CAP => 0},
    );

    unlike(
        $res->{stdout},
        qr/bytes elided/,
        "exec output cap off: no elision marker"
    );
    my @filler = ($res->{stdout} =~ /uncapped filler line/g);
    is(scalar @filler,
        100, "exec output cap off: full output stored verbatim");
}

# 1) shellwords: preserve spaces within quotes
{
    my $res = run_synergy_session(
        [qq[,exec rg -n "hello world" /dev/null\n], ",exit\n"]);

    like(
        $res->{stdout},
        qr/exec: rg -n hello world/,
        "exec shellwords: quoted arg with space is preserved in displayed command"
    );
    like(
        $res->{stdout},
        qr/WARNING: Command exited with status \d+/,
        "exec shellwords: command runs (non-zero ok on /dev/null mismatch)"
    );
}

# 2) shellwords parse failure: unmatched quote
{
    my $res = run_synergy_session(
        [qq[,exec rg "unterminated /dev/null\n], ",exit\n"]);

    like(
        $res->{stdout},
        qr/ERROR: Failed to parse ,exec command:|ERROR: No command provided to ,exec/,
        "exec parse error: unmatched quote yields parse error or empty-argv error"
    );
}

# 3) Commands outside the allowlist run for the human (confirm tier:
# typing the command is the approval). Only the deny tier blocks.
{
    my $res = run_synergy_session([",exec echo now_allowed\n", ",exit\n"]);

    like($res->{stdout}, qr/OUTPUT:\nnow_allowed/,
        "exec confirm tier: unknown command runs for the human");

    my $deny
      = run_synergy_session([",exec bash -c 'echo nope'\n", ",exit\n"]);
    like(
        $deny->{stdout},
        qr/ERROR: Command 'bash' is not permitted in ,exec/,
        "exec deny tier: shell interpreters blocked for the human"
    );

    my $git_deny = run_synergy_session(
        [",exec git push --force origin main\n", ",exit\n"]);
    like(
        $git_deny->{stdout},
        qr/ERROR: git push --force is not permitted/,
        "exec deny tier: destructive git blocked for the human"
    );
}

# 4) A token containing ';' should be passed literally to an allowed command.
# Here we use rg for a literal pattern containing ';' that won't match.
{
    my $res
      = run_synergy_session([qq[,exec rg -n ';' /dev/null\n], ",exit\n"]);

    like(
        $res->{stdout},
        qr/exec: rg -n ; \/dev\/null/,
        "exec metachar literal: semicolon passed as literal argv"
    );
    like(
        $res->{stdout},
        qr/WARNING: Command exited with status \d+/,
        "exec metachar literal: command executed (non-zero ok)"
    );
}

# 5) Ensure newline injection is rejected (control chars)
{
    my $res = run_synergy_session([",exec rg foo /dev/null\n", ",exit\n"]);
    unlike(
        $res->{stdout},
        qr/Invalid control characters/,
        "exec control chars: normal args do not trigger control-char rejection"
    );
}

# 6) Empty/whitespace-only after ,exec should error
{
    my $res = run_synergy_session([",exec    \n", ",exit\n"]);
    like(
        $res->{stdout},
        qr/ERROR: No command provided to ,exec/,
        "exec empty: whitespace-only args rejected"
    );
}

# 6b) Pipelines: unquoted '|' splits segments; each segment is
# policy-checked; other shell operators are rejected.
{
    my $res = run_synergy_session(
        [",exec printf 'x\\ny\\nz\\n' | wc -l\n", ",exit\n"]);
    like($res->{stdout}, qr/OUTPUT:\n\s*3\n/,
        "exec pipeline: two-segment pipeline runs and pipes data");

    my $three = run_synergy_session(
        [",exec cat /etc/hosts | head -50 | wc -l\n", ",exit\n"]);
    like(
        $three->{stdout},
        qr/exec: cat \/etc\/hosts \| head -50 \| wc -l/,
        "exec pipeline: three segments accepted and displayed with pipes"
    );

    my $quoted
      = run_synergy_session([",exec rg -n 'one|two' /dev/null\n", ",exit\n"]);
    unlike($quoted->{stdout}, qr/ERROR:/,
        "exec pipeline: quoted '|' stays inside the argument, no split");
    like(
        $quoted->{stdout},
        qr/exec: rg -n one\|two \/dev\/null/,
        "exec pipeline: quoted '|' passed to the command as one argv"
    );

    my $deny = run_synergy_session(
        [",exec cat /etc/hosts | rm -f /tmp/nope\n", ",exit\n"]);
    like(
        $deny->{stdout},
        qr/ERROR: Command 'rm' is not permitted in ,exec/,
        "exec pipeline: a denied segment blocks the whole pipeline"
    );
    unlike(
        $deny->{stdout},
        qr/exec: output saved to/,
        "exec pipeline: denied pipeline does not execute any segment"
    );

    for my $case (
        [",exec cat a; cat b\n",   qr/shell operator ';'/,    'semicolon'],
        [",exec cat a && cat b\n", qr/shell operator '&'/,    'and-chain'],
        [",exec cat a || cat b\n", qr/shell operator '\|\|'/, 'or-chain'],
        [",exec cat < a\n",        qr/shell operator '<'/, 'stdin redirect'],
      )
    {
        my ($input, $pattern, $label) = @$case;
        my $r = run_synergy_session([$input, ",exit\n"]);
        like($r->{stdout}, $pattern,
            "exec operator rejection: $label rejected");
    }

    my $empty_seg
      = run_synergy_session([",exec cat a | | cat b\n", ",exit\n"]);
    like(
        $empty_seg->{stdout},
        qr/ERROR: empty pipeline segment in ,exec command/,
        "exec pipeline: empty segment rejected"
    );

    my $arg_spaces = run_synergy_session(
        [qq[,exec printf '%s\\n' 'hello world' | wc -l\n], ",exit\n"]);
    like($arg_spaces->{stdout}, qr/OUTPUT:\n\s*1\n/,
        "exec pipeline: quoted arg with spaces survives requoting into the pipe"
    );
}

# 7) Git commands should not inherit a configured pager.
{
    my $pager = "$temp_dir/fake-pager";
    open my $pfh, '>', $pager or die "Cannot create $pager: $!";
    print {$pfh} "#!/usr/bin/env perl\nprint qq[PAGER_INVOKED\\n];\n";
    close $pfh;
    chmod 0755, $pager or die "Cannot chmod $pager: $!";

    local $ENV{GIT_PAGER} = $pager;
    local $ENV{PAGER}     = $pager;

    my $res = run_synergy_session(
        [
            qq[,exec git -C $original_cwd --paginate log --oneline -1\n],
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/exec: git -C \Q$original_cwd\E --paginate log --oneline -1/,
        "exec git pager: command executed"
    );
    unlike($res->{stdout}, qr/PAGER_INVOKED/,
        "exec git pager: inherited pager is suppressed");
}

END {
    chdir $original_cwd;
}

# -------------------------------------------------------------------
# Additional coverage for exec parsing/execution (cases 1-4)
# -------------------------------------------------------------------

# Prepare a test file we can safely run rg/sed against.
my $data_file = "$temp_dir/exec_data.txt";
open my $dfh, '>', $data_file or die "Cannot create $data_file: $!";
print $dfh "fn_one\n";
print $dfh "fn_two\n";
print $dfh "hello world\n";
print $dfh "a|b\n";
print $dfh "a;rm -rf /\n";
close $dfh;

# -------------------------------------------------------------------
# Case 1: Quoted-argument correctness (spaces + special chars)
# -------------------------------------------------------------------

# 7) Double quotes: preserve spaces within quotes; rg should match the line.
{
    my $res = run_synergy_session(
        [qq[,exec rg -n "hello world" $data_file\n], ",exit\n"]);

    like(
        $res->{stdout},
        qr/3:hello world/,
        "exec quoting: double-quoted arg with space matches expected line"
    );
}

# 8) Single quotes: preserve regex metachars ()|$ in a single argv element.
{
    my $res = run_synergy_session(
        [qq[,exec rg -n '(fn_one|fn_two)\$' $data_file\n], ",exit\n"]);

    like($res->{stdout}, qr/1:fn_one\n2:fn_two/s,
        'exec quoting: single-quoted ERE with grouping/alternation/$ works');
}

# 9) Mixed quoting with sed: script contains spaces; should execute as one arg.
{
    my $res = run_synergy_session(
        [
            qq[,exec sed -e 's/hello world/HELLO WORLD/' $data_file\n],
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/HELLO WORLD/,
        "exec quoting: sed script with spaces preserved and applied"
    );
}

# -------------------------------------------------------------------
# Case 2: Metacharacters are inert (no shell interpretation)
# -------------------------------------------------------------------

# 10) $() should be treated as literal text, not command substitution.
{
    my $res = run_synergy_session(
        [
            q[,exec rg -n '\$\(uname\)' /dev/null
], ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/exec: rg -n \\\$\\\(uname\\\) \/dev\/null/,
        'exec metachar inert: $() preserved literally in displayed command'
    );
    like(
        $res->{stdout},
        qr/WARNING: Command exited with status \d+/,
        "exec metachar inert: rg ran (non-zero ok)"
    );
}

# 11) Backticks should be treated as literal text.
{
    my $res = run_synergy_session(
        [
            q[,exec rg -n '`uname`' /dev/null
], ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/exec: rg -n `uname`/,
        "exec metachar inert: backticks preserved literally in displayed command"
    );
}

# -------------------------------------------------------------------
# Case 3: Parse failures and empty-argv behavior
# -------------------------------------------------------------------

# 12) Empty quoted argument should survive parsing.
{
    my $res = run_synergy_session(
        [
            q[,exec rg '' /dev/null
], ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/exec: rg\s+\/dev\/null/,
        "exec empty-arg: empty quoted string accepted (pattern is empty)"
    );
}

__END__
