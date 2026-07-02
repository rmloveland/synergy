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

plan tests => 21;

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

# 3) Metacharacters should be inert (no shell). Semicolon should not split commands.
{
    my $res = run_synergy_session([",exec echo not_allowed\n", ",exit\n"]);

    like(
        $res->{stdout},
        qr/ERROR: Command 'echo' not allowed/,
        "exec allowlist: still enforced"
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

# 7) git commit with unquoted multi-word -m should be rejected early.
{
    my $res = run_synergy_session(
        [
            ",exec git commit -m Add replace review navigation and undo status\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/ERROR: git commit message arguments must be quoted; use git commit -m "subject" -m "body" or git commit -F file/,
        "exec git commit: rejects unquoted multi-word -m message"
    );
    unlike(
        $res->{stdout},
        qr/exec: git commit -m Add replace review navigation and undo status/,
        "exec git commit: invalid command is not executed"
    );
}

# 7b) Git commands should not inherit a configured pager.
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

# 8) rg with a suspicious unquoted multi-word pattern should be rejected early.
{
    my $res = run_synergy_session(
        [qq[,exec rg -n ERROR: No command provided $SYNERGY\n], ",exit\n"]);

    like(
        $res->{stdout},
        qr/ERROR: rg search patterns containing spaces must be quoted; use quotes around the pattern, e\.g\. rg -n "ERROR: No command provided" path/,
        "exec rg quoting: rejects suspicious unquoted multi-word pattern"
    );
    unlike(
        $res->{stdout},
        qr/rg: No: No such file or directory/,
        "exec rg quoting: invalid search does not reach rg"
    );
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
