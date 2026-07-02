#!/usr/bin/env perl

use strict;
use warnings;
use lib 't/lib';
use Test::More;
use File::Slurp qw(slurp);
use File::Temp  qw(tempdir);
use Cwd         qw(abs_path);
use Synergy::Test::Runner
  qw(run_synergy_file_session run_synergy_session setup_test_env write_fake_curl);

use constant OFFLINE_MODE => 1;

my $repo_root    = abs_path();
my $temp_dir     = tempdir(DIR     => $repo_root, CLEANUP => 1);
my $outside_dir  = tempdir(CLEANUP => 1);
my $original_cwd = abs_path();
my $env          = setup_test_env(
    log_dir       => $temp_dir,
    dump_dir      => $temp_dir,
    seed_api_keys => 1,
);
my $SYNERGY = $env->{synergy_script};

if (OFFLINE_MODE) {
    my $curl_dir = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    $ENV{SYNERGY_CURL_CAPTURE_DIR} = $temp_dir
      unless exists $ENV{SYNERGY_CURL_CAPTURE_DIR};
}

sub write_text {
    my ($file, $text) = @_;
    open my $fh, '>', $file or die "cannot write $file: $!";
    print {$fh} $text;
    close $fh;
}

sub encoded_patch {
    my ($original, $updated) = @_;

    my $patch = <<EOF;
<<<<<< ORIGINAL
$original=======
$updated>>>>>> UPDATED
EOF
    chomp $patch;
    $patch =~ s/\n/<NL>/g;
    return $patch;
}

sub run_apply_patch {
    my ($file, $original, $updated, $extra_env) = @_;

    my $patch = encoded_patch($original, $updated);
    return run_synergy_session([",apply_patch $file '$patch'\n", ",exit\n"],
        $SYNERGY, $extra_env,);
}

=head3 Path safety: unresolved parent traversal cannot escape HOME

=cut

{
    my $home        = tempdir(CLEANUP => 1);
    my $escape_file = "$home/../apply_patch_escape_$$.txt";
    unlink $escape_file if -e $escape_file;

    my $res = run_apply_patch(
        $escape_file,
        '',
        "escaped\n",
        {
            HOME             => $home,
            SYNERGY_ROOT     => $env->{root},
            SYNERGY_LOG_DIR  => $env->{log_dir},
            SYNERGY_DUMP_DIR => $env->{dump_dir},
        },
    );

    like(
        $res->{stdout},
        qr/ERROR: File '\Q$escape_file\E' must be within \$HOME/,
        "apply_patch path safety: rejects new file path escaping HOME via .."
    );
    ok(!-e $escape_file,
        "apply_patch path safety: escaped new file was not created");
}

=head3 Path safety: symlink inside HOME cannot edit target outside HOME

=cut

{
    my $outside_file = "$outside_dir/apply_patch_outside_target_$$.txt";
    my $link_file    = "$temp_dir/apply_patch_link_out_$$.txt";
    write_text($outside_file, "outside\n");

  SKIP: {
        skip "symlinks unavailable on this filesystem", 2
          unless symlink $outside_file, $link_file;

        my $res = run_apply_patch($link_file, "outside\n", "inside\n");

        like(
            $res->{stdout},
            qr/ERROR: File '\Q$link_file\E' must be within \$HOME/,
            "apply_patch path safety: rejects symlink from HOME to outside target"
        );
        is(slurp($outside_file), "outside\n",
            "apply_patch path safety: outside symlink target unchanged");
    }
}

=head3 Fallback safety: ambiguous whitespace match is refused

=cut

{
    my $file = "$temp_dir/apply_patch_ambiguous_ws_$$.txt";
    write_text($file, "same    value\nmiddle\nsame    value\n");

    my $res = run_apply_patch($file, "same value\n", "changed\n");

    like(
        $res->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch fallback: ambiguous whitespace match warns instead of editing"
    );
    is(
        slurp($file),
        "same    value\nmiddle\nsame    value\n",
        "apply_patch fallback: ambiguous whitespace match leaves file unchanged"
    );
}

=head3 Fallback safety: ambiguous anchor-window match is refused

=cut

{
    my $file = "$temp_dir/apply_patch_ambiguous_anchor_$$.txt";
    write_text($file,
            "start anchor\nfirst actual\nend anchor\n"
          . "between\n"
          . "start anchor\nsecond actual\nend anchor\n");

    my $res
      = run_apply_patch($file, "start anchor\nexpected middle\nend anchor\n",
        "replacement\n",);

    like(
        $res->{stdout},
        qr/WARNING: Search text not found/,
        "apply_patch fallback: ambiguous anchor-window match warns instead of editing"
    );
    unlike(slurp($file), qr/replacement/,
        "apply_patch fallback: ambiguous anchor-window match leaves file unchanged"
    );
}

=head3 Backup behavior: first write creates one original-content backup

=cut

{
    my $file = "$temp_dir/apply_patch_backup_once_$$.txt";
    write_text($file, "one\n");

    my $first  = encoded_patch("one\n", "two\n");
    my $second = encoded_patch("two\n", "three\n");

    my $res = run_synergy_session(
        [
            ",apply_patch $file '$first'\n",
            ",apply_patch $file '$second'\n",
            ",exit\n",
        ],
        $SYNERGY,
    );

    unlike(
        $res->{stdout},
        qr/apply_patch: backed up '\Q$file\E'/,
        "apply_patch backup: does not report backup notice to REPL stdout"
    );

    my @backups = glob "$file.*.bak";
    is(
        scalar @backups,
        1,
        "apply_patch backup: only one backup is created per file per session"
    );
    is(slurp($backups[0]),
        "one\n", "apply_patch backup: backup contains original content");
    is(slurp($file), "three\n", "apply_patch backup: both edits applied");
}

