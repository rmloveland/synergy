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

=head3 Test curl request generation (Anthropic)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"thinking","thinking":"internal","signature":"sig_123"},{"type":"text","text":"OK_ANTH"},{"type":"text","text":"ROPIC"}]}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello anthropic\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_ANTHROPIC/,
        "curl anthropic: returns stub reply");
    is($results->{exit_code}, 0, "curl anthropic: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my ($hdr_file)  = glob("$capture_dir/req_*_headers.txt");
    my ($url_file)  = glob("$capture_dir/req_*_url.txt");
    ok($body_file, "curl anthropic: captured body");
    ok($hdr_file,  "curl anthropic: captured headers");
    ok($url_file,  "curl anthropic: captured url");

    my $body = decode_json(slurp($body_file));
    is($body->{model}, "claude-sonnet-4-6", "curl anthropic: model set");
    is($body->{max_tokens}, 8192,
        "curl anthropic: max_tokens defaults to non-thinking chat budget");
    ok(!exists $body->{thinking},
        "curl anthropic: thinking disabled by default for chat");
    ok(!exists $body->{output_config},
        "curl anthropic: output_config omitted when thinking disabled");
    ok(!exists $body->{cache_control},
        "curl anthropic: cache_control not at request body root");
    ok(
        ref($body->{system}) eq 'ARRAY' && @{$body->{system}},
        "curl anthropic: system prompt is a content block array"
    );
    is($body->{system}[0]{type},
        'text', "curl anthropic: system block type is text");
    ok(
        length($body->{system}[0]{text} // ""),
        "curl anthropic: system block has text"
    );
    is_deeply(
        $body->{system}[0]{cache_control},
        {type => 'ephemeral'},
        "curl anthropic: cache_control is inside system content block"
    );

    my $headers = slurp($hdr_file);
    like(
        $headers,
        qr/x-api-key: ANTHROPIC_KEY_TEST/,
        "curl anthropic: api key header set"
    );
    like(
        $headers,
        qr/anthropic-version: 2023-06-01/,
        "curl anthropic: version header set"
    );

    my $url = slurp($url_file);
    like(
        $url,
        qr{https://api\.anthropic\.com/v1/messages},
        "curl anthropic: endpoint correct"
    );
}

=head3 Test Anthropic context message gets cache control

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $context_file = "$temp_dir/anthropic_context_cache_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print {$cfh} "Anthropic context cache line\n";
    close $cfh;

    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":"CONTEXT_CACHE_OK"}]}';

    my $results = run_synergy_session(
        [
            ",model claude-sonnet\n",
            ",push $context_file\n",
            "Hello anthropic context cache\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/CONTEXT_CACHE_OK/,
        "anthropic context cache: returns stub reply");
    is($results->{exit_code}, 0, "anthropic context cache: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "anthropic context cache: captured body");

    my $body = decode_json(slurp($body_file));
    ok(!exists $body->{cache_control},
        "anthropic context cache: cache_control not at request body root");
    is_deeply(
        $body->{system}[0]{cache_control},
        {type => 'ephemeral'},
        "anthropic context cache: system cache control remains present"
    );

    my ($context_block) = grep {
             ref($_) eq 'HASH'
          && ($_->{text} // '') =~ /Relevant file\/context state/
          && ($_->{text} // '')
          =~ /Anthropic context cache line/
    } map { ref($_->{content}) eq 'ARRAY' ? @{$_->{content}} : () }
      @{$body->{messages}};

    ok($context_block,
        "anthropic context cache: context is emitted as content block");
    is_deeply(
        $context_block->{cache_control},
        {type => 'ephemeral'},
        "anthropic context cache: context block has cache control"
    );
}

=head3 Test Anthropic response parsing fallback (thinking-only)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"thinking","thinking":"ONLY_THINKING_TEXT"}]}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello anthropic fallback\n", ",exit\n"]);

    like($results->{stdout}, qr/ONLY_THINKING_TEXT/,
        "anthropic fallback thinking-only: emits thinking text when no text block exists"
    );
    is($results->{exit_code}, 0,
        "anthropic fallback thinking-only: exits cleanly");
}

=head3 Test Anthropic response parsing fallback (summary-only)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"thinking","summary":[{"text":"SUMMARY_A"},{"text":"SUMMARY_B"}]}]}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello anthropic summary\n", ",exit\n"]);

    like($results->{stdout}, qr/SUMMARY_ASUMMARY_B/,
        "anthropic fallback summary-only: emits summary text when no text block exists"
    );
    is($results->{exit_code}, 0,
        "anthropic fallback summary-only: exits cleanly");
}

