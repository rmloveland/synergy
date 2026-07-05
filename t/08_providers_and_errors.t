#!/usr/bin/env perl

use strict;
use warnings;
use feature qw/ say /;
use Data::Dumper;
use lib 't/lib';
use Test::More;
use File::Slurp  qw/ slurp /;
use File::Temp   qw(tempdir);
use JSON::PP     qw(decode_json);
use MIME::Base64 qw(decode_base64);
use Cwd          qw(abs_path getcwd);
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
    is($body->{model}, "claude-sonnet-5", "curl anthropic: model set");
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

=head3 Test curl request generation (Fireworks, chat-completions dialect)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{FIREWORKS_API_KEY}        = "FIREWORKS_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"choices":[{"message":{"role":"assistant","content":"OK_FIREWORKS"}}],"usage":{"prompt_tokens":200,"completion_tokens":40,"total_tokens":240,"prompt_tokens_details":{"cached_tokens":150}}}';

    my $results = run_synergy_session(
        [",model deepseek\n", "Hello fireworks\n", ",tokens\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_FIREWORKS/,
        "curl fireworks: returns stub reply");
    is($results->{exit_code}, 0, "curl fireworks: exits cleanly");

    like(
        $results->{stdout},
        qr/tokens: input=200 output=40 total=240 cached=150 cache_hit_pct=75\.0%/,
        "curl fireworks: usage accumulates via the OpenAI parser"
    );

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my ($hdr_file)  = glob("$capture_dir/req_*_headers.txt");
    my ($url_file)  = glob("$capture_dir/req_*_url.txt");
    ok($body_file, "curl fireworks: captured body");

    my $body = decode_json(slurp($body_file));
    is(
        $body->{model},
        "accounts/fireworks/models/deepseek-v4-pro",
        "curl fireworks: model set"
    );
    is($body->{max_tokens}, 16384,
        "curl fireworks: max_tokens has a generous default");
    ok(ref($body->{messages}) eq 'ARRAY' && @{$body->{messages}},
        "curl fireworks: messages array present");
    is($body->{messages}[0]{role},
        'system', "curl fireworks: system prompt is the first message");
    is($body->{messages}[-1]{role},
        'user', "curl fireworks: live user message is last");
    like(
        $body->{messages}[-1]{content},
        qr/Hello fireworks/,
        "curl fireworks: user message content sent"
    );
    ok(
        !exists $body->{input} && !exists $body->{reasoning},
        "curl fireworks: no Responses-API fields leak into the body"
    );

    my $headers = slurp($hdr_file);
    like(
        $headers,
        qr/Authorization: Bearer FIREWORKS_KEY_TEST/,
        "curl fireworks: bearer auth header set"
    );

    my $url = slurp($url_file);
    like(
        $url,
        qr{https://api\.fireworks\.ai/inference/v1/chat/completions},
        "curl fireworks: endpoint correct"
    );
}

=head3 Test GLM model selection routes to Fireworks

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{FIREWORKS_API_KEY}        = "FIREWORKS_KEY_TEST";

    my $results
      = run_synergy_session([",model glm\n", "Hello glm\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/Switched model to 'glm'/,
        "glm: model switch reported"
    );
    like($results->{stdout}, qr/OK_FIREWORKS/,
        "glm: fake curl fireworks branch answers");
    is($results->{exit_code}, 0, "glm: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my $body = decode_json(slurp($body_file));
    is(
        $body->{model},
        "accounts/fireworks/models/glm-5p2",
        "glm: fireworks model name sent"
    );
}

=head3 Test Fireworks deepseek-flash model

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{FIREWORKS_API_KEY}        = "FIREWORKS_KEY_TEST";

    my $results = run_synergy_session(
        [",model deepseek-flash\n", "Hello flash\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/Switched model to 'deepseek-flash'/,
        "deepseek-flash: model switch reported"
    );
    like($results->{stdout}, qr/OK_FIREWORKS/,
        "deepseek-flash: fake curl fireworks branch answers");
    is($results->{exit_code}, 0, "deepseek-flash: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my $body = decode_json(slurp($body_file));
    is(
        $body->{model},
        "accounts/fireworks/models/deepseek-v4-flash",
        "deepseek-flash: fireworks model name sent"
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

=head3 Test context message survives pushed files containing fences

The context container uses sentinel lines, not markdown fences: a
pushed markdown file with its own ``` blocks must sit intact between
BEGIN/END, not terminate the container early.

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $fency_file = "$temp_dir/context_fence_collision_$$.md";
    open my $ffh, '>', $fency_file or die "Cannot create $fency_file: $!";
    print {$ffh} join("\n",
        "# Notes", "```perl",                "print 'inner fence';",
        "```",     "AFTER_INNER_FENCE_MARK", "");
    close $ffh;

    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"output":[{"content":[{"type":"output_text","text":"FENCE_OK"}]}]}';

    my $results = run_synergy_session(
        [
            ",model gpt-5\n",
            ",push $fency_file\n",
            "fence collision probe\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/FENCE_OK/,
        "context fence: returns stub reply");
    is($results->{exit_code}, 0, "context fence: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "context fence: captured body");

    my $body = decode_json(slurp($body_file));
    my ($context_msg) = grep {
             ($_->{role} // '') eq 'user'
          && ($_->{content} // '')
          =~ /Relevant file\/context state/
    } @{$body->{input}};

    ok($context_msg, "context fence: context message present");
    my $text = $context_msg->{content} // '';
    like(
        $text,
        qr/----- BEGIN FILE CONTEXT -----\n.*```perl\n.*AFTER_INNER_FENCE_MARK.*\n----- END FILE CONTEXT -----/s,
        "context fence: inner fences and trailing content sit inside the sentinels"
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

=head3 Test OpenAI legacy chat-completions response shape (choices)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"choices":[{"message":{"content":"LEGACY_CHOICES_REPLY"}}]}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello legacy shape\n", ",exit\n"]);

    like($results->{stdout}, qr/LEGACY_CHOICES_REPLY/,
        "openai legacy choices: extracts content from chat-completions shape"
    );
    is($results->{exit_code}, 0, "openai legacy choices: exits cleanly");
}

=head3 Test Anthropic legacy completion field fallback

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}        = "ANTHROPIC_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"completion":"COMPLETION_FALLBACK_REPLY"}';

    my $results = run_synergy_session(
        [",model claude-sonnet\n", "Hello completion fallback\n", ",exit\n"]);

    like($results->{stdout}, qr/COMPLETION_FALLBACK_REPLY/,
        "anthropic completion fallback: emits legacy completion field");
    is($results->{exit_code}, 0,
        "anthropic completion fallback: exits cleanly");
}

=head3 Test OpenAI response with no content reports parse failure

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}   = '{"output":[]}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello empty output\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/API call failed after 0 retries: OpenAI response missing content/s,
        "openai missing content: reports parse failure"
    );
    is($results->{exit_code}, 0, "openai missing content: exits cleanly");
}

=head3 Test Gemini response with no candidates reports parse failure

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{GEMINI_API_KEY}           = "GEMINI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}   = '{"candidates":[]}';

    my $results = run_synergy_session(
        [",model gemini-flash\n", "Hello empty candidates\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/API call failed after 0 retries: Gemini response missing content/s,
        "gemini missing content: reports parse failure"
    );
    is($results->{exit_code}, 0, "gemini missing content: exits cleanly");
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

=head3 Test Ctrl-C cancels an in-flight model request

While a curl child is running, SIGINT must cancel the request (kill
curl, no retries) and return control to the REPL rather than hanging
until the response arrives or asking about quitting.

=cut

SKIP: {
    skip 'signal delivery is unreliable on this platform', 5
      if $^O eq 'MSWin32';

    my $slow_dir = tempdir(CLEANUP => 1);
    open my $sfh, '>', "$slow_dir/curl" or die "Cannot create slow curl: $!";
    print {$sfh} "#!/bin/sh\nsleep 10\necho 200\n";
    close $sfh;
    chmod 0755, "$slow_dir/curl" or die "Cannot chmod slow curl: $!";

    local $ENV{PATH}                = "$slow_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}      = 'OPENAI_KEY_TEST';
    local $ENV{SYNERGY_MAX_RETRIES} = 0;

    require IPC::Open3;
    require Symbol;
    my $stderr_fh = Symbol::gensym();
    my $pid
      = IPC::Open3::open3(my $wtr, my $rdr, $stderr_fh, $^X, $SYNERGY_SCRIPT);

    print {$wtr} ",model gpt-5\n";
    print {$wtr} "this request will be canceled\n";
    print {$wtr} ",comment survived the cancel\n";
    print {$wtr} ",exit\n";
    close $wtr;

    sleep 2;    # let the turn reach the slow curl
    kill 'INT', $pid;

    my $stdout = do { local $/; <$rdr> };
    waitpid $pid, 0;
    my $exit_code = $?;

    like(
        $stdout,
        qr/\[request canceled by user\]/,
        'cancel: in-flight request reports cancellation'
    );
    like(
        $stdout,
        qr/survived the cancel/,
        'cancel: REPL keeps working after the cancellation'
    );
    unlike(
        $stdout,
        qr/API call failed after/,
        'cancel: not reported as a retried failure'
    );
    unlike(
        $stdout,
        qr/Do you really want to quit/,
        'cancel: mid-request Ctrl-C does not ask about quitting'
    );
    is($exit_code >> 8, 0, 'cancel: session exits cleanly');
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


=head3 Image upload: per-provider request shapes

A pushed image is stored as a placeholder and base64-encoded into
provider-specific blocks at request time; the base64 must round-trip
to the original file bytes.

=cut

# A valid 1x1 PNG, generated at runtime so no binary fixture lives in
# the repo.
my $PIXEL_PNG_B64
  = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
my $PIXEL_PNG_BYTES = decode_base64($PIXEL_PNG_B64);

sub write_pixel_png {
    my ($path) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    binmode $fh;
    print {$fh} $PIXEL_PNG_BYTES;
    close $fh;
    return $path;
}

sub image_session {
    my (%args)      = @_;
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = 'OPENAI_KEY_TEST';
    local $ENV{ANTHROPIC_API_KEY}        = 'ANTHROPIC_KEY_TEST';
    local $ENV{GEMINI_API_KEY}           = 'GEMINI_KEY_TEST';
    local $ENV{FIREWORKS_API_KEY}        = 'FIREWORKS_KEY_TEST';

    my $results     = run_synergy_session($args{input});
    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my $body        = $body_file ? decode_json(slurp($body_file)) : undef;
    return ($results, $body);
}

{
    my $png = write_pixel_png("$temp_dir/img_shape_openai_$$.png");
    my ($results, $body) = image_session(
        input => [
            ",model gpt-5\n",
            ",push $png\n",
            "describe the image\n",
            ",exit\n"
        ]
    );
    is($results->{exit_code}, 0, 'image openai: exits cleanly');
    my ($ctx) = grep { ref($_->{content}) eq 'ARRAY' } @{$body->{input}};
    ok($ctx, 'image openai: context message content is a block array');
    is($ctx->{content}[0]{type},
        'input_image', 'image openai: first block is input_image');
    like($ctx->{content}[0]{image_url},
        qr/^data:image\/png;base64,/,
        'image openai: data URL carries the png MIME type');
    my ($b64) = ($ctx->{content}[0]{image_url} // '') =~ /base64,(.*)\z/s;
    is(decode_base64($b64 // ''),
        $PIXEL_PNG_BYTES, 'image openai: base64 round-trips to file bytes');
    is($ctx->{content}[-1]{type},
        'input_text', 'image openai: text block is last');
    like(
        $ctx->{content}[-1]{text},
        qr/Relevant file\/context state/,
        'image openai: text block still carries the context container'
    );
}

{
    my $png = write_pixel_png("$temp_dir/img_shape_anthropic_$$.png");
    my ($results, $body) = image_session(
        input => [
            ",model claude-sonnet\n",
            ",push $png\n",
            "describe the image\n",
            ",exit\n"
        ]
    );
    is($results->{exit_code}, 0, 'image anthropic: exits cleanly');
    like($results->{stdout}, qr/OK_ANTHROPIC/,
        'image anthropic: reply parsed on the first attempt (no retry storm)'
    );
    my ($ctx)
      = grep { ref($_->{content}) eq 'ARRAY' && @{$_->{content}} > 1 }
      @{$body->{messages}};
    ok($ctx, 'image anthropic: context message has multiple blocks');
    is($ctx->{content}[0]{type},
        'image', 'image anthropic: first block is image');
    is($ctx->{content}[0]{source}{media_type},
        'image/png', 'image anthropic: media type set');
    is(decode_base64($ctx->{content}[0]{source}{data} // ''),
        $PIXEL_PNG_BYTES,
        'image anthropic: base64 round-trips to file bytes');
    ok(!exists $ctx->{content}[0]{cache_control},
        'image anthropic: image block carries no breakpoint');
    is($ctx->{content}[-1]{type},
        'text', 'image anthropic: text block is last');
    is_deeply(
        $ctx->{content}[-1]{cache_control},
        {type => 'ephemeral'},
        'image anthropic: breakpoint sits on the final text block, covering the images'
    );
}

{
    my $png = write_pixel_png("$temp_dir/img_shape_gemini_$$.png");
    my ($results, $body) = image_session(
        input => [
            ",model gemini-flash\n",
            ",push $png\n",
            "describe the image\n",
            ",exit\n"
        ]
    );
    is($results->{exit_code}, 0, 'image gemini: exits cleanly');
    my ($ctx) = grep { @{$_->{parts} // []} > 1 } @{$body->{contents}};
    ok($ctx, 'image gemini: content entry has multiple parts');
    is($ctx->{parts}[0]{inline_data}{mime_type},
        'image/png', 'image gemini: inline_data mime type set');
    is(decode_base64($ctx->{parts}[0]{inline_data}{data} // ''),
        $PIXEL_PNG_BYTES, 'image gemini: base64 round-trips to file bytes');
    like(
        $ctx->{parts}[-1]{text} // '',
        qr/Relevant file\/context state/,
        'image gemini: text part is last'
    );
}

{
    my $png = write_pixel_png("$temp_dir/img_shape_fireworks_$$.png");
    my ($results, $body)
      = image_session(input =>
          [",model glm\n", ",push $png\n", "describe the image\n", ",exit\n"]
      );
    is($results->{exit_code}, 0, 'image fireworks: exits cleanly');
    my ($ctx) = grep { ref($_->{content}) eq 'ARRAY' } @{$body->{messages}};
    ok($ctx, 'image fireworks: context message content is a block array');
    is($ctx->{content}[0]{type},
        'image_url', 'image fireworks: first block is image_url');
    my ($b64)
      = ($ctx->{content}[0]{image_url}{url} // '') =~ /base64,(.*)\z/s;
    is(decode_base64($b64 // ''),
        $PIXEL_PNG_BYTES,
        'image fireworks: base64 round-trips to file bytes');
    is($ctx->{content}[-1]{type},
        'text', 'image fireworks: text block is last');
}

=head3 Image upload: missing file degrades to a text placeholder

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = 'OPENAI_KEY_TEST';

    # Push and dump while the image exists; delete it; a fresh
    # session loading the dump must still complete the request.
    # This is also the dump/load placeholder round-trip test.
    my $dump_file = "$temp_dir/img_missing_dump_$$.xml";
    my $png       = write_pixel_png("$temp_dir/img_missing_$$.png");
    my $r1        = run_synergy_session(
        [",push $png\n", ",dump $dump_file\n", ",exit\n"]);
    is($r1->{exit_code}, 0, 'image missing: dump session exits cleanly');
    unlink $png;

    my $r2 = run_synergy_session(
        [",load $dump_file\n", "describe the image\n", ",exit\n"]);
    is($r2->{exit_code}, 0, 'image missing: request still succeeds');
    like(
        $r2->{stderr},
        qr/WARNING: image '\Q$png\E' unreadable, sending placeholder/,
        'image missing: warning names the path'
    );
    my $body
      = decode_json(slurp((sort glob("$capture_dir/req_*_body.json"))[-1]));
    my $all_text = join '', map {
        ref($_->{content}) eq 'ARRAY'
          ? join('', map { $_->{text} // '' } @{$_->{content}})
          : ($_->{content} // '')
    } @{$body->{input}};
    like(
        $all_text,
        qr/\[image '\Q$png\E' unavailable\]/,
        'image missing: placeholder line lands in the context text'
    );
}

=head3 Image upload: placeholder round-trips through dump/load intact

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = 'OPENAI_KEY_TEST';

    my $dump_file = "$temp_dir/img_roundtrip_dump_$$.xml";
    my $png       = write_pixel_png("$temp_dir/img_roundtrip_$$.png");
    my $r1        = run_synergy_session(
        [",push $png\n", ",dump $dump_file\n", ",exit\n"]);
    is($r1->{exit_code}, 0, 'image roundtrip: dump session exits cleanly');

    my $r2 = run_synergy_session(
        [",load $dump_file\n", "describe the image\n", ",exit\n"]);
    is($r2->{exit_code}, 0, 'image roundtrip: load session exits cleanly');

    my $body
      = decode_json(slurp((sort glob("$capture_dir/req_*_body.json"))[-1]));
    my ($ctx) = grep { ref($_->{content}) eq 'ARRAY' } @{$body->{input}};
    ok($ctx, 'image roundtrip: loaded placeholder produces image blocks');
    my ($b64) = ($ctx->{content}[0]{image_url} // '') =~ /base64,(.*)\z/s;
    is(decode_base64($b64 // ''),
        $PIXEL_PNG_BYTES,
        'image roundtrip: bytes identical after dump/load cycle');
}

=head3 Image upload: size guard and non-image regression

=cut

{
    local $ENV{SYNERGY_MAX_IMAGE_BYTES} = 10;
    my $png     = write_pixel_png("$temp_dir/img_toobig_$$.png");
    my $results = run_synergy_session([",push $png\n", ",s\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/ERROR: image '\Q$png\E' is \d+ bytes, over the 10-byte limit/,
        'image size guard: oversize push refused with limit message'
    );
    like($results->{stdout}, qr/\[ \]/,
        'image size guard: context stack stays empty');
}

{
    my $txt_file = "$temp_dir/not_an_image_$$.txt";
    open my $tfh, '>', $txt_file or die "cannot write $txt_file: $!";
    print {$tfh} "ordinary text content\n";
    close $tfh;

    my ($results, $body) = image_session(
        input => [
            ",model gpt-5\n",
            ",push $txt_file\n",
            "plain text probe\n",
            ",exit\n"
        ]
    );
    my ($ctx) = grep {
        !ref($_->{content})
          && ($_->{content} // '')
          =~ /Relevant file\/context state/
    } @{$body->{input}};
    ok($ctx,
        'non-image push: context message stays a plain string, no image blocks'
    );
    like(
        $ctx->{content},
        qr/file: '\Q$txt_file\E'/,
        'non-image push: .txt never gains the image placeholder'
    );
}

done_testing();

END {
    chdir $original_cwd;
}