=head3 Backup behavior: new-file patch does not create empty backup

=cut

{
    my $file = "$temp_dir/apply_patch_new_no_backup_$$.txt";
    unlink $file if -e $file;

    my $res = run_apply_patch($file, '', "new content\n");

    like(
        $res->{stdout},
        qr/File '\Q$file\E' does not exist, will create new file/,
        "apply_patch backup: new-file patch reports creation"
    );
    is(slurp($file), "new content",
        "apply_patch backup: new-file patch writes requested content");

    my @backups = glob "$file.*.bak";
    is(scalar @backups,
        0, "apply_patch backup: new-file patch does not create empty backup");
}

=head3 Filesystem errors: missing parent directory reports write failure

=cut

{
    my $file = "$temp_dir/missing_parent_$$/apply_patch_write_failure.txt";

    my $res = run_apply_patch($file, '', "new content\n");

    like(
        $res->{stdout},
        qr/ERROR: Could not write to file '\Q$file\E'/,
        "apply_patch filesystem: missing parent reports write error"
    );
    ok(
        !-e $file,
        "apply_patch filesystem: missing-parent write failure creates no file"
    );

    my @backups = glob "$file.*.bak";
    is(
        scalar @backups,
        0,
        "apply_patch filesystem: missing-parent write failure creates no backup"
    );
}

=head3 Self-hosting canary: agent apply_patch edits Synergy marker example

=cut

{
    my $copy   = "$temp_dir/synergy_self_hosting_$$";
    my $source = slurp($SYNERGY);
    write_text($copy, $source);

    my $original = <<'ORIGINAL';
sub agent_apply_patch_example {
    my (%args)         = @_;
    my $command_prefix = $args{command_prefix} // '';
    my $line_prefix    = $args{line_prefix}    // '';

    return join("\n",
        $command_prefix . ",apply_patch file.txt <<<<<< ORIGINAL",
        $line_prefix . "foo",
        $line_prefix . "=======",
        $line_prefix . "bar",
        $line_prefix . ">>>>>> UPDATED",
    );
}
ORIGINAL

    my $updated = <<'UPDATED';
sub agent_apply_patch_example {
    my (%args)         = @_;
    my $command_prefix = $args{command_prefix} // '';
    my $line_prefix    = $args{line_prefix}    // '';

    return join("\n",
        $command_prefix . ",apply_patch file.txt <<<<<< ORIGINAL",
        $line_prefix . "before",
        $line_prefix . "=======",
        $line_prefix . "after",
        $line_prefix . ">>>>>> UPDATED",
    );
}
UPDATED

    my $copy_source = slurp($copy);
    ok(
        index($copy_source, $original) >= 0,
        "apply_patch self-hosting: copied synergy source has marker example block"
    );

    my $response = <<EOF;
,apply_patch $copy <<<<<< ORIGINAL
$original=======
$updated>>>>>> UPDATED
,comment AGENT_COMPLETE: self-hosting patch ok
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $res
      = run_synergy_file_session(
        [",agent test self-hosting apply_patch\n", ",exit\n"],
        $SYNERGY, $temp_dir,);

    like(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$copy\E'/,
        "apply_patch self-hosting: agent patches copied synergy source"
    );

    my $patched = slurp($copy);
    ok(
        index($patched, '        $line_prefix . "before",') >= 0,
        "apply_patch self-hosting: updated marker-adjacent code is present"
    );
    ok(
        index($patched,
            '        $command_prefix . ",apply_patch file.txt <<<<<< ORIGINAL",'
        ) >= 0,
        "apply_patch self-hosting: embedded ORIGINAL marker text is preserved"
    );
    ok(
        index($patched, '        $line_prefix . ">>>>>> UPDATED",') >= 0,
        "apply_patch self-hosting: embedded UPDATED marker text is preserved"
    );

    my $syntax_status = system($^X, '-c', $copy);
    is($syntax_status, 0,
        "apply_patch self-hosting: patched synergy copy still passes perl -c"
    );
}

=head3 Agent parser: filenames with spaces are not partially applied

=cut

{
    my $file = "$temp_dir/apply patch space path $$.txt";
    write_text($file, "alpha\n");

    my $response = <<EOF;
,apply_patch $file <<<<<< ORIGINAL
alpha
=======
beta
>>>>>> UPDATED
,comment AGENT_COMPLETE: space path done
EOF
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = $response;
    local $ENV{SYNERGY_AGENT_FAST}       = 1;

    my $res
      = run_synergy_file_session(
        [",agent test apply_patch space path\n", ",exit\n"],
        $SYNERGY, $temp_dir,);

    unlike(
        $res->{stdout},
        qr/apply_patch: Applied edits to file '\Q$file\E'/,
        "agent apply_patch parser: space-containing path is not applied as intended"
    );
    is(slurp($file), "alpha\n",
        "agent apply_patch parser: space-containing path leaves file unchanged"
    );
}

done_testing();

END {
    chdir $original_cwd if defined $original_cwd;
}
