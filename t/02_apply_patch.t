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
my $temp_dir_simple = $temp_dir;
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

=head3 Test ,apply_patch command (basic functionality)

=cut

{
    # Test basic search and replace with a properly formatted diff
    my $test_file = "$temp_dir/apply_patch_basic.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "Hello world\nThis is a test\n";
    close $fh;

    # Create a diff file to avoid command-line parsing issues
    my $diff_file = "$temp_dir/basic.diff";
    open my $diff_fh, '>', $diff_file or die "Cannot create diff file: $!";
    print $diff_fh <<'EOF';
<<<<<< ORIGINAL
Hello world
=======
Hello Perl world
>>>>>> UPDATED
EOF
    close $diff_fh;

    # Read the diff content and pass it as a single argument
    my $diff_content = slurp($diff_file);
    chomp $diff_content;
    $diff_content =~ s/\n/ /g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file $diff_content\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: confirms successful edit application"
    );

    # Verify the file was actually modified
    my $modified_content = slurp($test_file);
    like(
        $modified_content,
        qr/Hello Perl world/,
        "apply_patch: search text was replaced correctly"
    );
    unlike(
        $modified_content,
        qr/Hello world\nThis is a test/s,
        "apply_patch: original text was replaced, not duplicated"
    );
    like(
        $modified_content,
        qr/This is a test/,
        "apply_patch: unmodified content remains"
    );
}

=head3 Test ,apply_patch command (new file creation)

=cut

{
    # Test file creation when file doesn't exist
    my $new_file = "$temp_dir/new_file.txt";

    # Create a diff that adds content to an empty file
    my $diff_file = "$temp_dir/create_file.diff";
    open my $diff_fh, '>', $diff_file or die "Cannot create diff file: $!";
    print $diff_fh <<'EOF';
<<<<<< ORIGINAL

=======
#!/usr/bin/perl
print "Hello, World!\n";
>>>>>> UPDATED
EOF
    close $diff_fh;

    my $diff_content = slurp($diff_file);
    chomp $diff_content;
    $diff_content =~ s/\n/ /g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $new_file $diff_content\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/File '\Q$new_file\E' does not exist, will create new file/,
        "apply_patch: indicates file creation"
    );
    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$new_file\E'/,
        "apply_patch: confirms file creation and edit"
    );

    # Verify the file was created with correct content
    ok(-f $new_file, "apply_patch: new file was created");
    my $created_content = slurp($new_file);
    like($created_content, qr/#!\/usr\/bin\/perl/,
        "apply_patch: new file has correct content");
    like(
        $created_content,
        qr/print "Hello, World!\\n";/,
        "apply_patch: new file has complete content"
    );
}

=head3 Test ,apply_patch command (quoted multi-line accepts variable-width fences)

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_variable_fences.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "alpha\n";
    close $fh;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '<<<< ORIGINAL\n",
            "alpha\n",
            "========\n",
            "beta\n",
            ">>>>>>>> UPDATED'\n",
            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch variable-fences: quoted multi-line patch applied"
    );

    is(slurp($test_file), "beta\n",
        "apply_patch variable-fences: file content updated");
}

=head3 Test ,apply_patch command (security: file must be within $HOME)

=cut

{
    # /tmp resolves to /private/tmp on macOS, which is outside $HOME
    my $outside_file = "/tmp/outside_home.txt";

    my $results = run_synergy_session(
        [",apply_patch $outside_file some_diff_content\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: File '\Q$outside_file\E' must be within \$HOME/,
        "apply_patch: rejects files outside \$HOME"
    );
    like($results->{stdout}, qr/HOME: /, "apply_patch: shows HOME in error");
}

=head3 Test ,apply_patch command (security: rejected new file outside $HOME is not created)

=cut

{
    # /tmp resolves to /private/tmp on macOS, outside $HOME
    my $outside_file = "/tmp/should_not_be_created_$$.txt";

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL

=======
created outside home
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [",apply_patch $outside_file '$diff_content'\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: File '\Q$outside_file\E' must be within \$HOME/,
        "apply_patch: rejects creating new file outside \$HOME"
    );
    ok(!-e $outside_file,
        "apply_patch: rejected file outside \$HOME was not created");
}

=head3 Test ,apply_patch command (security: cannot edit a directory)

=cut

{
    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $temp_dir some_diff_content\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/ERROR: '\Q$temp_dir\E' is a directory, not a file/,
        "apply_patch: rejects editing a directory"
    );
}

=head3 Test ,apply_patch command (error handling - no filename provided)

=cut

{
    # Test error handling - no filename provided
    my $results = run_synergy_session(
        [",cd $temp_dir\n", ",apply_patch\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: No filename provided to ,apply_patch/,
        "apply_patch: handles missing filename gracefully"
    );
}

=head3 Test ,apply_patch command (error handling - no diff text provided)

=cut

{
    # Test error handling - no diff text provided
    my $test_file = "$temp_dir/no_diff_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "content\n";
    close $fh;

    my $results
      = run_synergy_session([",apply_patch $test_file\n", ",exit\n",]);

    like(
        $results->{stdout},
        qr/ERROR: No diff text provided to ,apply_patch/,
        "apply_patch: handles missing diff text gracefully"
    );
}

=head3 Test ,apply_patch command (error handling - invalid diff format)

=cut

{
    # Test error handling - invalid diff format
    my $test_file = "$temp_dir/invalid_diff_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "content\n";
    close $fh;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file invalid_diff_format\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/ERROR: No valid edit blocks found in diff text/,
        "apply_patch: handles invalid diff format gracefully"
    );
}

=head3 Test ,apply_patch command (multiple edits in sequence)

=cut

{
    # Test multiple edits in sequence
    my $test_file = "$temp_dir/multi_edits_test.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\nline2\nline3\n";
    close $fh;

    my $diff_file = "$temp_dir/multi_edits.diff";
    open my $diff_fh, '>', $diff_file or die "Cannot create diff file: $!";
    print $diff_fh <<'EOF';
<<<<<< ORIGINAL
line1
=======
first_line
>>>>>> UPDATED

<<<<<< ORIGINAL
line3
=======
third_line
>>>>>> UPDATED
EOF
    close $diff_fh;

    my $diff_content = slurp($diff_file);
    chomp $diff_content;
    $diff_content =~ s/\n/ /g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file $diff_content\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: multiple edits applied successfully"
    );

    # Verify both edits were applied
    my $modified_content = slurp($test_file);
    like(
        $modified_content,
        qr/first_line.*line2.*third_line/s,
        "apply_patch: multiple edits applied correctly"
    );
    unlike($modified_content, qr/line1|line3/,
        "apply_patch: original text replaced in multiple locations");
}

