#!/usr/bin/env perl

use strict;
use warnings;

use lib 't/lib';
use File::Slurp qw(slurp);
use File::Temp  qw(tempdir);
use JSON::PP    qw(decode_json);
use Test::More;

use Synergy::Test::Cache::Anthropic;
use Synergy::Test::Cache::Gemini;
use Synergy::Test::Cache::OpenAI;
use Synergy::Test::Runner
  qw(run_synergy_session setup_test_env write_fake_curl);

my $temp_dir = tempdir(CLEANUP => 1);
setup_test_env(
    log_dir       => $temp_dir,
    dump_dir      => $temp_dir,
    seed_api_keys => 1,
);

sub anthropic_body {
    my (%args) = @_;

    return {
        model      => 'claude-sonnet-4-6',
        max_tokens => 8192,
        system     => [
            {
                type          => 'text',
                text          => $args{system} // 'stable system prompt',
                cache_control => $args{cache_control}
                  // {type => 'ephemeral'},
            }
        ],
        messages => [
            {
                role    => 'user',
                content => $args{message} // 'volatile user message',
            }
        ],
    };
}

sub anthropic_context_body {
    my (%args) = @_;

    my @messages;
    push @messages, {role => 'user', content => $args{pre_context}}
      if defined $args{pre_context};
    push @messages,
      {
        role    => 'user',
        content => [
            {
                type          => 'text',
                text          => $args{context} // 'stable context block',
                cache_control => {type => 'ephemeral'},
            }
        ],
      };
    push @messages,
      {role => 'user', content => $args{message} // 'volatile user message'};

    return {
        model      => 'claude-sonnet-4-6',
        max_tokens => 8192,
        system     => [{type => 'text', text => 'uncached system prompt',}],
        messages   => \@messages,
    };
}

sub cache_read_pct {
    my ($result) = @_;
    my $usage    = $result->{usage};
    my $read     = $usage->{cache_read_input_tokens}     // 0;
    my $made     = $usage->{cache_creation_input_tokens} // 0;
    my $base     = $read + $made;
    return 0 if !$base;
    return ($read / $base) * 100;
}

sub openai_body {
    my (%args) = @_;

    my $stable = $args{stable} // ('stable OpenAI prefix ' x 300);
    return {
        model            => 'gpt-5.5-2026-04-23',
        prompt_cache_key => $args{prompt_cache_key} // 'synergy:gpt-test',
        input            => [
            {role => 'system', content => $stable,},
            {
                role    => 'user',
                content => $args{message} // 'volatile user request',
            }
        ],
        reasoning => {effort => 'medium'},
        (
            exists $args{prompt_cache_retention}
            ? (prompt_cache_retention => $args{prompt_cache_retention})
            : ()
        ),
    };
}

sub openai_cache_read_pct {
    my ($result) = @_;
    my $read     = $result->{cache}{read_tokens}    // 0;
    my $made     = $result->{cache}{created_tokens} // 0;
    my $base     = $read + $made;
    return 0 if !$base;
    return ($read / $base) * 100;
}

sub gemini_body {
    my (%args) = @_;

    my $stable = $args{stable} // ('stable Gemini prefix ' x 300);
    return {
        contents => [
            {role => 'user', parts => [{text => $stable}],},
            {
                role  => 'user',
                parts =>
                  [{text => $args{message} // 'volatile Gemini request'}],
            }
        ],
        generationConfig => {maxOutputTokens => 8192},
    };
}

sub gemini_cache_read_pct {
    my ($result) = @_;
    my $read     = $result->{cache}{read_tokens}    // 0;
    my $made     = $result->{cache}{created_tokens} // 0;
    my $base     = $read + $made;
    return 0 if !$base;
    return ($read / $base) * 100;
}

=head3 Test Gemini helper models implicit stable-prefix cache reuse

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::Gemini->new(
        store_dir => $store,
        model     => 'gemini-3.5-flash',
    );

    my $first
      = $cache->evaluate_request(gemini_body(message => 'question one'));
    ok($first->{ok}, 'gemini cache contract: first request is valid')
      or diag join("\n", @{$first->{errors}});
    ok($first->{cache}{cacheable_prefix},
        'gemini cache contract: first request has cacheable prefix');
    is($first->{usage}{cachedContentTokenCount},
        0, 'gemini cache contract: first request has no cache read');

    my $second
      = $cache->evaluate_request(gemini_body(message => 'question two'));
    ok($second->{ok}, 'gemini cache contract: changed suffix is valid')
      or diag join("\n", @{$second->{errors}});
    ok($second->{cache}{hit},
        'gemini cache contract: changed suffix hits stable prefix');
    ok($second->{usage}{cachedContentTokenCount} > 0,
        'gemini cache contract: changed suffix reports cached tokens');
    cmp_ok(gemini_cache_read_pct($second),
        '>=', 80,
        'gemini cache contract: stable prefix read percentage is high');
}

=head3 Test Gemini helper models model-specific cache thresholds

=cut

{
    my $body = gemini_body(stable => ('pro threshold prefix ' x 300));

    my $flash
      = Synergy::Test::Cache::Gemini->new(model => 'gemini-3.5-flash');
    my $flash_result = $flash->evaluate_request($body);
    ok($flash_result->{cache}{cacheable_prefix},
        'gemini cache contract: Flash threshold accepts medium prefix');

    my $pro
      = Synergy::Test::Cache::Gemini->new(model => 'gemini-3-pro-preview');
    my $pro_result = $pro->evaluate_request($body);
    ok(!$pro_result->{cache}{cacheable_prefix},
        'gemini cache contract: Pro threshold rejects same medium prefix');
    like(
        join("\n", @{$pro_result->{warnings}}),
        qr/no prefix reached the model cache eligibility threshold/,
        'gemini cache contract: Pro threshold warning is diagnostic'
    );
}

=head3 Test Gemini helper validates provider isolation contracts

=cut

{
    my $cache = Synergy::Test::Cache::Gemini->new();

    my $missing_contents = gemini_body();
    delete $missing_contents->{contents};
    my $missing_result = $cache->evaluate_request($missing_contents);
    ok(!$missing_result->{ok},
        'gemini cache contract: missing contents is rejected');
    like(
        join("\n", @{$missing_result->{errors}}),
        qr/contents must be an array/,
        'gemini cache contract: missing contents error is diagnostic'
    );

    my $anthropic_field = gemini_body();
    $anthropic_field->{contents}[0]{cache_control} = {type => 'ephemeral'};
    my $anthropic_result = $cache->evaluate_request($anthropic_field);
    ok(!$anthropic_result->{ok},
        'gemini cache contract: Anthropic cache_control is rejected');
    like(
        join("\n", @{$anthropic_result->{errors}}),
        qr/cache_control is Anthropic-only/,
        'gemini cache contract: Anthropic field error is diagnostic'
    );

    my $openai_field = gemini_body();
    $openai_field->{prompt_cache_key} = 'synergy:bad';
    my $openai_result = $cache->evaluate_request($openai_field);
    ok(!$openai_result->{ok},
        'gemini cache contract: OpenAI prompt_cache_key is rejected');
    like(
        join("\n", @{$openai_result->{errors}}),
        qr/prompt_cache_key is OpenAI-only/,
        'gemini cache contract: OpenAI field error is diagnostic'
    );
}

=head3 Test fake curl can return modeled Gemini cache usage

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $cache_dir   = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $context_file = "$temp_dir/gemini_cache_context_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print {$cfh} 'stable Gemini file context ' x 400;
    close $cfh;

    my %env = (
        SYNERGY_CURL_CAPTURE_DIR         => $capture_dir,
        SYNERGY_CURL_FAKE_CACHE_PROVIDER => 'gemini',
        SYNERGY_CURL_FAKE_CACHE_STORE    => $cache_dir,
        PATH                             => "$curl_dir:$ENV{PATH}",
        GEMINI_API_KEY                   => 'GEMINI_KEY_TEST',
    );

    my $first = run_synergy_session(
        [
            ",model gemini-flash\n",
            ",push $context_file\n",
            "first Gemini cache contract turn\n",
            ",exit\n"
        ],
        undef,
        \%env
    );
    like($first->{stdout}, qr/OK_GEMINI_CACHE/,
        'gemini fake curl cache: first request returns modeled response');
    is($first->{exit_code}, 0,
        'gemini fake curl cache: first session exits cleanly');

    my $second = run_synergy_session(
        [
            ",model gemini-flash\n",
            ",push $context_file\n",
            "second Gemini cache contract turn\n",
            ",tokens\n", ",exit\n"
        ],
        undef,
        \%env
    );

    like($second->{stdout}, qr/OK_GEMINI_CACHE/,
        'gemini fake curl cache: second request returns modeled response');
    like($second->{stdout}, qr/\bcached=\d+/,
        'gemini fake curl cache: token output includes cached count');
    unlike($second->{stdout}, qr/\bcached=0\b/,
        'gemini fake curl cache: second request reads cached tokens');
    is($second->{exit_code}, 0,
        'gemini fake curl cache: second session exits cleanly');

    my @bodies = sort glob("$capture_dir/req_*_body.json");
    is(scalar @bodies,
        2, 'gemini fake curl cache: captures both request bodies');

    my $second_body = decode_json(slurp($bodies[1]));
    ok(!_contains_cache_control($second_body),
        'gemini fake curl cache: generated request has no cache_control');
    ok(!_contains_prompt_cache_key($second_body),
        'gemini fake curl cache: generated request has no prompt_cache_key');
}

sub _contains_prompt_cache_key {
    my ($value) = @_;
    if (ref($value) eq 'HASH') {
        return 1 if exists $value->{prompt_cache_key};
        for my $child (values %$value) {
            return 1 if _contains_prompt_cache_key($child);
        }
    }
    elsif (ref($value) eq 'ARRAY') {
        for my $child (@$value) {
            return 1 if _contains_prompt_cache_key($child);
        }
    }
    return 0;
}

=head3 Test OpenAI helper models stable-prefix cache reuse

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::OpenAI->new(store_dir => $store);

    my $first
      = $cache->evaluate_request(openai_body(message => 'question one'));
    ok($first->{ok}, 'openai cache contract: first request is valid')
      or diag join("\n", @{$first->{errors}});
    ok($first->{cache}{created},
        'openai cache contract: first request creates cache entry');
    is($first->{usage}{input_tokens_details}{cached_tokens},
        0, 'openai cache contract: first request has no cache read');

    my $second
      = $cache->evaluate_request(openai_body(message => 'question two'));
    ok($second->{ok}, 'openai cache contract: changed suffix is valid')
      or diag join("\n", @{$second->{errors}});
    ok($second->{cache}{hit},
        'openai cache contract: changed suffix hits stable prefix');
    ok(
        $second->{usage}{input_tokens_details}{cached_tokens} > 0,
        'openai cache contract: changed suffix reports cached tokens'
    );
    cmp_ok(openai_cache_read_pct($second),
        '>=', 80,
        'openai cache contract: stable prefix read percentage is high');
}