=head3 Test model switch mid-session into Anthropic response parsing

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY_1}
      = '{"output":[{"content":[{"type":"output_text","text":"OPENAI_BEFORE_SWITCH"}]}]}';
    local $ENV{SYNERGY_CURL_FAKE_BODY_2}
      = '{"content":[{"type":"thinking","summary":[{"text":"ANTH_AFTER_SWITCH"}]}]}';

    my $results = run_synergy_session(
        [
            ",model gpt-5\n",
            "Hello openai pre-switch\n",
            ",model claude-sonnet\n",
            "Hello anthropic post-switch\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/OPENAI_BEFORE_SWITCH/,
        "model switch parsing: OpenAI response is present");
    like($results->{stdout}, qr/ANTH_AFTER_SWITCH/,
        "model switch parsing: Anthropic fallback response is present");
    is($results->{exit_code}, 0, "model switch parsing: exits cleanly");
}

=head3 Test curl request generation (Anthropic Opus 4.6 thinking config)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":"OK_OPUS"}]}';

    my $results = run_synergy_session(
        [",model claude-opus\n", "Hello opus\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPUS/,
        "curl anthropic opus: returns stub reply");
    is($results->{exit_code}, 0, "curl anthropic opus: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "curl anthropic opus: captured body");

    my $body = decode_json(slurp($body_file));
    is($body->{model}, "claude-opus-4-8", "curl anthropic opus: model set");
    is($body->{max_tokens}, 8192,
        "curl anthropic opus: max_tokens defaults to non-thinking chat budget"
    );
    ok(!exists $body->{thinking},
        "curl anthropic opus: thinking disabled by default for chat");
    ok(!exists $body->{output_config},
        "curl anthropic opus: output_config omitted when thinking disabled");
    ok(!exists $body->{cache_control},
        "curl anthropic opus: cache_control not at request body root");
    is_deeply(
        $body->{system}[0]{cache_control},
        {type => 'ephemeral'},
        "curl anthropic opus: cache_control is inside system content block"
    );
}

=head3 Test Anthropic prompt cache TTL override via env

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR}           = $capture_dir;
    local $ENV{PATH}                               = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}                  = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_ANTHROPIC_PROMPT_CACHE_TTL} = "1h";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":"CACHE_TTL_OK"}]}';

    my $context_file = "$temp_dir/anthropic_context_ttl_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print {$cfh} "Anthropic context ttl line\n";
    close $cfh;

    my $results = run_synergy_session(
        [
            ",model claude-sonnet\n",
            ",push $context_file\n",
            "Hello anthropic ttl\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/CACHE_TTL_OK/,
        "anthropic cache ttl: returns stub reply");
    is($results->{exit_code}, 0, "anthropic cache ttl: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "anthropic cache ttl: captured body");

    my $body = decode_json(slurp($body_file));
    ok(!exists $body->{cache_control},
        "anthropic cache ttl: cache_control not at request body root");
    is_deeply(
        $body->{system}[0]{cache_control},
        {type => 'ephemeral', ttl => '1h'},
        "anthropic cache ttl: cache_control with ttl is inside system content block"
    );

    my ($context_block) = grep {
             ref($_) eq 'HASH'
          && ($_->{text} // '') =~ /Relevant file\/context state/
          && ($_->{text} // '')
          =~ /Anthropic context ttl line/
    } map { ref($_->{content}) eq 'ARRAY' ? @{$_->{content}} : () }
      @{$body->{messages}};

    ok($context_block, "anthropic cache ttl: captured context block");
    is_deeply(
        $context_block->{cache_control},
        {type => 'ephemeral', ttl => '1h'},
        "anthropic cache ttl: context cache control includes ttl"
    );
}

=head3 Test Anthropic thinking opt-out via env

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_NO_THINKING}      = 1;
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":"NO_THINKING_OK"}]}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello no-thinking\n", ",exit\n"]);

    like($results->{stdout}, qr/NO_THINKING_OK/,
        "anthropic no-thinking: returns stub reply");
    is($results->{exit_code}, 0, "anthropic no-thinking: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "anthropic no-thinking: captured body");

    my $body = decode_json(slurp($body_file));
    ok(!exists $body->{thinking},
        "anthropic no-thinking: thinking block omitted");
    ok(!exists $body->{output_config},
        "anthropic no-thinking: output_config omitted");
    is($body->{max_tokens}, 8192,
        "anthropic no-thinking: max_tokens falls back to default");
}

