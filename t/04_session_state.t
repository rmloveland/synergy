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

=head3 Test ,comment command (basic functionality)

=cut

{
    my $results
      = run_synergy_session([",comment This is a test comment\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/This is a test comment/,
        "comment: displays the comment text"
    );
    is($results->{exit_code}, 0, "comment: exits cleanly");
}

=head3 Test ,comment command (empty comment)

=cut

{
    my $results = run_synergy_session([",comment\n", ",exit\n"]);
    unlike($results->{stdout}, qr/ERROR/,
        "comment: handles empty comment without error");
    is($results->{exit_code}, 0, "comment: empty comment exits cleanly");
}

=head3 Test ,comment command (multiline content)

=cut

{
    my $results = run_synergy_session(
        [
            ",comment This is line one\n",
            ",comment This is line two\n",
            ",comment This is line three\n",
            ",exit\n"
        ]
    );
    like(
        $results->{stdout},
        qr/This is line one/,
        "comment: first comment line displayed"
    );
    like(
        $results->{stdout},
        qr/This is line two/,
        "comment: second comment line displayed"
    );
    like(
        $results->{stdout},
        qr/This is line three/,
        "comment: third comment line displayed"
    );
}

=head3 Test ,comment command (special characters)

=cut

{
    my $special_comment = "Special chars: !@#\$%^&*()_+-={}[]|\\:;\"'<>?,./";
    my $results
      = run_synergy_session([",comment $special_comment\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/\QSpecial chars\E/,
        "comment: strips out special characters correctly"
    );
}

=head3 Test ,comment command (does not affect context stack)

=cut

{
    # Create a test file
    my $test_file = "$temp_dir/comment_context_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "Test file content\n";
    close $fh;

    my $results = run_synergy_session(
        [
            ",push $test_file\n",
            ",s\n", ",comment This comment should not affect the stack\n",
            ",s\n", ",exit\n"
        ]
    );

    # Count occurrences of the test file in stack listings
    my @stack_listings = $results->{stdout} =~ /file: '\Q$test_file\E'/g;
    is(scalar(@stack_listings), 2,
        "comment: context stack unchanged after comment (file appears twice in two ,s commands)"
    );
    like(
        $results->{stdout},
        qr/This comment should not affect the stack/,
        "comment: comment text is displayed"
    );
}

=head3 Test ,comment command (integration with other commands)

=cut

{
    my $results = run_synergy_session(
        [
            ",comment Starting test sequence\n",      ",pwd\n",
            ",comment Current directory confirmed\n", ",model\n",
            ",comment Model information retrieved\n", ",exit\n"
        ]
    );

    like(
        $results->{stdout},
        qr/Starting test sequence/,
        "comment: first comment displayed"
    );
    like(
        $results->{stdout},
        qr/pwd: \Q$original_cwd\E/,
        "comment: pwd command works after comment"
    );
    like(
        $results->{stdout},
        qr/Current directory confirmed/,
        "comment: second comment displayed"
    );
    like($results->{stdout}, qr/Model: /,
        "comment: model command works after comment");
    like(
        $results->{stdout},
        qr/Model information retrieved/,
        "comment: third comment displayed"
    );
}

=head3 Test ,comment command (with leading/trailing whitespace)

=cut

{
    my $results = run_synergy_session(
        [",comment    Leading and trailing spaces    \n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Leading and trailing spaces/,
        "comment: preserves content with whitespace"
    );
}

=head3 Test empty/blank user input

=cut

# Test empty input
{
    my $results = run_synergy_session(["\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/WARNING: Ignoring empty assistant query\n/,
        "empty input: displays warning"
    );
    like($results->{stdout}, qr/Goodbye!\n/,
        "empty input: processes subsequent command after warning");
    is($results->{exit_code}, 0, "empty input: exits cleanly");
}

# Test blank input
{
    my $results = run_synergy_session(["   \t \n", ",exit\n"])
      ;    # blank line with spaces and tab
    like(
        $results->{stdout},
        qr/WARNING: Ignoring empty assistant query\n/,
        "blank input: displays warning"
    );
    like($results->{stdout}, qr/Goodbye!\n/,
        "blank input: processes subsequent command after warning");
    is($results->{exit_code}, 0, "blank input: exits cleanly");
}

=head3 Autodump default filename behavior

Key constraints:
- NEVER delete or unlink anything already existing in $SYNERGY_ROOT/etc/dumps (git "sacred" history).
- Do not assert on "how many files exist" in that directory.
- Instead, capture the exact dump filename SYNERGY reports, and only assert properties
  about that file (path, basename format, and that it exists).
- Then, during cleanup, delete only the files we just created

These tests only *create new dump files* via `,dump` and then `stat`
those exact paths, and then delete only those files.

=cut

{
    my $dump_dir = "$ENV{SYNERGY_DUMP_DIR}";

    # If dumps dir doesn't exist, these tests should not try to create it,
    # because that would also affect a "sacred" checkout.
    unless (-d $dump_dir) {
        skip
          "No $dump_dir directory present; skipping autodump filename tests",
          5;
    }

    my $res = run_synergy_session([",dump\n", ",exit\n"]);

    # 1) Capture the filename used by ,dump with no filename
    my ($reported_path)
      = ($res->{stdout} =~ /WARNING: No filename provided, using '([^']+)'/);

    ok(defined $reported_path,
        "dump(no filename): captures reported filename")
      or diag($res->{stdout});

    # 2) It should land under $SYNERGY_ROOT/etc/dumps (since dir exists)
    like(
        $reported_path,
        qr/^\Q$dump_dir\E\/dump-[0-9A-Fa-f\-]{36}-\d+(?:\.\d+)?\.xml\z/,
        "dump(no filename): path is under dumps dir and includes timestamp"
    );

    # 3) It should also be referenced by the success message
    like(
        $res->{stdout},
        qr/\QDumped conversation to '$reported_path'.\E/,
        "dump(no filename): success line references the same file path '$reported_path'"
    );

    # 4) That file should exist
    ok(-f $reported_path,
        "dump(no filename): reported file '$reported_path' exists on disk");

    # 5) Sanity: timestamp portion is numeric (int or hi-res float)
    my ($basename) = ($reported_path =~ m{/([^/]+)\z});
    my ($sid, $ts)
      = ($basename =~ /\Adump-([0-9A-Fa-f\-]{36})-(\d+(?:\.\d+)?)\.xml\z/);
    ok(defined $sid && defined $ts,
        "dump(no filename): basename parses as dump-<UUID>-<TS>.xml");

    unlink($reported_path) or die qq[Could not unlink $reported_path: $!\n];
}

=head3 Autodump after assistant reply uses canonical dump filename format

This covers the initial rolling autodump path, which is distinct from
`,dump` with no filename. A normal assistant turn under forced autodump
should create a dump file immediately, and that first file should
already match `dump-<UUID>-<TS>.xml`.

=cut

{
    my $dump_dir = "$ENV{SYNERGY_DUMP_DIR}";
    local $ENV{SYNERGY_FORCE_AUTODUMP} = 1;

    unless (-d $dump_dir) {
        skip
          "No $dump_dir directory present; skipping assistant autodump filename tests",
          8;
    }

    my $res = run_synergy_session(["hello autodump\n", ",exit\n"]);

    my @dump_paths
      = ($res->{stdout} =~ /Dumped conversation to '([^']+)'\./g);

    is(scalar(@dump_paths), 2,
        "autodump after assistant reply: exactly two dumps reported")
      or diag($res->{stdout});

    my ($p1, $p2) = @dump_paths;

    ok(defined $p1 && defined $p2,
        "autodump after assistant reply: captured both dump paths");

    my $uuid_re
      = qr/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/;
    my $ts_re = qr/\d+(?:\.\d+)?/;

    like($p1, qr/^\Q$dump_dir\E\//,
        "autodump after assistant reply: first dump is under dumps dir");
    like($p1, qr/\/dump-$uuid_re-$ts_re\.xml\z/,
        "autodump after assistant reply: first dump matches dump-<UUID>-<TS>.xml"
    );
    ok(-f $p1,
        "autodump after assistant reply: first reported dump file exists");
    ok(-f $p2,
        "autodump after assistant reply: second reported dump file exists");

    my $dump_xml = slurp($p1);
    my ($dump_session_id)
      = ($dump_xml =~ /<dump time="[^"]+" session="([^"]+)"/);
    ok(
        defined $dump_session_id,
        "autodump after assistant reply: first dump file records a session id"
    );
    like($p1, qr/\/dump-\Q$dump_session_id\E-$ts_re\.xml\z/,
        "autodump after assistant reply: first dump basename uses the dump session id"
    );

    unlink($p1) or die qq[Could not unlink $p1: $!\n];
    unlink($p2) or die qq[Could not unlink $p2: $!\n];
}

=head3 Autodump rotation behavior: if forced, exit triggers a second dump whose name differs

This test ONLY asserts on the two filenames that SYNERGY itself prints, and checks that:

- both are under the dumps dir
- both exist
- filenames are different (rotation happened)

NOTE: In your current synergy, autodump is disabled under piped-STDIN
(`-p STDIN`), so this can only run because we override an env var
(e.g. SYNERGY_FORCE_AUTODUMP=1) that SYNERGY has logic to check for
just for testing.

=cut

{
    my $dump_dir = "$ENV{SYNERGY_DUMP_DIR}";
    $ENV{SYNERGY_FORCE_AUTODUMP} = 1;
    unless (-d $dump_dir) {
        skip
          "No $dump_dir directory present; skipping autodump rotation tests",
          7;
    }

    my $res = run_synergy_session([",dump\n", ",exit\n"]);

    # Extract all dump paths SYNERGY reports in this session
    my @dump_paths
      = ($res->{stdout} =~ /Dumped conversation to '([^']+)'\./g);

    # We expect:
    # - first dump: explicit ,dump with autogenerated dump-<UUID>-<TS>.xml
    # - second dump: exit handler dumps to $active_dump_file (the "next" file)
    #
    # If your implementation prints more/less, we fail with diag.
    is(scalar(@dump_paths), 2,
        "autodump forced: exactly two dumps reported (initial + exit dump)")
      or diag($res->{stdout});

    my ($p1, $p2) = @dump_paths;

    ok(defined $p1 && defined $p2,
        "autodump forced: captured both dump paths");

    isnt($p1, $p2,
        "autodump forced: second dump path differs from first (rotation happened)"
    );

    like($p1, qr/^\Q$dump_dir\E\//,
        "autodump forced: first dump is under dumps dir");
    like($p2, qr/^\Q$dump_dir\E\//,
        "autodump forced: second dump is under dumps dir");

    ok(-f $p1, "autodump forced: first reported dump file '$p1' exists");
    ok(-f $p2, "autodump forced: second reported dump file '$p2' exists");

    my $uuid_re
      = qr/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/;
    my $ts_re = qr/\d+(?:\.\d+)?/;

    like(
        $p1,
        qr/\/dump-$uuid_re-$ts_re\.xml\z/,
        "autodump forced: first dump matches dump-<UUID>-<TS>.xml"
    );

   # If you kept the legacy prefix for the rotated dump too, use this instead:
    like(
        $p2,
        qr/\/dump-$uuid_re-$ts_re\.xml\z/,
        "autodump forced: rotated dump matches dump-<UUID>-<TS>.xml"
    );

    unlink($p1) or die qq[Could not unlink $p1: $!\n];
    unlink($p2) or die qq[Could not unlink $p2: $!\n];
}

=head3 Test ,reset <N> command

=cut

{
    my $test_file_1 = "$temp_dir_simple/dump_file_1.txt";

    my $session_results = run_synergy_session(
        [
            ",push $test_file_1\n",
            ",comment A\n", ",comment B\n", ",comment C\n", ",reset 2\n",
            ",history\n",   ",s\n",         ",reset\n",     ",s\n",
        ],
        $SYNERGY_SCRIPT
    );

    like(
        $session_results->{stdout},
        qr/reset: truncated chat history to \[0\.\.2\]; preserved file context/,
        ",reset 2 reports expected behavior"
    );

    like(
        $session_results->{stdout},
        qr/\[2\]: comment: B/,
        ",reset 2 retains expected history item at position 2"
    );

    unlike(
        $session_results->{stdout},
        qr/\[3\]: comment: C/,
        ",reset 2 discards previous history item at position 3"
    );

    like(
        $session_results->{stdout},
        qr/file: '\/tmp\/dump_file_1.txt': contents:/,
        ",reset 2 does not affect file context stack"
    );
    like(
        $session_results->{stdout},
        qr/reset: cleared chat history and file context/,
        ",reset reports clear history and file context"
    );
    like($session_results->{stdout},
        qr/\[ \]/, ",reset - confirm file context stack is cleared");
}

=head3 Test dump records the model and load switches back to it

=cut

{
    my $dump_file = "$temp_dir/model_roundtrip_dump.xml";

    my $dump_results = run_synergy_session(
        [",model claude-haiku\n", ",dump $dump_file\n", ",exit\n"]);
    is($dump_results->{exit_code}, 0, "model roundtrip: dump run exits ok");

    my $dump_xml = slurp($dump_file);
    like(
        $dump_xml,
        qr/<dump [^>]*model="claude-haiku"/,
        "model roundtrip: dump stores the active model short name"
    );

    # Fresh session starts on the default model; loading should switch.
    my $load_results
      = run_synergy_session([",load $dump_file\n", ",model\n", ",exit\n"]);
    like(
        $load_results->{stdout},
        qr/Loading model\s+\.\.\. ok/,
        "model roundtrip: load reports the stored model"
    );
    like(
        $load_results->{stdout},
        qr/Switched model to 'claude-haiku'/,
        "model roundtrip: load switches to the dumped model"
    );
    like(
        $load_results->{stdout},
        qr/^\s+\* claude-haiku /m,
        "model roundtrip: ,model shows the dumped model as current"
    );
}

=head3 Test loading an old dump without a model attribute

=cut

{
    my $legacy_file = "$temp_dir/legacy_no_model_dump.xml";
    open my $lfh, '>', $legacy_file or die "Cannot create $legacy_file: $!";
    print $lfh
      qq[<dump time="0" session="LEGACY-SESSION">\n  <convo>\n  </convo>\n  <context>\n  </context>\n</dump>\n];
    close $lfh;

    my $results
      = run_synergy_session([",load $legacy_file\n", ",model\n", ",exit\n"]);
    is($results->{exit_code}, 0, "legacy dump: load run exits ok");
    unlike(
        $results->{stdout},
        qr/Switched model to|unknown model/,
        "legacy dump: no model switch and no warning"
    );
    like(
        $results->{stdout},
        qr/^\s+\* gpt-5 /m,
        "legacy dump: default model stays current"
    );
}

=head3 Test dump/load round-trips UTF-8 as characters

Dumps are base64 over UTF-8 bytes; loading must decode back to
characters, not leave byte strings in the history (which would be
double-encoded on display and in later requests).

=cut

{
    my $dump_file = "$temp_dir/utf8_roundtrip_$$.xml";

    # STDIN is :utf8 via utf8::all, so these UTF-8 bytes arrive as
    # the characters: unicode note "curly" (curly quotes) plus a
    # bullet.
    my $session1 = run_synergy_session(
        [
            ",comment unicode note \xe2\x80\x9ccurly\xe2\x80\x9d \xe2\x97\x8f here\n",
            ",dump $dump_file\n",
            ",exit\n"
        ]
    );
    is($session1->{exit_code},
        0, "utf8 roundtrip: dump session exits cleanly");
    ok(-f $dump_file, "utf8 roundtrip: dump file written");

    my $session2
      = run_synergy_session([",load $dump_file\n", ",history\n", ",exit\n"]);

    is($session2->{exit_code},
        0, "utf8 roundtrip: load session exits cleanly");
    like(
        $session2->{stdout},
        qr/unicode note \xe2\x80\x9ccurly\xe2\x80\x9d \xe2\x97\x8f here/,
        "utf8 roundtrip: history shows single-encoded UTF-8 after load"
    );
    unlike($session2->{stdout}, qr/\xc3\xa2\xc2/,
        "utf8 roundtrip: no double-encoding fingerprint after load");
}

done_testing();

END {
    chdir $original_cwd;
}