=head3 Test OpenAI helper scopes cache by prompt_cache_key

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::OpenAI->new(store_dir => $store);

    my $first = $cache->evaluate_request(
        openai_body(prompt_cache_key => 'synergy:key-one'));
    ok($first->{ok}, 'openai cache contract: first key request is valid')
      or diag join("\n", @{$first->{errors}});

    my $second = $cache->evaluate_request(
        openai_body(prompt_cache_key => 'synergy:key-two'));
    ok($second->{ok}, 'openai cache contract: second key request is valid')
      or diag join("\n", @{$second->{errors}});
    ok(!$second->{cache}{hit},
        'openai cache contract: changed prompt_cache_key misses cache');
    is($second->{usage}{input_tokens_details}{cached_tokens},
        0, 'openai cache contract: changed key has no cache read');
}

=head3 Test OpenAI helper validates request contracts

=cut

{
    my $cache = Synergy::Test::Cache::OpenAI->new();

    my $missing_key = openai_body();
    delete $missing_key->{prompt_cache_key};
    my $missing_key_result = $cache->evaluate_request($missing_key);
    ok(!$missing_key_result->{ok},
        'openai cache contract: missing prompt_cache_key is rejected');
    like(
        join("\n", @{$missing_key_result->{errors}}),
        qr/prompt_cache_key missing/,
        'openai cache contract: missing key error is diagnostic'
    );

    my $bad_retention = openai_body(prompt_cache_retention => 'forever');
    my $bad_retention_result = $cache->evaluate_request($bad_retention);
    ok(!$bad_retention_result->{ok},
        'openai cache contract: invalid retention is rejected');
    like(
        join("\n", @{$bad_retention_result->{errors}}),
        qr/prompt_cache_retention must be in_memory or 24h/,
        'openai cache contract: retention error is diagnostic'
    );

    my $anthropic_field = openai_body();
    $anthropic_field->{input}[0]{cache_control} = {type => 'ephemeral'};
    my $anthropic_field_result = $cache->evaluate_request($anthropic_field);
    ok(!$anthropic_field_result->{ok},
        'openai cache contract: Anthropic cache_control is rejected');
    like(
        join("\n", @{$anthropic_field_result->{errors}}),
        qr/cache_control is Anthropic-only/,
        'openai cache contract: provider isolation error is diagnostic'
    );
}