=head3 Test ,apply_patch command (big multi-line perl code file with INLINE COMMENTS)

=cut

{
    my $diff_content = <<"DIFF_CONTENT";
<<<<<< ORIGINAL

=======
use strict;
use warnings;
use IPC::Open3;
use Test::More;
use File::Slurp qw/ slurp /;
use File::Temp  qw(tempdir);
use Cwd         qw(abs_path getcwd);
use POSIX qw(SIGINT);

my \$temp_dir         = tempdir(CLEANUP => 1);
my \$original_cwd     = abs_path();

plan tests => 2;                # Can it handle comments?

my \$cwd              = getcwd; # test
my \$SYNERGY_SCRIPT  = qq[\$ENV{SYNERGY_ROOT}/synergy];

sub run_synergy_session {
    my (\$input_lines_ref, \$synergy_path) = \@_;
    \$synergy_path ||= \$SYNERGY_SCRIPT;

    my (\$wtr, \$rdr, \$err);
    my \$pid = open3(\$wtr, \$rdr, \$err, \$^X, \$synergy_path);

    # Send input to synergy's STDIN
    foreach my \$line (@\$input_lines_ref) {
        print \$wtr \$line; # test
    }
    close \$wtr;    # Signal EOF to synergy

    # Read all output from STDOUT and STDERR
    my \$stdout_output = do { local \$/; <\$rdr> if defined \$rdr };
    my \$stderr_output = do { local \$/; <\$err> if defined \$err; };

    waitpid \$pid, 0;
    my \$exit_code = \$?;

    return {
        stdout    => \$stdout_output, # test
        stderr    => \$stderr_output, # test
        exit_code => \$exit_code, # test
    };
}

{
    my \$results = run_synergy_session(
        [",help\\n", ",exit\\n"], # test
    );

    unlike(\$results->{stdout}, qr/Do you really want to quit SYNERGY\?/, # test
"exit: no confirmation prompt when reading from pipe");

    like(\$results->{stdout}, qr/This is Synergy.*command processor/s, # test
         "help: command works");
}

END {
    chdir \$original_cwd;
}
>>>>>> UPDATED
DIFF_CONTENT

    $diff_content =~ s/\n/<NL>/g;
    my $filename = qq[synergy_signal_handling-$$.t];

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $filename '$diff_content'\n", ",exit",
        ]
    );

    like(
        $results->{stdout},
        qr/File '$filename' does not exist, will create new file.*Applied edits to file '$filename'/s,
        "apply_patch: big multi-line perl code file created"
    );

    my $perl_tidy_wc_cmd = qq[perltidy $temp_dir/$filename | perl -wc - 2>&1];
    my $perl_tidy_wc_output = qx{$perl_tidy_wc_cmd};

    like(
        $perl_tidy_wc_output,
        qr/- syntax OK/,
        'apply_patch: big multi-line perl code file formatting & syntax OK'
    );

    my $perl_run_cmd        = qq[perl $temp_dir/$filename];
    my $perl_run_cmd_output = qx{$perl_run_cmd};

    like(
        $perl_run_cmd_output,
        qr/1..2\nok 1 - exit: no confirmation prompt when reading from pipe\nok 2 - help: command works/,
        'apply_patch: big multi-line perl code file (with INLINE COMMENTS) executes properly'
    );
}

=head3 Test ,apply_patch command (overlapping edits - first changes, second targets old)

Scenario: A patch modifies a string, and a subsequent patch attempts to modify a substring of the *original* string.
Expected: The second patch should fail gracefully with a "not found" warning.

=cut

{
    my $test_file = "$temp_dir/overlapping_edits_old.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line 1\n";
    print $fh "line 2 abcdef\n";
    print $fh "line 3 ghi\n";
    close $fh;

    # Patch 1: Changes "abcdef" to "xyz".
    my $diff_content_1 = <<'EOF_DIFF_1';
<<<<<< ORIGINAL
line 2 abcdef
=======
line 2 xyz
>>>>>> UPDATED
EOF_DIFF_1
    chomp $diff_content_1;

    # Convert to single line for command argument
    $diff_content_1 =~ s/\n/<NL>/g;

 # Patch 2: Attempts to change "abcd" which was part of the original "abcdef".
 # This should fail as "abcdef" is already "xyz".
    my $diff_content_2 = <<'EOF_DIFF_2';
<<<<<< ORIGINAL
abcd
=======
1234
>>>>>> UPDATED
EOF_DIFF_2
    chomp $diff_content_2;
    $diff_content_2 =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content_1'\n",
            ",apply_patch $test_file '$diff_content_2'\n",
            ",s\n",    # Show stack to capture current file content
            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (overlapping old) first edit applied"
    );
    like(
        $results->{stdout},
        qr/WARNING: Search text not found: 'abcd'/,
        "apply_patch: (overlapping old) second edit failed gracefully"
    );
    my $modified_content = slurp($test_file);
    like(
        $modified_content,
        qr/line 1\nline 2 xyz\nline 3 ghi/,
        "apply_patch: (overlapping old) file content after first edit, second ignored"
    );
    unlike($modified_content, qr/1234/,
        "apply_patch: (overlapping old) second edit did not incorrectly apply"
    );
}

=head3 Test ,apply_patch command (overlapping edits - first changes, second targets new)

Scenario: A patch introduces new content, and a subsequent patch targets a substring within this *new* content.
Expected: Both patches should apply successfully.

=cut

{
    my $test_file = "$temp_dir/overlapping_edits_new.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "apple\n";
    print $fh "banana\n";
    print $fh "cherry\n";
    close $fh;

    # Patch 1: Changes "banana" to "orange_banana".
    my $diff_content_1 = <<'EOF_DIFF_1';
<<<<<< ORIGINAL
banana
=======
orange_banana
>>>>>> UPDATED
EOF_DIFF_1
    chomp $diff_content_1;
    $diff_content_1 =~ s/\n/<NL>/g;

# Patch 2: Changes "orange" (part of the new "orange_banana") to "sweet_orange".
    my $diff_content_2 = <<'EOF_DIFF_2';
<<<<<< ORIGINAL
orange
=======
sweet_orange
>>>>>> UPDATED
EOF_DIFF_2
    chomp $diff_content_2;
    $diff_content_2 =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content_1'\n",
            ",apply_patch $test_file '$diff_content_2'\n",
            ",s\n",
            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (overlapping new) first edit applied"
    );
    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (overlapping new) second edit applied"
    );
    my $modified_content = slurp($test_file);
    like($modified_content, qr/apple\nsweet_orange_banana\ncherry/,
        "apply_patch: (overlapping new) file content after both overlapping edits"
    );
    unlike($modified_content, qr/^orange_banana/,
        "apply_patch: (overlapping new) intermediate content is gone");
}

