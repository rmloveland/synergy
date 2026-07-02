#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP;

my $has_cloc = `which cloc 2>/dev/null`;
if (!$has_cloc) {
    plan skip_all => 'cloc not installed';
}

my $json_out = `cloc synergy --json 2>/dev/null`;
if ($? != 0 || !$json_out) {
    plan skip_all => 'cloc failed to run or produced no output';
}

my $data = eval { decode_json($json_out) };
if (!$data || !exists $data->{SUM}{code}) {
    BAIL_OUT("Failed to parse cloc JSON output");
}

my $code_lines = $data->{SUM}{code};
ok($code_lines > 0, "Got code lines count: $code_lines");
cmp_ok($code_lines, '<=', 4000,
    "synergy has $code_lines non-comment lines (budget is 4000)");

done_testing();