=head3 Test fake curl can return modeled OpenAI cache usage

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $cache_dir   = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    my $context_file = "$temp_dir/openai_cache_context_$$.txt";
    open my $cfh, '>', $context_file or die "Cannot create $context_file: $!";
    print {$cfh} 'stable OpenAI file context ' x 400;
    close $cfh;

    my %env = (
        SYNERGY_CURL_CAPTURE_DIR         => $capture_dir,
        SYNERGY_CURL_FAKE_CACHE_PROVIDER => 'openai',
        SYNERGY_CURL_FAKE_CACHE_STORE    => $cache_dir,
        PATH                             => "$curl_dir:$ENV{PATH}",
        OPENAI_API_KEY                   => 'OPENAI_KEY_TEST',
    );

    my $first = run_synergy_session(
        [
            ",model gpt-5\n",
            ",push $context_file\n",
            "first OpenAI cache contract turn\n",
            ",exit\n"
        ],
        undef,
        \%env
    );
    like($first->{stdout}, qr/OK_OPENAI_CACHE/,
        'openai fake curl cache: first request returns modeled response');
    is($first->{exit_code}, 0,
        'openai fake curl cache: first session exits cleanly');

    my $second = run_synergy_session(
        [
            ",model gpt-5\n",
            ",push $context_file\n",
            "second OpenAI cache contract turn\n",
            ",tokens\n", ",exit\n"
        ],
        undef,
        \%env
    );

    like($second->{stdout}, qr/OK_OPENAI_CACHE/,
        'openai fake curl cache: second request returns modeled response');
    like($second->{stdout}, qr/\bcached=\d+/,
        'openai fake curl cache: token output includes cached count');
    unlike($second->{stdout}, qr/\bcached=0\b/,
        'openai fake curl cache: second request reads cached tokens');
    is($second->{exit_code}, 0,
        'openai fake curl cache: second session exits cleanly');

    my @bodies = sort glob("$capture_dir/req_*_body.json");
    is(scalar @bodies,
        2, 'openai fake curl cache: captures both request bodies');

    my $second_body = decode_json(slurp($bodies[1]));
    is($second_body->{prompt_cache_key},
        'synergy:gpt-5.5-2026-04-23',
        'openai fake curl cache: generated request has default cache key');
    ok(!_contains_cache_control($second_body),
        'openai fake curl cache: generated request has no cache_control');
}