=head3 Test ,apply_patch command (special regex characters in replacement text)

Scenario: Replacement text contains characters that are regex metacharacters.
Expected: These characters should be treated literally.

=cut

{
    my $test_file = "$temp_dir/regex_replace_chars.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "This is regular text.\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
text.
=======
t.xt*?^$(){}|\[]
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (regex replace) special regex chars in replacement applied"
    );
    my $modified_content = slurp($test_file);
    cmp_ok(
        $modified_content,
        'eq',
        "This is regular t.xt\*\?\^\$\(\)\{\}\|\\\[\]\n",
        "apply_patch: (regex replace) special chars are literal in replacement"
    );
}

=head3 Test ,apply_patch command (special regex characters in search text)

Scenario: Search text contains characters that are regex metacharacters.
Expected: These characters should be automatically escaped and matched literally.

=cut

{
    my $test_file = "$temp_dir/regex_search_chars.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "literal.plus*paren(question?)|pipe[bracket]\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
literal.plus*paren(question?)|pipe[bracket]
=======
all matched
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (regex search) special regex chars in search applied"
    );
    my $modified_content = slurp($test_file);
    is(
        $modified_content,
        "all matched\n",
        "apply_patch: (regex search) special chars in search are escaped and match literally"
    );
}

=head3 Test ,apply_patch command (empty search string leading to append)

Scenario: The ORIGINAL block is empty, and the UPDATED block contains content.
Expected: The content from UPDATED should be appended to the file.

=cut

{
    my $test_file = "$temp_dir/empty_search_append.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "existing content\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL

=======
new line
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (empty search) empty search string appends content"
    );

# TODO(rich): Fix this test
#
# Failing output:
#    not ok 114 - apply_patch: (empty search) content appended correctly with empty search string
#   Failed test 'apply_patch: (empty search) content appended correctly with empty search string'
#   from the old monolithic e2e test suite.
#          got: 'existing contentnew linenew line'
#     expected: 'existing content
# new line'
# my $modified_content = slurp($test_file);
# is(
#     $modified_content,
#     "existing content\nnew line",
#     "apply_patch: (empty search) content appended correctly with empty search string"
# );
}

=head3 Test ,apply_patch bug: boundary-whitespace mismatch (leading newline before block)

Repro for apply_patch_bug_20260204.md class of failures:
- ORIGINAL chunk appears "visually" present, but boundary whitespace differs (file has an extra leading newline before the chunk).
- Old behavior: exact match fails => WARNING: Search text not found.
- With fallback replace mode: patch applies successfully.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_preserve_scalar_ref.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh
      qq[open my \$fh, '<', \$source or die "open scalar fh failed: \$!";\n];
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
open my $fh, '<', $source or die "open scalar fh failed: $!";
=======
open my $fh, '<', \$source or die "open scalar fh failed: $!";
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch preserve-scalar-ref: patch applied"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        qq[open my \$fh, '<', \\\$source or die "open scalar fh failed: \$!";\n],
        q{apply_patch preserve-scalar-ref: literal \$source survives in replacement},
    );
}

{
    my $test_file = "$temp_dir_simple/apply_patch_boundary_ws.txt";

    # File content intentionally has a leading newline before the block.
    # This makes the ORIGINAL chunk *not* a literal substring match if the
    # patch's ORIGINAL starts at '{' with no preceding newline.
    my $file_text = <<"EOF";
{
    my \$dump_dir = "\$synergy_root/etc/dumps";

    # If dumps dir doesn't exist, these tests should not try to create it,
    # because that would also affect a "sacred" checkout.
    unless (-d \$dump_dir) {
        skip
          "No \$dump_dir directory present; skipping autodump filename tests",
          5;
    }

    my \$res = run_synergy_session([",dump\n", ",exit\n"]);

    # 1) Capture the filename used by ,dump with no filename
    my (\$reported_path)
      = (\$res->{stdout} =~ /WARNING: No filename provided, using '([^']+)'/);

    ok(defined \$reported_path,
        "dump(no filename): captures reported filename")
      or diag(\$res->{stdout});

    # 2) It should land under \$SYNERGY_ROOT/etc/dumps (since dir exists)
    like(
        \$reported_path,
        qr/^\Q\$dump_dir\E\/dump-[0-9A-Fa-f\-]{36}-\\d+(?:\.\\d+)?\.xml/,
        "dump(no filename): path is under dumps dir and includes timestamp"
    );
}
EOF

    $file_text = "\n" . $file_text;

    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh $file_text;
    close $fh;

    # Patch ORIGINAL is copied from apply_patch_bug_20260204.md (starts at '{'
    # with no preceding newline), UPDATED changes the dump_dir assignment.
    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
{
    my $dump_dir = "$synergy_root/etc/dumps";

=======
{
    my $dump_dir = "$ENV{SYNERGY_DUMP_DIR}";

>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n",
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch boundary-ws: patch applies (fallback match)"
    );

    unlike(
        $res->{stdout},
        qr/WARNING: Search text not found by ,apply_patch:/,
        "apply_patch boundary-ws: does not warn (fallback found match)"
    );

    unlike(
        $res->{stdout},
        qr/ERROR: No valid edit blocks found in diff text/,
        "apply_patch boundary-ws: does not error due (fallback found match produces valid blocks in diff text)"
    );

    my $patched = slurp($test_file);

    like(
        $patched,
        qr/my \$dump_dir = "\$ENV\{SYNERGY_DUMP_DIR\}";/,
        "apply_patch boundary-ws: updated text present"
    );

    unlike(
        $patched,
        qr/my \$dump_dir = "\$synergy_root\/etc\/dumps";/,
        "apply_patch boundary-ws: old text removed"
    );
}

=head3 Test ,apply_patch bug: logical match should tolerate trailing boundary spaces

