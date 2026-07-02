package Synergy::Test::Cache::OpenAI;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);

sub new {
    my ($class, %args) = @_;
    my $self = {
        store_dir  => $args{store_dir},
        min_tokens => defined($args{min_tokens}) ? $args{min_tokens} : 1024,
        json       => JSON::PP->new->canonical->allow_nonref,
    };
    make_path($self->{store_dir}) if defined $self->{store_dir};
    return bless $self, $class;
}

sub evaluate_request {
    my ($self, $body) = @_;

    my @errors;
    my @warnings;

    if (ref($body) ne 'HASH') {
        return $self->_result(
            errors => [
                'OpenAI cache contract violation: request body is not an object'
            ],
        );
    }

    push @errors, 'OpenAI cache contract violation: prompt_cache_key missing'
      unless defined($body->{prompt_cache_key})
      && length($body->{prompt_cache_key});

    if (exists $body->{prompt_cache_retention}) {
        my $retention = $body->{prompt_cache_retention} // '';
        push @errors,
          'OpenAI cache contract violation: prompt_cache_retention must be in_memory or 24h'
          unless $retention =~ /^(?:in_memory|24h)$/;
    }

    push @errors,
      'OpenAI cache contract violation: cache_control is Anthropic-only'
      if _contains_key($body, 'cache_control');

    push @errors, 'OpenAI cache contract violation: input must be an array'
      unless ref($body->{input}) eq 'ARRAY';

    my @prefixes
      = ref($body->{input}) eq 'ARRAY'
      ? $self->_cacheable_prefixes($body)
      : ();

    my $last_prefix = @prefixes ? $prefixes[-1] : undef;
    my $hit_prefix;
    if (defined $self->{store_dir}) {
        for my $prefix (@prefixes) {
            my $path = File::Spec->catfile($self->{store_dir},
                _safe_key($prefix->{key}));
            $hit_prefix = $prefix if -e $path;
        }

        for my $prefix (@prefixes) {
            my $path = File::Spec->catfile($self->{store_dir},
                _safe_key($prefix->{key}));
            next if -e $path;
            open my $fh, '>', $path
              or die "OpenAI fake cache write failed: $!";
            print {$fh} $prefix->{json};
            close $fh;
        }
    }

    push @warnings,
      'OpenAI cache contract warning: no prefix reached the 1024 token cache eligibility threshold'
      if !@prefixes;

    my $prompt_tokens
      = _estimate_tokens(length($self->{json}->encode($body)));
    my $read_tokens = $hit_prefix ? $hit_prefix->{tokens} : 0;
    my $created_tokens
      = $last_prefix ? $last_prefix->{tokens} - $read_tokens : 0;
    $created_tokens = 0 if $created_tokens < 0;

    return $self->_result(
        errors   => \@errors,
        warnings => \@warnings,
        usage    => {
            input_tokens          => $prompt_tokens,
            output_tokens         => 100,
            input_tokens_details  => {cached_tokens => $read_tokens},
            prompt_tokens_details => {cached_tokens => $read_tokens},
        },
        cache => {
            provider         => 'openai',
            key              => $last_prefix ? $last_prefix->{key}   : undef,
            prefix_chars     => $last_prefix ? $last_prefix->{chars} : 0,
            hit              => $hit_prefix  ? 1                     : 0,
            created          => $created_tokens > 0 ? 1              : 0,
            read_tokens      => $read_tokens,
            created_tokens   => $created_tokens,
            prompt_cache_key => $body->{prompt_cache_key},
        },
    );
}

sub fake_response_json {
    my ($self, $body_json) = @_;

    my $body   = decode_json($body_json);
    my $result = $self->evaluate_request($body);

    die join("\n", @{$result->{errors}}) . "\n" unless $result->{ok};

    return encode_json(
        {
            output => [
                {
                    content =>
                      [{type => 'output_text', text => 'OK_OPENAI_CACHE',}],
                }
            ],
            usage => $result->{usage},
        }
    );
}

sub _cacheable_prefixes {
    my ($self, $body) = @_;

    my @prefixes;
    my @prefix_input;
    for my $item (@{$body->{input}}) {
        push @prefix_input, $item;
        my $prefix_body = {
            model            => $body->{model},
            prompt_cache_key => $body->{prompt_cache_key},
            input            => [@prefix_input],
        };
        $prefix_body->{tools} = $body->{tools} if exists $body->{tools};
        if (exists $body->{prompt_cache_retention}) {
            $prefix_body->{prompt_cache_retention}
              = $body->{prompt_cache_retention};
        }

        my $json   = $self->{json}->encode($prefix_body);
        my $tokens = _estimate_tokens(length($json));
        next if $tokens < $self->{min_tokens};

        push @prefixes,
          {
            json   => $json,
            chars  => length($json),
            tokens => $tokens,
            key    => 'sha256:' . sha256_hex($json),
          };
    }

    return @prefixes;
}

sub _contains_key {
    my ($value, $needle) = @_;

    if (ref($value) eq 'HASH') {
        return 1 if exists $value->{$needle};
        for my $child (values %$value) {
            return 1 if _contains_key($child, $needle);
        }
    }
    elsif (ref($value) eq 'ARRAY') {
        for my $child (@$value) {
            return 1 if _contains_key($child, $needle);
        }
    }

    return 0;
}

sub _result {
    my ($self, %args) = @_;
    my $errors = $args{errors} // [];
    $errors = [$errors] unless ref($errors) eq 'ARRAY';

    return {
        ok       => @$errors ? 0 : 1,
        errors   => $errors,
        warnings => $args{warnings} // [],
        usage    => $args{usage}    // {
            input_tokens          => 0,
            output_tokens         => 0,
            input_tokens_details  => {cached_tokens => 0},
            prompt_tokens_details => {cached_tokens => 0},
        },
        cache => $args{cache} // {
            provider         => 'openai',
            key              => undef,
            prefix_chars     => 0,
            hit              => 0,
            created          => 0,
            read_tokens      => 0,
            created_tokens   => 0,
            prompt_cache_key => undef,
        },
    };
}

sub _estimate_tokens {
    my ($chars) = @_;
    $chars = 0 if !defined($chars) || $chars < 0;
    return int(($chars + 3) / 4);
}

sub _safe_key {
    my ($key) = @_;
    $key =~ s/[^A-Za-z0-9_.-]/_/g;
    return $key . '.json';
}

1;
