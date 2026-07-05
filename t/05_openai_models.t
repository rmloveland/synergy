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

=head3 Test ,model command (display current)

=cut

{
    my $results = run_synergy_session([",model\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Model: 'gpt-5'/,
        "model: displays current model correctly"
    );
    is($results->{exit_code}, 0,
        "model: displays current model exits cleanly");
}

=head3 Test ,model command (switch to valid model)

=cut

{
    my $results
      = run_synergy_session([",model gemini-flash\n", ",model\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Switched model to 'gemini-flash'.*Model: 'gemini-flash'/s,
        "model: switches to gemini-flash and displays it correctly"
    );
    is($results->{exit_code}, 0,
        "model: switches to gemini-flash exits cleanly");
}

=head3 Test ,model command (switch to another valid model)

=cut

{
    my $results
      = run_synergy_session([",model gpt-5\n", ",model\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Switched model to 'gpt-5'.*Model: 'gpt-5'/s,
        "model: switches to gpt-5 and displays it correctly"
    );
    is($results->{exit_code}, 0, "model: switches to gpt-5 exits cleanly");
}

=head3 Test ,model command (switch to Anthropic Fable model)

=cut

{
    my $results
      = run_synergy_session([",model claude-fable\n", ",model\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/Switched model to 'claude-fable' \(`claude-fable-5`\).*Model: 'claude-fable'/s,
        "model: switches to claude-fable and displays it correctly"
    );
    is($results->{exit_code}, 0,
        "model: switches to claude-fable exits cleanly");
}

=head3 Test ,model command (switch to invalid model)

=cut

{
    my $results = run_synergy_session([",model foo\n", ",exit\n"]);
    like(
        $results->{stdout},
        qr/ERROR: Model shortname 'foo' not found./s,
        "model: displays error for non-existent model"
    );
    like(
        $results->{stdout},
        qr/\*? claude-sonnet/,
        "model: lists available models for invalid input (claude-sonnet)"
    );
    like(
        $results->{stdout},
        qr/\*? gemini-flash /,
        "model: lists available models for invalid input (gemini-flash)"
    );
    like($results->{stdout}, qr/\*? gpt-5 /,
        "model: lists available models for invalid input (gpt-5)");
    is($results->{exit_code}, 0, "model: invalid model input exits cleanly");
}

=head3 Test offline assistant response

=cut

{
    local $ENV{SYNERGY_OFFLINE_RESPONSE} = "OFFLINE_OK";
    my $results = run_synergy_session(["Hello offline\n", ",exit\n"]);
    like($results->{stdout}, qr/OFFLINE_OK/,
        "offline: returns configured offline response");
    is($results->{exit_code}, 0, "offline: exits cleanly");
}

=head3 Test curl stub response

=cut

{
    my $stub_file = "$temp_dir/curl_stub.json";
    open my $fh, '>', $stub_file or die "Cannot create stub file: $!";
    print $fh '{"output_text":"STUB_OK"}';
    close $fh;
    local $ENV{SYNERGY_CURL_STUB} = $stub_file;
    my $results = run_synergy_session(["Hello stub\n", ",exit\n"]);
    like($results->{stdout}, qr/STUB_OK/,
        "curl stub: uses stubbed response body");
    is($results->{exit_code}, 0, "curl stub: exits cleanly");
}

=head3 Test curl request generation (OpenAI)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";

    my $results
      = run_synergy_session([",model gpt-5\n", "Hello openai\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPENAI/,
        "curl openai: returns stub reply");
    is($results->{exit_code}, 0, "curl openai: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    my ($hdr_file)  = glob("$capture_dir/req_*_headers.txt");
    my ($url_file)  = glob("$capture_dir/req_*_url.txt");
    ok($body_file, "curl openai: captured body");
    ok($hdr_file,  "curl openai: captured headers");
    ok($url_file,  "curl openai: captured url");

    my $body = decode_json(slurp($body_file));
    is($body->{model}, "gpt-5.5-2026-04-23", "curl openai: model set");
    is($body->{input}[0]{role}, "system",    "curl openai: system role");
    is($body->{input}[1]{role}, "user",      "curl openai: user role");
    is($body->{reasoning}{effort},
        "medium",
        "curl openai: reasoning effort defaults to medium for chat");
    is($body->{prompt_cache_key},
        "synergy:gpt-5.5-2026-04-23",
        "curl openai: prompt_cache_key default set");

    my $headers = slurp($hdr_file);
    like(
        $headers,
        qr/Authorization: Bearer OPENAI_KEY_TEST/,
        "curl openai: auth header set"
    );
    like(
        $headers,
        qr/Content-Type: application\/json/,
        "curl openai: content-type header set"
    );

    my $url = slurp($url_file);
    like(
        $url,
        qr{https://api\.openai\.com/v1/responses},
        "curl openai: endpoint correct"
    );
}

=head3 Test curl request generation (OpenAI structured messages for history and context)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $context_file = "$temp_dir/openai_context_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print $cfh "OpenAI context line\n";
    close $cfh;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY_1}
      = '{"output":[{"content":[{"type":"output_text","text":"FIRST_OPENAI_REPLY"}]}]}';
    local $ENV{SYNERGY_CURL_FAKE_BODY_2}
      = '{"output":[{"content":[{"type":"output_text","text":"SECOND_OPENAI_REPLY"}]}]}';

    my $results = run_synergy_session(
        [
            ",model gpt-5\n",
            "First structured openai turn\n",
            ",push $context_file\n",
            "Second structured openai turn\n",
            ",exit\n",
        ]
    );

    like($results->{stdout}, qr/SECOND_OPENAI_REPLY/,
        "curl openai structured: returns second stub reply");
    is($results->{exit_code}, 0, "curl openai structured: exits cleanly");

    my @body_files = sort glob("$capture_dir/req_*_body.json");
    is(scalar(@body_files), 2,
        "curl openai structured: captured two request bodies");

    my $body = decode_json(slurp($body_files[1]));
    unlike(
        $body->{input}[0]{content},
        qr/Here is the history of the conversation to this point/,
        "curl openai structured: system prompt no longer embeds history block"
    );
    unlike(
        $body->{input}[0]{content},
        qr/Relevant file\/context state/,
        "curl openai structured: system prompt no longer embeds context block"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{content} // '')
                  =~ /First structured openai turn/
            } @{$body->{input}}
        ),
        "curl openai structured: prior user turn sent as user message"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'assistant'
                  && ($_->{content} // '')
                  =~ /FIRST_OPENAI_REPLY/
            } @{$body->{input}}
        ),
        "curl openai structured: prior assistant turn sent as assistant message"
    );
    ok(
        (
            grep {
                     ($_->{role} // '') eq 'user'
                  && ($_->{content} // '') =~ /Relevant file\/context state/
                  && ($_->{content} // '') =~ /\Q$context_file\E/
                  && ($_->{content} // '') =~ /OpenAI context line/
                  && !ref($_->{content})
                  && !exists $_->{cache_control}
                  && !exists $_->{synergy_cache_role}
            } @{$body->{input}}
        ),
        "curl openai structured: context sent as plain dedicated user message"
    );
    is($body->{prompt_cache_key},
        "synergy:gpt-5.5-2026-04-23",
        "curl openai structured: prompt_cache_key remains present");
    is($body->{input}[-1]{role},
        "user",
        "curl openai structured: current turn remains final user message");
    is(
        $body->{input}[-1]{content},
        "Second structured openai turn\n",
        "curl openai structured: current turn content preserved exactly"
    );
    unlike($body->{input}[-1]{content}, qr/\\[bnrtf]/,
        "curl openai structured: current turn no longer contains escape artifacts"
    );
}

=head3 Test OpenAI cached tokens logging and UX output

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $log_dir = $ENV{SYNERGY_LOG_DIR} // "$synergy_root/var/log";
    my %before  = map { $_ => 1 } glob("$log_dir/chats-*.txt");
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"output":[{"content":[{"type":"output_text","text":"OK_OPENAI"}]}],"usage":{"input_tokens":2006,"input_tokens_details":{"cached_tokens":123}}}';

    my $results = run_synergy_file_session(
        [",model gpt-5\n", "Hello cache tokens\n", ",exit\n"]);

    like($results->{stdout}, qr/cached_tokens=123/,
        "openai cached tokens: UX includes cached token count");
    like($results->{stdout}, qr/cache_hit_pct=6\.1%/,
        "openai cached tokens: UX includes cache hit percentage");
    is($results->{exit_code}, 0, "openai cached tokens: exits cleanly");

    my @after = glob("$log_dir/chats-*.txt");
    my @new   = grep { !$before{$_} } @after;
    ok(@new == 1, "openai cached tokens: one new log file created")
      or diag("log_dir=$log_dir after=@after");

    my $log = slurp($new[0]);
    like(
        $log,
        qr/cached_tokens: 123/,
        "openai cached tokens: log file includes cached token count"
    );
    like(
        $log,
        qr/prompt_tokens: 2006/,
        "openai cached tokens: log file includes prompt token count"
    );
    like(
        $log,
        qr/cache_hit_pct: 6\.1%/,
        "openai cached tokens: log file includes cache hit percentage"
    );
}

=head3 Test curl request generation (OpenAI prompt cache retention)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR}              = $capture_dir;
    local $ENV{SYNERGY_OPENAI_PROMPT_CACHE_RETENTION} = "24h";
    local $ENV{PATH}           = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY} = "OPENAI_KEY_TEST";

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello retention\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPENAI/,
        "curl openai retention: returns stub reply");
    is($results->{exit_code}, 0, "curl openai retention: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "curl openai retention: captured body");

    my $body = decode_json(slurp($body_file));
    is($body->{prompt_cache_retention},
        "24h", "curl openai retention: prompt_cache_retention set from env");
}