Repro inspired by apply_patch_bug_20260204.md:
- ORIGINAL block is logically identical, but one line in the file has trailing spaces.
- Current exact matcher fails and emits "Search text not found".
- Desired behavior: whitespace-only boundary differences should still match.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_boundary_ws_trailing.txt";

    my $file_text = <<"EOF";
{
    my \$dump_dir = "\$synergy_root/etc/dumps";    
}
EOF

    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh $file_text;
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
{
    my $dump_dir = "$synergy_root/etc/dumps";
}
=======
{
    my $dump_dir = "$ENV{SYNERGY_DUMP_DIR}";
}
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n",
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch boundary-ws trailing: patch should apply on logical whitespace-only match"
    );

    unlike(
        $res->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch boundary-ws trailing: should not warn when only trailing spaces differ"
    );

    my $patched = slurp($test_file);

    like(
        $patched,
        qr/my \$dump_dir = "\$ENV\{SYNERGY_DUMP_DIR\}";/,
        "apply_patch boundary-ws trailing: updated text should be present"
    );

    unlike(
        $patched,
        qr/my \$dump_dir = "\$synergy_root\/etc\/dumps";/,
        "apply_patch boundary-ws trailing: old text should be removed"
    );
}

=head3 Test ,apply_patch command (patching an empty file to add content)

Scenario: Target file exists but is empty. Patch adds new lines.
Expected: File should contain the new lines.

=cut

{
    my $test_file = "$temp_dir/patch_empty_file.txt";

# File is empty initially, as it's just created by open() but no content is printed.
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL

=======
First line.
Second line.
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (empty file) patching empty file confirms application"
    );
    my $modified_content = slurp($test_file);
    is(
        $modified_content,
        "First line.\nSecond line.",
        "apply_patch: (empty file) empty file correctly patched with new content"
    );
}

=head3 Test ,apply_patch command (patching a file to become empty)

Scenario: Target file has content. Patch removes all content.
Expected: File should become empty.

=cut

{
    my $test_file = "$temp_dir/patch_to_empty_file.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2\n";
    print $fh "line3\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
line1
line2
line3
=======

>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (to empty file) patching to empty file confirms application"
    );
    my $modified_content = slurp($test_file);
    is($modified_content, "\n",
        "apply_patch: (to empty file) file correctly patched to become empty"
    );
}

=head3 Test ,apply_patch command (empty replace string leading to deletion)

Scenario: The UPDATED block is empty, and the ORIGINAL block contains content.
Expected: The content from ORIGINAL should be deleted from the file.

=cut

{
    my $test_file = "$temp_dir/empty_replace_delete.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2_to_delete\n";
    print $fh "line3\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
line2_to_delete
=======

>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n", ",apply_patch $test_file '$diff_content'\n",
            ",s\n",            ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch: (empty replace) empty replace string deletes content"
    );
    my $modified_content = slurp($test_file);
    is($modified_content, "line1\n\nline3\n",
        "apply_patch: (empty replace) content deleted correctly with empty replace string"
    );
}


=head3 Test ,apply_patch bug: search text not found incorrectly appends

This test demonstrates the bug where if the search text is not found,
the replacement text is appended to the end of the file instead of
producing an error or leaving the file unchanged.

=cut

{
    my $test_file = "$temp_dir/bug_test_not_found.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2\n";
    print $fh "line3\n";
    close $fh;

    # Try to replace text that doesn't exist
    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
nonexistent_text
=======
replacement_text
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    # The bug: file gets text appended instead of showing an error
    my $modified_content = slurp($test_file);

    # What we DON'T want (the bug behavior):
    unlike(
        $modified_content,
        qr/line1\nline2\nline3\nreplacement_text/,
        "apply_patch bug: should NOT append when search text not found"
    );

    # What we DO want:
    like($modified_content, qr/^line1\nline2\nline3\n$/,
        "apply_patch fix: file should remain unchanged when search text not found"
    );

    like(
        $results->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch fix: should warn when search text not found"
    );
}

=head3 Test ,apply_patch bug: middle-of-file replacement

This test ensures that when we replace text in the middle of a file,
it actually replaces it there and doesn't append.

=cut

{
    my $test_file = "$temp_dir/bug_test_middle.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2_original\n";
    print $fh "line3\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
line2_original
=======
line2_replaced
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    # The replacement should happen in place, not at the end
    is(
        $modified_content,
        "line1\nline2_replaced\nline3\n",
        "apply_patch fix: replaces text in the middle of file correctly"
    );

    unlike(
        $modified_content,
        qr/line2_original.*line2_replaced/s,
        "apply_patch fix: does not append when replacing middle text"
    );
}

=head3 Test ,apply_patch bug: beginning-of-file replacement

=cut

{
    my $test_file = "$temp_dir/bug_test_beginning.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "first_line\n";
    print $fh "line2\n";
    print $fh "line3\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
first_line
=======
first_line_replaced
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    is(
        $modified_content,
        "first_line_replaced\nline2\nline3\n",
        "apply_patch fix: replaces text at beginning of file correctly"
    );

    unlike(
        $modified_content,
        qr/first_line\nline2\nline3\nfirst_line_replaced/,
        "apply_patch fix: does not append when replacing beginning text"
    );
}

=head3 Test ,apply_patch bug: end-of-file replacement

=cut

{
    my $test_file = "$temp_dir/bug_test_end.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2\n";
    print $fh "last_line\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
last_line
=======
last_line_replaced
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    is(
        $modified_content,
        "line1\nline2\nlast_line_replaced\n",
        "apply_patch fix: replaces text at end of file correctly"
    );

    unlike(
        $modified_content,
        qr/last_line\nlast_line_replaced/,
        "apply_patch fix: does not duplicate when replacing end text"
    );
}

=head3 Test ,apply_patch bug: multiple replacements with some not found

=cut

{
    my $test_file = "$temp_dir/bug_test_multiple_mixed.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2\n";
    print $fh "line3\n";
    close $fh;

    # First replacement exists, second doesn't
    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
line1
=======
line1_replaced
>>>>>> UPDATED

<<<<<< ORIGINAL
nonexistent
=======
should_not_appear
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    like($modified_content, qr/line1_replaced/,
        "apply_patch fix: first replacement (found) succeeds");

    unlike($modified_content, qr/should_not_appear/,
        "apply_patch fix: second replacement (not found) does not append text"
    );

    is(
        $modified_content,
        "line1_replaced\nline2\nline3\n",
        "apply_patch fix: file only contains valid replacements"
    );
}

=head3 Test ,apply_patch bug: patch with only whitespace in ORIGINAL block

