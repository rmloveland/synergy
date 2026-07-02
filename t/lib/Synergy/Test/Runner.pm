package Synergy::Test::Runner;

use strict;
use warnings;

use Exporter       qw(import);
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);

our @EXPORT_OK = qw(
  fresh_test_root
  repo_root
  run_synergy_file_session
  run_synergy_session
  setup_test_env
  synergy_script
  write_fake_curl
  write_stub
);

my $REPO_ROOT;

sub repo_root {
    return $REPO_ROOT if defined $REPO_ROOT;

    my $dir = dirname(abs_path(__FILE__));
    $REPO_ROOT = abs_path(File::Spec->catdir($dir, '..', '..', '..', '..'));
    return $REPO_ROOT;
}

sub synergy_script {
    return File::Spec->catfile(repo_root(), 'synergy');
}

sub fresh_test_root {
    my $root = tempdir(CLEANUP => 1);
    make_path(
        File::Spec->catdir($root, 'var', 'log'),
        File::Spec->catdir($root, 'etc', 'dumps'),
    );
    return $root;
}

sub setup_test_env {
    my (%args) = @_;

    my $root
      = exists $ENV{SYNERGY_ROOT}
      ? $ENV{SYNERGY_ROOT}
      : ($args{root} // repo_root());

    my $log_dir
      = exists $ENV{SYNERGY_LOG_DIR}
      ? $ENV{SYNERGY_LOG_DIR}
      : ($args{log_dir} // File::Spec->catdir($root, 'var', 'log'));

    my $dump_dir
      = exists $ENV{SYNERGY_DUMP_DIR}
      ? $ENV{SYNERGY_DUMP_DIR}
      : ($args{dump_dir} // File::Spec->catdir($root, 'etc', 'dumps'));

    make_path($log_dir, $dump_dir);

    $ENV{SYNERGY_ROOT}     = $root     unless exists $ENV{SYNERGY_ROOT};
    $ENV{SYNERGY_LOG_DIR}  = $log_dir  unless exists $ENV{SYNERGY_LOG_DIR};
    $ENV{SYNERGY_DUMP_DIR} = $dump_dir unless exists $ENV{SYNERGY_DUMP_DIR};

    if ($args{seed_api_keys}) {
        $ENV{ANTHROPIC_API_KEY} = 'TEST_ANTHROPIC_KEY'
          unless exists $ENV{ANTHROPIC_API_KEY};
        $ENV{GEMINI_API_KEY} = 'TEST_GEMINI_KEY'
          unless exists $ENV{GEMINI_API_KEY};
        $ENV{OPENAI_API_KEY} = 'TEST_OPENAI_KEY'
          unless exists $ENV{OPENAI_API_KEY};
    }

    return {
        root           => $ENV{SYNERGY_ROOT},
        log_dir        => $ENV{SYNERGY_LOG_DIR},
        dump_dir       => $ENV{SYNERGY_DUMP_DIR},
        synergy_script => synergy_script(),
    };
}

sub run_synergy_session {
    my ($input_lines_ref, $synergy_path, $env, $env_delete_ref) = @_;
    $synergy_path ||= synergy_script();

    local %ENV = %ENV;
    delete @ENV{@$env_delete_ref} if $env_delete_ref && @$env_delete_ref;
    if ($env) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    my $stderr = gensym;
    my $pid    = open3(my $wtr, my $rdr, $stderr, $^X, $synergy_path);

    print {$wtr} $_ for @$input_lines_ref;
    close $wtr;

    my $stdout_output = do { local $/; <$rdr>    // '' };
    my $stderr_output = do { local $/; <$stderr> // '' };

    waitpid $pid, 0;
    my $exit_code = $?;

    return {
        stdout    => $stdout_output,
        stderr    => $stderr_output,
        exit_code => $exit_code,
        exit      => ($exit_code >> 8),
    };
}

sub run_synergy_file_session {
    my ($input_lines_ref, $synergy_path, $dir, $env, $env_delete_ref) = @_;
    $synergy_path ||= synergy_script();
    $dir          ||= File::Spec->tmpdir();

    local %ENV = %ENV;
    delete @ENV{@$env_delete_ref} if $env_delete_ref && @$env_delete_ref;
    if ($env) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    my ($ifh, $input_file) = tempfile(
        'agent_input_XXXX',
        DIR    => $dir,
        SUFFIX => '.txt',
        UNLINK => 0,
    );
    print {$ifh} $_ for @$input_lines_ref;
    close $ifh;

    my $cmd = join q{ }, _shell_quote($^X), _shell_quote($synergy_path), '<',
      _shell_quote($input_file), '2>&1';

    my $stdout_output = `$cmd`;
    my $exit_code     = $?;

    unlink $input_file;

    return {
        stdout    => $stdout_output,
        stderr    => '',
        exit_code => $exit_code,
        exit      => ($exit_code >> 8),
    };
}

sub write_stub {
    my ($body) = @_;
    my ($fh, $path) = tempfile();
    print {$fh} $body;
    close $fh;
    return $path;
}

sub write_fake_curl {
    my ($dir)     = @_;
    my $curl_path = File::Spec->catfile($dir, 'curl');
    my $test_lib  = File::Spec->catdir(repo_root(), 't', 'lib');
    $test_lib =~ s/'/'\\''/g;
    open my $fh, '>', $curl_path or die "Cannot create fake curl: $!";
    print {$fh} "#!/usr/bin/env perl\nuse lib '$test_lib';\n";
    print {$fh} <<'EOS';
use strict;
use warnings;
use File::Spec;

my @args = @ARGV;
my ($out, $stderr, $data, $url, $write_out);
my @headers;
for (my $i = 0; $i < @args; $i++) {
    my $a = $args[$i];
    if ($a eq '--output') { $out = $args[++$i]; next; }
    if ($a eq '--stderr') { $stderr = $args[++$i]; next; }
    if ($a eq '--data-binary') { $data = $args[++$i]; next; }
    if ($a eq '--write-out') { $write_out = $args[++$i]; next; }
    if ($a eq '--header') { push @headers, $args[++$i]; next; }
    if ($a =~ m{^https?://}i) { $url = $a; next; }
}

$data =~ s/^\@// if defined $data;
my $body = '';
if ($data && -f $data) {
    local $/;
    open my $bfh, '<', $data or die "fake curl: read body failed: $!";
    $body = <$bfh>;
    close $bfh;
}

my $dir = $ENV{SYNERGY_CURL_CAPTURE_DIR} || File::Spec->tmpdir();
my $counter_file = File::Spec->catfile($dir, "counter.txt");
my $n = 0;
if (open my $cfh, '<', $counter_file) {
    my $c = <$cfh>;
    close $cfh;
    $n = $c if defined $c;
}
$n++;
open my $cfh, '>', $counter_file or die "fake curl: counter write failed: $!";
print $cfh $n;
close $cfh;

my $prefix = File::Spec->catfile($dir, "req_$n");
open my $body_fh, '>', $prefix . "_body.json" or die "fake curl: body write failed: $!";
print $body_fh $body;
close $body_fh;

open my $hdr_fh, '>', $prefix . "_headers.txt" or die "fake curl: header write failed: $!";
print $hdr_fh join("\n", @headers);
close $hdr_fh;

open my $url_fh, '>', $prefix . "_url.txt" or die "fake curl: url write failed: $!";
print $url_fh ($url // '');
close $url_fh;

my $response = '{"output":[{"content":[{"type":"output_text","text":"OK_OPENAI"}]}]}';
if (($url // '') =~ /anthropic\.com/) {
    $response = '{"content":[{"text":"OK_ANTHROPIC"}]}';
} elsif (($url // '') =~ /generativelanguage\.googleapis\.com/) {
    $response = '{"candidates":[{"content":{"parts":[{"text":"OK_GEMINI"}]}}]}';
}

if (($ENV{SYNERGY_CURL_FAKE_CACHE_PROVIDER} // '') eq 'anthropic') {
    require Synergy::Test::Cache::Anthropic;
    my $cache = Synergy::Test::Cache::Anthropic->new(
        store_dir => $ENV{SYNERGY_CURL_FAKE_CACHE_STORE},
    );
    $response = $cache->fake_response_json($body);
}
elsif (($ENV{SYNERGY_CURL_FAKE_CACHE_PROVIDER} // '') eq 'openai') {
    require Synergy::Test::Cache::OpenAI;
    my $cache = Synergy::Test::Cache::OpenAI->new(
        store_dir => $ENV{SYNERGY_CURL_FAKE_CACHE_STORE},
    );
    $response = $cache->fake_response_json($body);
}
elsif (($ENV{SYNERGY_CURL_FAKE_CACHE_PROVIDER} // '') eq 'gemini') {
    require Synergy::Test::Cache::Gemini;
    my $model;
    if (($url // '') =~ m{/models/([^:]+):generateContent}) {
        $model = $1;
    }
    my $cache = Synergy::Test::Cache::Gemini->new(
        store_dir => $ENV{SYNERGY_CURL_FAKE_CACHE_STORE},
        model     => $model,
    );
    $response = $cache->fake_response_json($body);
}

my $seq_key = "SYNERGY_CURL_FAKE_BODY_$n";
if (defined $ENV{$seq_key}) {
    $response = $ENV{$seq_key};
}
elsif (defined $ENV{SYNERGY_CURL_FAKE_BODY}) {
    $response = $ENV{SYNERGY_CURL_FAKE_BODY};
}

if ($out) {
    open my $ofh, '>', $out or die "fake curl: output write failed: $!";
    print $ofh $response;
    close $ofh;
}
if ($stderr) {
    open my $efh, '>', $stderr or die "fake curl: stderr write failed: $!";
    if (defined $ENV{SYNERGY_CURL_FAKE_STDERR}) {
        print $efh $ENV{SYNERGY_CURL_FAKE_STDERR};
    }
    close $efh;
}

if (defined $ENV{SYNERGY_CURL_FAKE_EXIT} && $ENV{SYNERGY_CURL_FAKE_EXIT} ne "0") {
    exit int($ENV{SYNERGY_CURL_FAKE_EXIT});
}

my $status = $ENV{SYNERGY_CURL_FAKE_STATUS} // "200";
my $write = defined($write_out) ? $write_out : '%{http_code}';
$write =~ s/%\{http_code\}/$status/g;
if ($out) {
    print $write;
}
else {
    print $response;
    print $write;
}
exit 0;
EOS
    close $fh;
    chmod 0755, $curl_path or die "Cannot chmod fake curl: $!";
    return $curl_path;
}

sub _shell_quote {
    my ($value) = @_;
    $value //= q{};
    $value =~ s/'/'\\''/g;
    return qq['$value'];
}

1;