=head3 Test OpenAI output_text convenience parsing

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"output_text":"OK_OPENAI_DIRECT","usage":{"input_tokens":100}}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello output_text\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPENAI_DIRECT/,
        "openai output_text: convenience field parsed");
    is($results->{exit_code}, 0, "openai output_text: exits cleanly");
}

=head3 Test OpenAI legacy choices fallback parsing

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}
      = '{"choices":[{"message":{"content":"OK_OPENAI_LEGACY"}}],"usage":{"prompt_tokens":42}}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello legacy choices\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPENAI_LEGACY/,
        "openai legacy choices: fallback parsing works");
    is($results->{exit_code}, 0, "openai legacy choices: exits cleanly");
}

=head3 Test OpenAI malformed output structure handling

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY} = '{"output":{"unexpected":"shape"}}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello malformed output\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/OpenAI response malformed: expected 'output' to be array/s,
        "openai malformed output: reports specific shape error"
    );
    is($results->{exit_code}, 0, "openai malformed output: exits cleanly");
}

=head3 Test OpenAI missing content error path

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_MAX_RETRIES}      = 0;
    local $ENV{SYNERGY_CURL_CAPTURE_DIR} = $capture_dir;
    local $ENV{PATH}                     = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}           = "OPENAI_KEY_TEST";
    local $ENV{SYNERGY_CURL_FAKE_BODY}   = '{"usage":{"input_tokens":5}}';

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello missing content\n", ",exit\n"]);

    like(
        $results->{stdout},
        qr/OpenAI response missing content/s,
        "openai missing content: reports parse safety-net error"
    );
    is($results->{exit_code}, 0, "openai missing content: exits cleanly");
}

=head3 Test curl request generation (OpenAI reasoning effort override)

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);
    local $ENV{SYNERGY_CURL_CAPTURE_DIR}        = $capture_dir;
    local $ENV{SYNERGY_OPENAI_REASONING_EFFORT} = "low";
    local $ENV{PATH}                            = "$curl_dir:$ENV{PATH}";
    local $ENV{OPENAI_API_KEY}                  = "OPENAI_KEY_TEST";

    my $results = run_synergy_session(
        [",model gpt-5\n", "Hello reasoning override\n", ",exit\n"]);

    like($results->{stdout}, qr/OK_OPENAI/,
        "curl openai reasoning override: returns stub reply");
    is($results->{exit_code}, 0,
        "curl openai reasoning override: exits cleanly");

    my ($body_file) = glob("$capture_dir/req_*_body.json");
    ok($body_file, "curl openai reasoning override: captured body");

    my $body = decode_json(slurp($body_file));
    is($body->{reasoning}{effort},
        "low", "curl openai reasoning override: effort set from env");
}


done_testing();

END {
    chdir $original_cwd;
}