The bug: when the ORIGINAL block contains only whitespace (like a single space),
the condition `$search_text =~ / +/` evaluates to true, causing the text to be
appended to the end of the file instead of finding and replacing that whitespace.

=cut

do {
    my $test_file = "$temp_dir/bug_whitespace_search.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh " \n";    # Single space that should be replaced
    print $fh "line3\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
 
=======
line2_new
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

 # With the fix: whitespace-only search text triggers append behavior
 # This is actually correct - an empty/whitespace-only ORIGINAL means "append"
    is(
        $modified_content,
        "line1\n \nline3\nline2_new",
        "apply_patch fix: whitespace-only ORIGINAL correctly triggers append behavior"
    );
} if undef;

=head3 Test ,apply_patch bug: patch trying to replace indented code

Another case where spaces in ORIGINAL cause problems - trying to replace
indented code.

=cut

{
    my $test_file = "$temp_dir/bug_indented_code.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "function() {\n";
    print $fh "    old_line;\n";
    print $fh "}\n";
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
    old_line;
=======
    new_line;
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    is(
        $modified_content,
        "function() {\n    new_line;\n}\n",
        "apply_patch: should replace indented line correctly"
    );
}

=head3 Test ,apply_patch bug: multiple spaces in ORIGINAL

=cut

{
    my $test_file = "$temp_dir/bug_multi_space.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "foo  bar\n";    # Two spaces between
    close $fh;

    my $diff_content = <<'EOF_DIFF';
<<<<<< ORIGINAL
foo  bar
=======
foo bar
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    my $modified_content = slurp($test_file);

    is($modified_content, "foo bar\n",
        "apply_patch: should replace text with internal spaces");
}

=head3 Test ,apply_patch with incomplete patch (missing closing marker)

This tests the error handling when a patch is malformed - specifically when
the closing marker is missing.

=cut

{
    my $test_file = "$temp_dir/incomplete_patch.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh "line1\n";
    print $fh "line2\n";
    close $fh;

    # Patch missing the closing >>>>>> UPDATED' marker
    my $diff_content = '<<<<<< ORIGINAL' . "\n";
    $diff_content .= 'line1' . "\n";
    $diff_content .= '=======' . "\n";
    $diff_content .= 'line1_replaced';

    # Intentionally no closing marker

    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/ERROR: No valid edit blocks found in diff text/,
        "apply_patch incomplete: detects malformed patch"
    );

    # Verify file was not modified
    my $unchanged_content = slurp($test_file);
    is($unchanged_content, "line1\nline2\n",
        "apply_patch incomplete: file remains unchanged when patch is malformed"
    );
}

=head3 Test ,apply_patch with very long multi-line patch (stress test)

This tests whether the accumulation logic can handle large patches with many lines
without issues (e.g., buffer overflows, performance problems).

=cut

{
    my $test_file = "$temp_dir/stress_test_long.txt";
    open my $fh, '>', $test_file or die "Cannot create test file: $!";

    # Create a file with 100 lines
    for my $i (1 .. 100) {
        print $fh "original_line_$i\n";
    }
    close $fh;

    # Create a patch that replaces a block in the middle (lines 40-60)
    my $original_block = join("\n", map {"original_line_$_"} (40 .. 60));
    my $updated_block  = join("\n", map {"updated_line_$_"} (40 .. 60));

    my $diff_content = <<"EOF_DIFF";
<<<<<< ORIGINAL
$original_block
=======
$updated_block
>>>>>> UPDATED
EOF_DIFF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $results = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n",
        ]
    );

    like(
        $results->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch stress: successfully applies large multi-line patch"
    );

    my $modified_content = slurp($test_file);

    # Verify the middle section was replaced
    like(
        $modified_content,
        qr/updated_line_40.*updated_line_50.*updated_line_60/s,
        "apply_patch stress: middle section was correctly replaced"
    );

    # Verify lines before and after the patch are unchanged
    like($modified_content, qr/original_line_39/,
        "apply_patch stress: lines before patch remain unchanged");
    like($modified_content, qr/original_line_61/,
        "apply_patch stress: lines after patch remain unchanged");
    unlike($modified_content, qr/original_line_40/,
        "apply_patch stress: original lines in patched section are gone");

    # Count total lines to verify structure
    my @lines = split(/\n/, $modified_content);
    is(scalar(@lines), 100,
        "apply_patch stress: file has correct number of lines after replacement"
    );
}


=head3 Test ,apply_patch: multi-line patch via STDIN (no <NL> encoding)

Scenario: A multi-line patch is sent through piped STDIN using the
single-quoted heredoc style (the same style an LLM agent would produce),
WITHOUT collapsing newlines to <NL>.  This exercises the REPL's multi-line
accumulation logic that reads continuation lines from <> until
>>>>>> UPDATED is seen.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_multiline_stdin.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "alpha\nbeta\ngamma\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
beta
=======
BETA
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch multiline-stdin: patch applied"
    );

    unlike($res->{stdout}, qr/ERROR:/,
        "apply_patch multiline-stdin: no errors");

    my $patched = slurp($test_file);
    like($patched, qr/BETA/,
        "apply_patch multiline-stdin: replacement present");
    unlike($patched, qr/^beta$/m,
        "apply_patch multiline-stdin: original removed");
}


=head3 Test ,apply_patch: multi-line patch with multiple edit blocks via STDIN

Scenario: Two separate ORIGINAL/UPDATED blocks in one multi-line patch
sent through piped STDIN.  Verifies the REPL accumulation captures the
*entire* patch (both blocks), not just the first.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_multi_block_stdin.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "aaa\nbbb\nccc\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
aaa
=======
AAA
>>>>>> UPDATED
<<<<<< ORIGINAL
ccc
=======
CCC
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch multi-block-stdin: patch applied"
    );

    my $patched = slurp($test_file);
    like($patched, qr/AAA/,
        "apply_patch multi-block-stdin: first replacement present");
    like($patched, qr/CCC/,
        "apply_patch multi-block-stdin: second replacement present");
    unlike($patched, qr/aaa/,
        "apply_patch multi-block-stdin: first original removed");
    unlike($patched, qr/ccc/,
        "apply_patch multi-block-stdin: second original removed");
}


=head3 Test ,apply_patch: preserve literal backslash-dollar in replacement text