=head3 Test Anthropic max_tokens override via env

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR}     = $capture_dir;
    local $ENV{PATH}                         = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}            = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_ANTHROPIC_MAX_TOKENS} = 9999;
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"text","text":"OVERRIDE_OK"}]}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello max override\n", ",exit\n"]);

    like($results->{stdout}, qr/OVERRIDE_OK/,
        "anthropic max override: returns stub reply");
    is($results->{exit_code}, 0, "anthropic max override: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "anthropic max override: captured body");

    my $body = decode_json(slurp($body_file));
    is($body->{max_tokens}, 9999,
        "anthropic max override: max_tokens set from env");
    ok(!exists $body->{thinking},
        "anthropic max override: thinking remains disabled for normal chat");
}

=head3 Test Anthropic thinking trace logging (env-gated)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $log_dir = $ENV{SYNERGY_LOG_DIR} // "$synergy_root/var/log";
    my %before  = map { $_ => 1 } glob("$log_dir/chats-*.txt");
    local $ENV{SYNERGY_CURL_CAPTURE_DIR}       = $capture_dir;
    local $ENV{PATH}                           = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}              = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_LOG_ANTHROPIC_THINKING} = 1;
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"content":[{"type":"thinking","thinking":"TRACE_SNIPPET"},{"type":"text","text":"LOG_OK"}]}';

    my $results = run_synergy_file_session(
        [",model claude-sonnet\n", "Hello log-thinking\n", ",exit\n"]);

    like($results->{stdout}, qr/LOG_OK/,
        "anthropic thinking log: returns visible text");
    is($results->{exit_code}, 0, "anthropic thinking log: exits cleanly");

    my @after = glob("$log_dir/chats-*.txt");
    my @new   = grep { !$before{$_} } @after;
    ok(@new == 1, "anthropic thinking log: one new log file created")
      or diag("log_dir=$log_dir after=@after");

    my $log = slurp($new[0]);
    like(
        $log,
        qr/anthropic_thinking: TRACE_SNIPPET/,
        "anthropic thinking log: includes thinking trace"
    );
    like(
        $log,
        qr/SYNERGY >  LOG_OK/,
        "anthropic thinking log: includes normal visible response"
    );
}