sub _contains_cache_control {
    my ($value) = @_;
    if (ref($value) eq 'HASH') {
        return 1 if exists $value->{cache_control};
        for my $child (values %$value) {
            return 1 if _contains_cache_control($child);
        }
    }
    elsif (ref($value) eq 'ARRAY') {
        for my $child (@$value) {
            return 1 if _contains_cache_control($child);
        }
    }
    return 0;
}

=head3 Test Anthropic helper models context breakpoint cache reuse

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::Anthropic->new(store_dir => $store);

    my $first = $cache->evaluate_request(
        anthropic_context_body(message => 'question one'));
    ok($first->{ok}, 'anthropic cache contract: context request is valid')
      or diag join("\n", @{$first->{errors}});
    ok($first->{usage}{cache_creation_input_tokens} > 0,
        'anthropic cache contract: context request creates cache tokens');

    my $second = $cache->evaluate_request(
        anthropic_context_body(message => 'question two'));
    ok($second->{ok},
        'anthropic cache contract: changed post-context suffix is valid')
      or diag join("\n", @{$second->{errors}});
    ok($second->{cache}{hit},
        'anthropic cache contract: changed post-context suffix hits cache');
    cmp_ok(cache_read_pct($second), '>=', 80,
        'anthropic cache contract: context prefix read percentage is high');
}