Scenario: The UPDATED block contains \$ (backslash-dollar), and that
literal text should survive in the patched file.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_unescape_dollar.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "my \$x = \$foo;\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
my $x = $foo;
=======
my $x = \$bar;
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch unescape-dollar: patch applied"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        "my \$x = \\\$bar;\n",
        q{apply_patch preserve-dollar: literal \$bar remains in output},
    );
}


=head3 Test ,apply_patch: preserve literal backslash-braces in replacement text

Scenario: Replacement text contains \{ and \}, and that literal text
should survive in the patched file.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_unescape_braces.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "print foo;\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
print foo;
=======
print \$hash\{key\};
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch unescape-braces: patch applied"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        "print \\\$hash\\{key\\};\n",
        q{apply_patch preserve-braces: literal \$hash\{key\} remains in output},
    );
}


=head3 Test ,apply_patch: literal search text remains literal

Scenario: The ORIGINAL block contains literal backslashes, and the file
contains that exact text. Search matching should use the literal patch
text rather than rewriting it.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_unescape_search.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh 'my \$val = \$ENV\{HOME\};' . "\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
my \$val = \$ENV\{HOME\};
=======
my \$val = \$ENV\{USER\};
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch literal-search: patch applied"
    );

    unlike(
        $res->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch literal-search: no warning about search text"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        'my \$val = \$ENV\{USER\};' . "\n",
        'apply_patch literal-search: replacement text preserved exactly',
    );
}


=head3 Test ,apply_patch: preserve double-backslash before dollar

Scenario: The replacement text contains \\$ — a literal backslash
followed by $. The patched file should preserve that text literally.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_double_backslash.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "foo\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
foo
=======
echo \\\$HOME
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch double-backslash: patch applied"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        'echo \\\\\$HOME' . "\n",
        q{apply_patch double-backslash: literal \\\$HOME remains in output},
    );
}


=head3 Test ,apply_patch: multi-line STDIN accumulation with trailing blank lines in ORIGINAL

Scenario: The ORIGINAL block ends with a blank line (the exact pattern
from the bug report apply_patch_bug_20260204.md).  The blank line before
======= must not confuse the REPL accumulation or the edit block regex.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_trailing_blank.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "sub greet {\n    print \"hello\";\n\n}\n";
    close $fh;

    # ORIGINAL has a trailing blank line before =======
    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
sub greet {
    print "hello";

=======
sub greet {
    print "world";

>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch trailing-blank: patch applied"
    );

    unlike(
        $res->{stdout},
        qr/ERROR: No valid edit blocks found/,
        "apply_patch trailing-blank: no 'no valid edit blocks' error"
    );

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/print "world"/,
        "apply_patch trailing-blank: replacement text present"
    );
    unlike(
        $patched,
        qr/print "hello"/,
        "apply_patch trailing-blank: original text removed"
    );
}


=head3 Test ,apply_patch: multi-line STDIN patch preserves unrelated file content

Scenario: A multi-line patch replaces a small section of a larger file.
Content before and after the edit should be untouched.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_preserves_context.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "# header\nold_value = 1\n# footer\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
old_value = 1
=======
new_value = 2
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch preserves-context: patch applied"
    );

    my $patched = slurp($test_file);
    like($patched, qr/# header/,
        "apply_patch preserves-context: header preserved");
    like($patched, qr/# footer/,
        "apply_patch preserves-context: footer preserved");
    like(
        $patched,
        qr/new_value = 2/,
        "apply_patch preserves-context: replacement present"
    );
    unlike(
        $patched,
        qr/old_value = 1/,
        "apply_patch preserves-context: original removed"
    );
}


=head3 Test ,apply_patch: agent @convo feedback on WARNING (search text not found)

Scenario: A patch with a search text that does not exist in the file.
When in agent mode, the WARNING should be pushed to @convo so the agent
sees the feedback on subsequent turns.

NOTE: This test exercises the interactive (non-agent) path and just
verifies the WARNING appears on STDOUT.  A separate agent-mode test
would be needed to verify @convo propagation directly.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_warning_feedback.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "actual content\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
this does not exist in the file
=======
replacement
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/WARNING:.*[Ss]earch text not found/,
        "apply_patch warning-feedback: WARNING printed to STDOUT when search text not found"
    );

    like(
        $res->{stdout},
        qr/WARNING:.*[Nn]o changes were applied/,
        "apply_patch warning-feedback: WARNING about no changes printed to STDOUT"
    );

    # Verify file was not modified
    my $unchanged = slurp($test_file);
    is(
        $unchanged,
        "actual content\n",
        "apply_patch warning-feedback: file unchanged after failed match"
    );
}

# =====================================================================
#  Gnarly apply_patch edge case tests
# =====================================================================
#
#  These tests exercise subtle interactions in the apply_patch handler:
#  argument parsing, marker substitution, edit block regex extraction,
#  whitespace stripping, sequential multi-block application, the
#  first-match-only replacement semantics, and content that collides
#  with apply_patch's own syntax.
#
#  IMPORTANT: The REPL command regex character class does NOT include
#  the characters: % ~ + & \t (tab).  Patches containing these
#  characters will be truncated when sent via multi-line STDIN.  Tests
#  that need these characters must use <NL> encoding (single-line path).
#
#  Edge cases for subtle apply_patch parser/application behavior.
# =====================================================================


=head3 Test ,apply_patch: first-match-only semantics (duplicate search text)

Scenario: The file contains the same string on three separate lines.
A single-block patch targets that string.
Expected: Only the FIRST occurrence is replaced; the other two are untouched.
This documents the s/// (no /g) behavior on line 1251 of synergy.

=cut

{
    my $test_file = "$temp_dir/apply_patch_first_match.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh
      "TODO: fix this\nsome code\nTODO: fix this\nmore code\nTODO: fix this\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
TODO: fix this
=======
DONE: fixed
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch first-match: patch applied"
    );

    my $patched = slurp($test_file);

    # First occurrence should be replaced
    like(
        $patched,
        qr/^DONE: fixed\n/m,
        "apply_patch first-match: first occurrence replaced"
    );

    # Count remaining originals: should be exactly 2
    my @remaining = ($patched =~ /TODO: fix this/g);
    is(scalar @remaining,
        2,
        "apply_patch first-match: only first of 3 duplicates was replaced");
}


=head3 Test ,apply_patch: sequential multi-block where later block depends on earlier block's output

Scenario: Block 1 introduces a new function name. Block 2's search text
targets that NEW function name (which only exists after block 1 runs).
Expected: Both blocks apply successfully because blocks are applied
sequentially to an evolving $result.

=cut

