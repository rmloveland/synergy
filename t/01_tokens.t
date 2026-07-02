#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use File::Slurp qw(slurp);
use Synergy::Test::Runner
  qw(fresh_test_root run_synergy_session setup_test_env synergy_script write_stub);

setup_test_env(seed_api_keys => 1);

sub run_synergy {
    my (%args)    = @_;
    my $input     = $args{input} // '';
    my $stub_path = $args{stub_path};
    my $root      = $args{root} // fresh_test_root();

    my $result = run_synergy_session(
        [$input],
        synergy_script(),
        {
            SYNERGY_ROOT      => $root,
            SYNERGY_LOG_DIR   => "$root/var/log",
            SYNERGY_DUMP_DIR  => "$root/etc/dumps",
            SYNERGY_CURL_STUB => $stub_path,
        },
        ['SYNERGY_OFFLINE_RESPONSE'],
    );

    return {
        stdout => $result->{stdout},
        stderr => $result->{stderr},
        exit   => $result->{exit},
        root   => $root,
    };
}

subtest 'openai session totals accumulate across requests' => sub {
    my $stub_path
      = write_stub(
        '{"output_text":"stub openai","usage":{"input_tokens":12,"output_tokens":6,"total_tokens":18,"input_tokens_details":{"cached_tokens":5}}}'
      );

    my $result = run_synergy(
        stub_path => $stub_path,
        input     => ",model gpt-5\nhello\nhello again\n,tokens\n,exit\n",
    );

    is($result->{exit}, 0, 'openai run exits successfully')
      or diag($result->{stderr}, $result->{stdout});
    like(
        $result->{stdout},
        qr/tokens: input=24 output=12 total=36 cached=10 cache_hit_pct=41\.7%/,
        'openai totals are accumulated and reported'
    );
};

subtest 'anthropic usage contributes to session totals' => sub {
    my $stub_path
      = write_stub(
        '{"content":[{"type":"text","text":"stub anthropic"}],"usage":{"input_tokens":2095,"output_tokens":503,"cache_creation_input_tokens":2095,"cache_read_input_tokens":0}}'
      );

    my $result = run_synergy(
        stub_path => $stub_path,
        input     => ",model claude-haiku\nhello\n,tokens\n,exit\n",
    );

    is($result->{exit}, 0, 'anthropic run exits successfully')
      or diag($result->{stderr}, $result->{stdout});
    like(
        $result->{stdout},
        qr/tokens: input=2095 output=503 total=2598 cached=0 cache_hit_pct=0\.0%/,
        'anthropic totals are reported'
    );
};

subtest 'gemini usage metadata contributes to session totals' => sub {
    my $stub_path
      = write_stub(
        '{"candidates":[{"content":{"parts":[{"text":"stub gemini"}]}}],"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":311,"totalTokenCount":900,"cachedContentTokenCount":400,"thoughtsTokenCount":89,"toolUsePromptTokenCount":50}}'
      );

    my $result = run_synergy(
        stub_path => $stub_path,
        input     => ",model gemini-flash\nhello\n,tokens\n,exit\n",
    );

    is($result->{exit}, 0, 'gemini run exits successfully')
      or diag($result->{stderr}, $result->{stdout});
    like(
        $result->{stdout},
        qr/tokens: input=500 output=311 total=900 cached=400 cache_hit_pct=80\.0%/,
        'gemini totals are reported'
    );
};

subtest 'token totals persist across dump and load for new dumps' => sub {
    my $stub_path
      = write_stub(
        '{"output_text":"stub openai","usage":{"input_tokens":12,"output_tokens":6,"total_tokens":18,"input_tokens_details":{"cached_tokens":5}}}'
      );
    my $root      = fresh_test_root();
    my $dump_path = "$root/etc/dumps/tokens-roundtrip.xml";

    my $dump_result = run_synergy(
        root      => $root,
        stub_path => $stub_path,
        input     =>
          ",model gpt-5\nhello\nhello again\n,dump $dump_path\n,exit\n",
    );

    is($dump_result->{exit}, 0, 'dump run exits successfully')
      or diag($dump_result->{stderr}, $dump_result->{stdout});
    ok(-f $dump_path, 'dump run writes the dump file');

    my $dump_xml = slurp($dump_path);
    like(
        $dump_xml,
        qr/<tokens input="24" output="12" total="36" cached="10" \/>/,
        'dump file stores token totals'
    );

    my $load_result = run_synergy(
        root      => $root,
        stub_path => $stub_path,
        input     => ",load $dump_path\n,tokens\n,exit\n",
    );

    is($load_result->{exit}, 0, 'load run exits successfully')
      or diag($load_result->{stderr}, $load_result->{stdout});
    like(
        $load_result->{stdout},
        qr/Loading token totals.*ok/,
        'load restores token totals from dump'
    );
    like(
        $load_result->{stdout},
        qr/tokens: input=24 output=12 total=36 cached=10 cache_hit_pct=41\.7%/,
        'loaded dump restores session token totals'
    );
};

subtest 'old dumps without token totals still load and reset totals' => sub {
    my $stub_path
      = write_stub(
        '{"output_text":"stub openai","usage":{"input_tokens":12,"output_tokens":6,"total_tokens":18,"input_tokens_details":{"cached_tokens":5}}}'
      );
    my $fixture = 't/data/20250609-sqlchecker-use-random-database.xml';

    my $result = run_synergy(
        stub_path => $stub_path,
        input     => ",model gpt-5\nhello\n,load $fixture\n,tokens\n,exit\n",
    );

    is($result->{exit}, 0, 'old-dump load run exits successfully')
      or diag($result->{stderr}, $result->{stdout});
    like(
        $result->{stdout},
        qr/Loading dump file '\Q$fixture\E'/,
        'old dump loads successfully'
    );
    unlike(
        $result->{stdout},
        qr/Loading token totals.*ok/,
        'old dump does not claim to restore token totals'
    );
    like(
        $result->{stdout},
        qr/tokens: input=0 output=0 total=0 cached=0 cache_hit_pct=0\.0%/,
        'old dump resets token totals to zero'
    );
};

done_testing();