=head3 Test Anthropic helper misses when volatile content precedes context

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::Anthropic->new(store_dir => $store);

    my $first = $cache->evaluate_request(
        anthropic_context_body(pre_context => 'history one'));
    ok($first->{ok},
        'anthropic cache contract: volatile-prefix request is valid')
      or diag join("\n", @{$first->{errors}});

    my $second = $cache->evaluate_request(
        anthropic_context_body(pre_context => 'history two'));
    ok($second->{ok},
        'anthropic cache contract: changed volatile prefix is valid')
      or diag join("\n", @{$second->{errors}});
    ok(!$second->{cache}{hit},
        'anthropic cache contract: changed volatile prefix misses cache');
    is($second->{usage}{cache_read_input_tokens},
        0, 'anthropic cache contract: volatile prefix has no cache read');
}

=head3 Test Anthropic helper models stable-prefix cache reuse

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::Anthropic->new(store_dir => $store);

    my $first
      = $cache->evaluate_request(anthropic_body(message => 'question one'));
    ok($first->{ok}, 'anthropic cache contract: first request is valid')
      or diag join("\n", @{$first->{errors}});
    ok($first->{usage}{cache_creation_input_tokens} > 0,
        'anthropic cache contract: first request creates cache tokens');
    is($first->{usage}{cache_read_input_tokens},
        0, 'anthropic cache contract: first request has no cache read');

    my $second
      = $cache->evaluate_request(anthropic_body(message => 'question two'));
    ok($second->{ok}, 'anthropic cache contract: changed suffix is valid')
      or diag join("\n", @{$second->{errors}});
    ok($second->{cache}{hit},
        'anthropic cache contract: changed suffix hits stable prefix');
    ok($second->{usage}{cache_read_input_tokens} > 0,
        'anthropic cache contract: changed suffix reads cache tokens');
    cmp_ok(cache_read_pct($second), '>=', 80,
        'anthropic cache contract: stable prefix read percentage is high');
}

=head3 Test Anthropic helper misses when content before breakpoint changes

=cut

{
    my $store = tempdir(CLEANUP => 1);
    my $cache = Synergy::Test::Cache::Anthropic->new(store_dir => $store);

    my $first = $cache->evaluate_request(
        anthropic_body(system => 'stable system prompt v1'));
    ok($first->{ok}, 'anthropic cache contract: initial prefix is valid')
      or diag join("\n", @{$first->{errors}});

    my $second = $cache->evaluate_request(
        anthropic_body(system => 'stable system prompt v2'));
    ok($second->{ok}, 'anthropic cache contract: changed prefix is valid')
      or diag join("\n", @{$second->{errors}});
    ok(!$second->{cache}{hit},
        'anthropic cache contract: changed prefix misses cache');
    ok($second->{usage}{cache_creation_input_tokens} > 0,
        'anthropic cache contract: changed prefix creates new cache entry');
    is($second->{usage}{cache_read_input_tokens},
        0, 'anthropic cache contract: changed prefix has no cache read');
}