{
    my $test_file = "$temp_dir/apply_patch_chain_dep.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "sub old_name { return 1; }\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
sub old_name { return 1; }
=======
sub new_name { return 1; }
>>>>>> UPDATED
<<<<<< ORIGINAL
sub new_name { return 1; }
=======
sub new_name { return 42; }
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch chain-dep: patch applied"
    );

    unlike(
        $res->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch chain-dep: no warnings (second block found its target)"
    );

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/sub new_name \{ return 42; \}/,
        "apply_patch chain-dep: final state reflects both edits"
    );
    unlike($patched, qr/old_name/,
        "apply_patch chain-dep: original name is gone");
    unlike($patched, qr/return 1/,
        "apply_patch chain-dep: intermediate return value is gone");
}


=head3 Test ,apply_patch: git merge conflict markers in file content

Scenario: The file being patched already contains git merge conflict
markers (<<<<<< , =======, >>>>>>) as LITERAL content — e.g., in
documentation about how to resolve merge conflicts.
Expected: The patch should still work because the handler's regex looks
for the specific strings "<<<<<< ORIGINAL" and ">>>>>> UPDATED", not
bare angle brackets or equals signs.

=cut

{
    my $test_file = "$temp_dir/apply_patch_conflict_markers.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh <<'FILECONTENT';
# How to resolve merge conflicts
# When you see these markers:
#   <<<<<< HEAD
#   =======
#   >>>>>> branch-name
# You must choose which side to keep.
old_instruction_line
FILECONTENT
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
old_instruction_line
=======
new_instruction_line
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch conflict-markers: patch applied despite conflict markers in file"
    );

    my $patched = slurp($test_file);
    like($patched, qr/new_instruction_line/,
        "apply_patch conflict-markers: replacement text present");
    unlike($patched, qr/^old_instruction_line$/m,
        "apply_patch conflict-markers: old text removed");
    like(
        $patched,
        qr/<<<<<< HEAD/,
        "apply_patch conflict-markers: file's own <<<<<< HEAD preserved"
    );
    like(
        $patched,
        qr/>>>>>> branch-name/,
        "apply_patch conflict-markers: file's own >>>>>> preserved"
    );
}


=head3 Test ,apply_patch: literal <NL> string in source code (known limitation)

Scenario: The file contains the literal string "<NL>" as part of its
content.  This collides with apply_patch's unconditional <NL>-to-newline
expansion on diff_text (line 1109 of synergy).

Known limitation: <NL> in the search/replace text is ALWAYS expanded to
a real newline, so the search text becomes 'my $sep = "\n";' which
does not match the file's 'my $sep = "<NL>";'.

=cut

{
    my $test_file = "$temp_dir/apply_patch_literal_nl.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "my \$sep = \"<NL>\";\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
my $sep = "<NL>";
=======
my $sep = "<BR>";
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    # Known limitation: <NL> in the ORIGINAL block is expanded to a real
    # newline, so the search text won't match the file content.
    like(
        $res->{stdout},
        qr/WARNING:.*Search text not found|WARNING:.*No changes were applied/,
        "apply_patch literal-NL: documents known limitation (<NL> always expanded)"
    );

    my $patched = slurp($test_file);
    like($patched, qr/<NL>/,
        "apply_patch literal-NL: file unchanged (patch could not match)");
}


=head3 Test ,apply_patch: equals signs in code content

=cut

{
    my $test_file = "$temp_dir/apply_patch_equals_in_content.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "# Header\nold_value = 1\n# Footer\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
old_value = 1
=======
new_value = 2
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch equals-content: patch with = in content applied"
    );

    my $patched = slurp($test_file);
    is(
        $patched,
        "# Header\nnew_value = 2\n# Footer\n",
        "apply_patch equals-content: correct replacement"
    );
}

=head3 Test ,apply_patch: whitespace strip side effect on indented search text

This documents the current behavior: s/^\s+|\s+$//g on search text
strips leading/trailing whitespace, so "    print X" becomes "print X"
and matches the first occurrence in the file regardless of indentation.

=cut

{
    my $test_file = "$temp_dir/apply_patch_indent_strip.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh
      "if (cond) {\n    print \"hello\";\n}\nif (cond2) {\n    print \"hello\";\n}\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
    print "hello";
=======
    print "goodbye";
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch indent-strip: patch applied"
    );

    my $patched = slurp($test_file);

    my @hellos   = ($patched =~ /print "hello"/g);
    my @goodbyes = ($patched =~ /print "goodbye"/g);

    is(scalar @goodbyes,
        1, "apply_patch indent-strip: one occurrence replaced");
    is(
        scalar @hellos,
        1,
        "apply_patch indent-strip: one occurrence remains (first-match-only)"
    );
}


=head3 Test ,apply_patch: ORIGINAL and UPDATED are identical (no-op patch)

=cut

{
    my $test_file = "$temp_dir/apply_patch_noop.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "keep this line\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
keep this line
=======
keep this line
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch noop: identical ORIGINAL/UPDATED still reports success"
    );

    unlike($res->{stdout}, qr/WARNING/,
        "apply_patch noop: no warnings on identity replacement");

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/keep this line/,
        "apply_patch noop: content unchanged as expected"
    );
}


=head3 Test ,apply_patch: multi-block patch where one block fails and another succeeds

=cut

{
    my $test_file = "$temp_dir/apply_patch_partial_fail.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "alpha\nbeta\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
nonexistent_line
=======
should_not_appear
>>>>>> UPDATED
<<<<<< ORIGINAL
beta
=======
BETA
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/WARNING:.*Search text not found.*nonexistent_line/s,
        "apply_patch partial-fail: WARNING for missing search text"
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch partial-fail: patch still applied (second block succeeded)"
    );

    my $patched = slurp($test_file);
    like($patched, qr/BETA/,
        "apply_patch partial-fail: successful block's replacement present");
    unlike($patched, qr/should_not_appear/,
        "apply_patch partial-fail: failed block's replacement absent");
    like($patched, qr/alpha/,
        "apply_patch partial-fail: unrelated content preserved");
}


=head3 Test ,apply_patch: replacement text contains apply_patch marker strings

=cut

