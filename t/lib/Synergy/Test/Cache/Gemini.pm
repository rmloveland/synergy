package Synergy::Test::Cache::Gemini;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);

sub new {
    my ($class, %args) = @_;
    my $model = $args{model} // 'gemini-3.5-flash';
    my $self  = {
        store_dir  => $args{store_dir},
        model      => $model,
        min_tokens => defined($args{min_tokens})
        ? $args{min_tokens}
        : _min_tokens_for_model($model),
        json => JSON::PP->new->canonical->allow_nonref,
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
                'Gemini cache contract violation: request body is not an object'
            ],
        );
    }

    push @errors, 'Gemini cache contract violation: contents must be an array'
      unless ref($body->{contents}) eq 'ARRAY';

    push @errors,
      'Gemini cache contract violation: cache_control is Anthropic-only'
      if _contains_key($body, 'cache_control');

    push @errors,
      'Gemini cache contract violation: prompt_cache_key is OpenAI-only'
      if _contains_key($body, 'prompt_cache_key');

    push @errors,
      'Gemini cache contract violation: prompt_cache_retention is OpenAI-only'
      if _contains_key($body, 'prompt_cache_retention');

    my @prefixes
      = ref($body->{contents}) eq 'ARRAY'
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
              or die "Gemini fake cache write failed: $!";
            print {$fh} $prefix->{json};
            close $fh;
        }
    }

    push @warnings,
      'Gemini cache contract warning: no prefix reached the model cache eligibility threshold'
      if !@prefixes;

    my $prompt_tokens
      = _estimate_tokens(length($self->{json}->encode($body)));
    my $cached_tokens = $hit_prefix ? $hit_prefix->{tokens} : 0;
    my $created_tokens
      = $last_prefix ? $last_prefix->{tokens} - $cached_tokens : 0;
    $created_tokens = 0 if $created_tokens < 0;
    my $output_tokens = 100;

    return $self->_result(
        errors   => \@errors,
        warnings => \@warnings,
        usage    => {
            promptTokenCount        => $prompt_tokens,
            candidatesTokenCount    => $output_tokens,
            totalTokenCount         => $prompt_tokens + $output_tokens,
            cachedContentTokenCount => $cached_tokens,
        },
        cache => {
            provider         => 'gemini',
            model            => $self->{model},
            key              => $last_prefix ? $last_prefix->{key}   : undef,
            prefix_chars     => $last_prefix ? $last_prefix->{chars} : 0,
            hit              => $hit_prefix  ? 1                     : 0,
            created          => $created_tokens > 0 ? 1              : 0,
            read_tokens      => $cached_tokens,
            created_tokens   => $created_tokens,
            min_tokens       => $self->{min_tokens},
            cacheable_prefix => $last_prefix ? 1 : 0,
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
            candidates =>
              [{content => {parts => [{text => 'OK_GEMINI_CACHE'}],},}],
            usageMetadata => $result->{usage},
        }
    );
}

sub _cacheable_prefixes {
    my ($self, $body) = @_;

    my @prefixes;
    my @prefix_contents;
    for my $content (@{$body->{contents}}) {
        push @prefix_contents, $content;
        my $prefix_body
          = {model => $self->{model}, contents => [@prefix_contents],};

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
            promptTokenCount        => 0,
            candidatesTokenCount    => 0,
            totalTokenCount         => 0,
            cachedContentTokenCount => 0,
        },
        cache => $args{cache} // {
            provider         => 'gemini',
            model            => $self->{model},
            key              => undef,
            prefix_chars     => 0,
            hit              => 0,
            created          => 0,
            read_tokens      => 0,
            created_tokens   => 0,
            min_tokens       => $self->{min_tokens},
            cacheable_prefix => 0,
        },
    };
}

sub _min_tokens_for_model {
    my ($model) = @_;
    return 4096 if defined($model) && $model =~ /pro/i;
    return 1024;
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