=head3 Test Anthropic helper validates breakpoint contracts

=cut

{
    my $cache = Synergy::Test::Cache::Anthropic->new();

    my $bad_root = anthropic_body();
    $bad_root->{cache_control} = {type => 'ephemeral'};
    my $root_result = $cache->evaluate_request($bad_root);
    ok(!$root_result->{ok},
        'anthropic cache contract: root cache_control is rejected');
    like(
        join("\n", @{$root_result->{errors}}),
        qr/cache_control found at request root/,
        'anthropic cache contract: root error is diagnostic'
    );

    my $bad_ttl
      = anthropic_body(cache_control => {type => 'ephemeral', ttl => '5m'});
    my $ttl_result = $cache->evaluate_request($bad_ttl);
    ok(!$ttl_result->{ok},
        'anthropic cache contract: unsupported Synergy TTL is rejected');
    like(
        join("\n", @{$ttl_result->{errors}}),
        qr/cache_control\.ttl must be 1h/,
        'anthropic cache contract: TTL error is diagnostic'
    );

    my $too_many = anthropic_body();
    $too_many->{messages} = [
        map {
            {
                role    => 'user',
                content => [
                    {
                        type          => 'text',
                        text          => "stable block $_",
                        cache_control => {type => 'ephemeral'},
                    }
                ],
            }
        } 1 .. 5
    ];
    my $limit_result = $cache->evaluate_request($too_many);
    ok(!$limit_result->{ok},
        'anthropic cache contract: breakpoint limit is enforced');
    like(
        join("\n", @{$limit_result->{errors}}),
        qr/6 explicit breakpoints found; maximum is 4/,
        'anthropic cache contract: breakpoint limit error is diagnostic'
    );
}

=head3 Test fake curl can return modeled Anthropic cache usage

=cut

{
    my $capture_dir = tempdir(CLEANUP => 1);
    my $cache_dir   = tempdir(CLEANUP => 1);
    my $curl_dir    = tempdir(CLEANUP => 1);
    write_fake_curl($curl_dir);

    local $ENV{SYNERGY_CURL_CAPTURE_DIR}         = $capture_dir;
    local $ENV{SYNERGY_CURL_FAKE_CACHE_PROVIDER} = 'anthropic';
    local $ENV{SYNERGY_CURL_FAKE_CACHE_STORE}    = $cache_dir;
    local $ENV{PATH}                             = "$curl_dir:$ENV{PATH}";
    local $ENV{ANTHROPIC_API_KEY}                = 'ANTHROPIC_KEY_TEST';

    my $results = run_synergy_session(
        [
            ",model claude-sonnet\n",
            "first cache contract turn\n",
            "second cache contract turn\n",
            ",tokens\n",
            ",exit\n"
        ]
    );

    like($results->{stdout}, qr/OK_ANTHROPIC_CACHE/,
        'anthropic fake curl cache: returns modeled response');
    like($results->{stdout}, qr/cached=\d+/,
        'anthropic fake curl cache: token output includes cached count');
    is($results->{exit_code}, 0,
        'anthropic fake curl cache: session exits cleanly');

    my @bodies = glob("$capture_dir/req_*_body.json");
    is(scalar @bodies,
        2, 'anthropic fake curl cache: captures both request bodies');

    my $second = decode_json(slurp($bodies[1]));
    ok(
        !exists $second->{cache_control},
        'anthropic fake curl cache: generated request has no root cache_control'
    );
    is_deeply(
        $second->{system}[0]{cache_control},
        {type => 'ephemeral'},
        'anthropic fake curl cache: generated request keeps system breakpoint'
    );
}

done_testing();