{
    my $test_file = "$temp_dir/apply_patch_meta_markers.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "PLACEHOLDER\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
PLACEHOLDER
=======
# Example patch format:
# <<<<<< ORIGINAL
# old code
# =======
# new code
# >>>>>> UPDATED
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    my $applied = ($res->{stdout} =~ /apply_patch: Applied edits to file/);
    my $errored = ($res->{stdout} =~ /ERROR:/);

    ok(
        $applied || $errored,
        "apply_patch meta-markers: produces either success or a clear error (no crash)"
    );

    if ($applied) {
        my $patched = slurp($test_file);
        unlike($patched, qr/^PLACEHOLDER$/m,
            "apply_patch meta-markers: original PLACEHOLDER removed if patch applied"
        );
    }
    else {
        diag("errored (acceptable); stdout:\n$res->{stdout}");
    }
}

=head3 Test ,apply_patch: replacement with interior blank lines (via multi-line STDIN)

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_blank_lines.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "before\nOLD\nafter\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
OLD
=======
NEW_LINE_1

NEW_LINE_2


NEW_LINE_3
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch blank-lines: patch applied"
    );

    my $patched = slurp($test_file);
    like($patched, qr/NEW_LINE_1/,
        "apply_patch blank-lines: first new line present");
    like($patched, qr/NEW_LINE_2/,
        "apply_patch blank-lines: second new line present");
    like($patched, qr/NEW_LINE_3/,
        "apply_patch blank-lines: third new line present");
    unlike($patched, qr/^OLD$/m, "apply_patch blank-lines: old text removed");

    if ($patched =~ /NEW_LINE_1(.*?)NEW_LINE_3/s) {
        my $middle = $1;
        my @blanks = ($middle =~ /^$/mg);
        ok(
            scalar @blanks >= 1,
            "apply_patch blank-lines: interior blank lines preserved (got "
              . scalar(@blanks) . ")"
        );
    }
}


=head3 Test ,apply_patch: Unicode content

=cut

{
    my $test_file = "$temp_dir/apply_patch_unicode.txt";
    open my $fh, '>:encoding(UTF-8)', $test_file
      or die "cannot write $test_file: $!";
    print $fh "greeting = \"Hej verden\";\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
greeting = "Hej verden";
=======
greeting = "Hej verden! Goddag!";
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch unicode: patch with accented characters applied"
    );

    my $patched = slurp($test_file);
    like($patched, qr/Goddag/,
        "apply_patch unicode: replacement text present");
}


=head3 Test ,apply_patch: very long single line (2000+ chars)

=cut

{
    my $test_file = "$temp_dir/apply_patch_long_line.txt";
    my $prefix    = "A" x 1000;
    my $suffix    = "Z" x 1000;
    my $content   = "${prefix}FIND_ME${suffix}\n";

    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh $content;
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
FIND_ME
=======
REPLACED
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch long-line: patch applied on long single-line file"
    );

    my $patched = slurp($test_file);
    like($patched, qr/REPLACED/,
        "apply_patch long-line: replacement present in long line");
    unlike($patched, qr/FIND_ME/,
        "apply_patch long-line: original substring removed");
    like($patched, qr/^A{1000}REPLACEDZ{1000}$/m,
        "apply_patch long-line: surrounding content preserved");
}


=head3 Test ,apply_patch: three blocks, middle one fails

=cut

{
    my $test_file = "$temp_dir/apply_patch_sandwich_fail.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "head\nmiddle\ntail\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
head
=======
HEAD
>>>>>> UPDATED
<<<<<< ORIGINAL
this_does_not_exist
=======
GHOST
>>>>>> UPDATED
<<<<<< ORIGINAL
tail
=======
TAIL
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/WARNING:.*Search text not found.*this_does_not_exist/s,
        "apply_patch sandwich-fail: WARNING for missing middle block"
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch sandwich-fail: file still written (other blocks succeeded)"
    );

    my $patched = slurp($test_file);
    like($patched, qr/HEAD/,
        "apply_patch sandwich-fail: first block applied");
    like($patched, qr/TAIL/,
        "apply_patch sandwich-fail: third block applied");
    like($patched, qr/middle/,
        "apply_patch sandwich-fail: untargeted middle preserved");
    unlike($patched, qr/GHOST/,
        "apply_patch sandwich-fail: failed block's replacement absent");
    unlike($patched, qr/^head$/m,
        "apply_patch sandwich-fail: first original removed");
    unlike($patched, qr/^tail$/m,
        "apply_patch sandwich-fail: third original removed");
}


=head3 Test ,apply_patch: substring match semantics

=cut

{
    my $test_file = "$temp_dir/apply_patch_substring.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "foobar\nbazfoo\nfoo\n";
    close $fh;

    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
foo
=======
QUX
>>>>>> UPDATED
EOF
    chomp $diff_content;
    $diff_content =~ s/\n/<NL>/g;

    my $res = run_synergy_session(
        [
            ",cd $temp_dir\n",
            ",apply_patch $test_file '$diff_content'\n", ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$test_file\E'/,
        "apply_patch substring: patch applied"
    );

    my $patched = slurp($test_file);

    like($patched, qr/QUXbar/,
        "apply_patch substring: first occurrence (inside foobar) was replaced"
    );
    like($patched, qr/bazfoo/,
        "apply_patch substring: bazfoo untouched (not first match)");
    like($patched, qr/^foo$/m,
        "apply_patch substring: standalone foo untouched (not first match)");
}

=head3 Test ,apply_patch: REPL command regex truncation (known limitation)

Documents that %, +, ~, &, and tab in multi-line STDIN patches cause
the REPL command regex to truncate the argument.  The workaround is
<NL> encoding.

=cut

{
    my $test_file = "$temp_dir_simple/apply_patch_charclass_limit.txt";
    open my $fh, '>', $test_file or die "cannot write $test_file: $!";
    print $fh "my \%hash = ();\n";
    close $fh;

    # Multi-line STDIN path -- the % will truncate $maybe_arg
    my $diff_content = <<'EOF';
<<<<<< ORIGINAL
my %hash = ();
=======
my %hash = (key => 1);
>>>>>> UPDATED
EOF

    my $res = run_synergy_session(
        [
            ",cd $temp_dir_simple\n",
            ",apply_patch $test_file '$diff_content'\n",
            ",exit\n"
        ]
    );

    like(
        $res->{stdout},
        qr/ERROR: No valid edit blocks found in diff text/,
        "apply_patch charclass-limit: multi-line STDIN truncates at % (known limitation)"
    );

    my $patched = slurp($test_file);
    like(
        $patched,
        qr/my %hash = \(\);/,
        "apply_patch charclass-limit: file unchanged after truncated patch"
    );
}


done_testing();

END {
    chdir $original_cwd;
}