=head3 Test curl request generation (Gemini)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{GEMINI_API_KEY}           = "GEMINI_KEY_TEST";

    my $results = run_synergy_session(
        [",model gemini-flash\n", "Hello gemini\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_GEMINI/,
        "curl gemini: returns stub reply");
    is($results->{exit_code}, 0, "curl gemini: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my ($hdr_file)  = glob("$capture_dir/req_*_headers.txt");
    my ($url_file)  = glob("$capture_dir/req_*_url.txt");
    ok($body_file, "curl gemini: captured body");
    ok($hdr_file,  "curl gemini: captured headers");
    ok($url_file,  "curl gemini: captured url");

    my $body = decode_json(slurp($body_file));
    is(scalar @{$body->{contents}}, 2, "curl gemini: system+user contents");
    is($body->{generationConfig}{maxOutputTokens},
        8192, "curl gemini: maxOutputTokens default");

    my $headers = slurp($hdr_file);
    like(
        $headers,
        qr/Content-Type: application\/json/,
        "curl gemini: content-type header set"
    );

    my $url = slurp($url_file);
    like(
        $url,
        qr{https://generativelanguage\.googleapis\.com/v1beta/models/.+:generateContent\?key=GEMINI_KEY_TEST},
        "curl gemini: endpoint includes key"
    );
}

=head3 Test curl request generation (Gemini structured history roles)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{GEMINI_API_KEY}           = "GEMINI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY_1}
      = '{"candidates":[{"content":{"parts":[{"text":"FIRST_GEMINI_REPLY"}]}}]}';
    local $ENV{SYNERGY_CURL_FAKE_BODY_2}
      = '{"candidates":[{"content":{"parts":[{"text":"SECOND_GEMINI_REPLY"}]}}]}';

    my $results = run_synergy_session(
        [
            ",model gemini-flash\n",
            "First structured gemini turn\n",
            "Second structured gemini turn\n",
            ",exit\n",
        ]
    );

    like($results->{stdout}, qr/SECOND_GEMINI_REPLY/,
        "curl gemini structured: returns second stub reply");
    is($results->{exit_code}, 0, "curl gemini structured: exits cleanly");

    my @body_files = sort glob("$capture_dir/req_*_body.json");
    is(scalar(@body_files), 2,
        "curl gemini structured: captured two request bodies");

    my $body = decode_json(slurp($body_files[1]));
    unlike(
        $body->{contents}[0]{parts}[0]{text},
        qr/Here is the history of the conversation to this point/,
        "curl gemini structured: system prompt no longer embeds history block"
    );
    is($body->{contents}[1]{role},
        "user", "curl gemini structured: prior user turn stays user role");
    is($body->{contents}[2]{role},
        "model",
        "curl gemini structured: prior assistant turn maps to model role");
    like($body->{contents}[2]{parts}[0]{text},
        qr/FIRST_GEMINI_REPLY/,
        "curl gemini structured: prior assistant content preserved");
    is($body->{contents}[3]{role},
        "user", "curl gemini structured: current turn stays final user role");
    like(
        $body->{contents}[3]{parts}[0]{text},
        qr/Second.*structured.*gemini.*turn/,
        "curl gemini structured: current turn content preserved"
    );
}

=head3 Test Gemini context remains provider-native text parts

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $context_file = "$temp_dir/gemini_context_no_cache_control_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print {$cfh} "Gemini context no cache control line\n";
    close $cfh;

    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{GEMINI_API_KEY}           = "GEMINI_KEY_TEST";

    my $results = run_synergy_session(
        [
            ",model gemini-flash\n",
            ",push $context_file\n",
            "Hello gemini context\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/OK_GEMINI/,
        "curl gemini context: returns stub reply");
    is($results->{exit_code}, 0, "curl gemini context: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "curl gemini context: captured body");

    my $body = decode_json(slurp($body_file));
    my ($context_content) = grep {
             ($_->{role} // '') eq 'user'
          && ref($_->{parts}) eq 'ARRAY'
          && (join '', map { $_->{text} // '' } @{$_->{parts}})
          =~ /Gemini context no cache control line/
    } @{$body->{contents}};

    ok($context_content,
        "curl gemini context: context sent as provider-native content");
    ok(
        !exists $context_content->{cache_control},
        "curl gemini context: content has no cache_control"
    );
    ok(!exists $context_content->{synergy_cache_role},
        "curl gemini context: internal cache metadata does not leak");
    ok(
        !(
            grep {
                exists($_->{cache_control}) || exists($_->{prompt_cache_key})
            } @{$body->{contents}}
        ),
        "curl gemini context: no Anthropic/OpenAI cache fields in contents"
    );
}

=head3 Test HTTP error handling (non-2xx)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{SYNERGY_CURL_FAKE_STATUS} = "401";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"error":{"message":"unauthorized"}}';
    local $ENV{PATH}           = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY} = "OPENAI_KEY_TEST";

    my $results
      = run_synergy_session([",model gpt-5\n", "Hello error\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/API call failed after 0 retries: HTTP 401/s,
        "http error: reports non-2xx status"
    );
    like($results->{stdout}, qr/unauthorized/s,
        "http error: includes response body preview");
    is($results->{exit_code}, 0, "http error: exits cleanly");
}

=head3 Test JSON parse error handling

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{SYNERGY_CURL_FAKE_STATUS} = "200";
    local $ENV{SYNERGY_CURL_FAKE_BODY}   = 'not-json';
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";

    my $results
      = run_synergy_session([",model gpt-5\n", "Hello badjson\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/Failed to parse JSON response:/s,
        "json error: reports parse failure"
    );
    is($results->{exit_code}, 0, "json error: exits cleanly");
}

=head3 Test curl execution error handling

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{SYNERGY_CURL_FAKE_EXIT}   = "7";
    local $ENV{SYNERGY_CURL_FAKE_STDERR} = "curl: simulated failure";
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello curlfail\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/curl failed \(exit 7\): curl: simulated failure/s,
        "curl error: reports curl failure"
    );
    is($results->{exit_code}, 0, "curl error: exits cleanly");
}

=head3 Test HTTP error preview truncation

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $long_body = "x" x 600;
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{SYNERGY_CURL_FAKE_STATUS} = "500";
    local $ENV{SYNERGY_CURL_FAKE_BODY}   = $long_body;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello longbody\n", ",exit\n"]);

    my $stdout = $results->{stdout};
    like(
        $stdout,
        qr/API call failed after 0 retries: HTTP 500:/s,
        "http preview: reports 500 status"
    );
    ok(
        index($stdout, ("x" x 400)) != -1,
        "http preview: includes 400-char prefix"
    );
    ok(index($stdout, ("x" x 401)) == -1,
        "http preview: does not include >400 chars");
    is($results->{exit_code}, 0, "http preview: exits cleanly");
}

=head3 Test missing API key handling

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY};

    my $results
      = run_synergy_session([",model gpt-5\n", "Hello no key\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/Missing API key for provider 'openai'/s,
        "missing api key: reports missing key"
    );
    is($results->{exit_code}, 0, "missing api key: exits cleanly");
}


done_testing();

END {
    chdir $original_cwd;
}
