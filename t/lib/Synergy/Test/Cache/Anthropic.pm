package Synergy::Test::Cache::Anthropic;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);

sub new {
    my ($class, %args) = @_;
    my $self = {
        store_dir => $args{store_dir},
        json      => JSON::PP->new->canonical->allow_nonref,
    };
    make_path($self->{store_dir}) if defined $self->{store_dir};
    return bless $self, $class;
}

sub evaluate_request {
    my ($self, $body) = @_;

    my @errors;
    my @warnings;
    my @segments;
    my $breakpoint_count = 0;

    if (ref($body) ne 'HASH') {
        return $self->_result(
            errors => [
                'Anthropic cache contract violation: request body is not an object'
            ],
        );
    }

    push @errors,
      'Anthropic cache contract violation: cache_control found at request root'
      if exists $body->{cache_control};

    $self->_collect_tool_segments($body, \@segments, \$breakpoint_count,
        \@errors);
    $self->_collect_system_segments($body, \@segments, \$breakpoint_count,
        \@errors);
    $self->_collect_message_segments($body, \@segments, \$breakpoint_count,
        \@errors, \@warnings);

    push @errors,
      "Anthropic cache contract violation: $breakpoint_count explicit breakpoints found; maximum is 4"
      if $breakpoint_count > 4;

    my @prefix_segments;
    my @prefixes;
    for my $segment (@segments) {
        push @prefix_segments, $segment->{value};
        if ($segment->{breakpoint}) {
            my $prefix_json = $self->{json}->encode(\@prefix_segments);
            push @prefixes,
              {
                json  => $prefix_json,
                chars => length($prefix_json),
                key   => 'sha256:' . sha256_hex($prefix_json),
              };
        }
    }

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
              or die "Anthropic fake cache write failed: $!";
            print {$fh} $prefix->{json};
            close $fh;
        }
    }

    my $prefix_chars  = $last_prefix ? $last_prefix->{chars} : 0;
    my $read_chars    = $hit_prefix  ? $hit_prefix->{chars}  : 0;
    my $cache_tokens  = _estimate_tokens($prefix_chars - $read_chars);
    my $read_tokens   = _estimate_tokens($read_chars);
    my $suffix_tokens = _estimate_tokens(
        length($self->{json}->encode($body)) - $prefix_chars);

    return $self->_result(
        errors   => \@errors,
        warnings => \@warnings,
        usage    => {
            input_tokens                => $suffix_tokens,
            output_tokens               => 100,
            cache_creation_input_tokens => $cache_tokens,
            cache_read_input_tokens     => $read_tokens,
        },
        cache => {
            provider         => 'anthropic',
            key              => $last_prefix ? $last_prefix->{key} : undef,
            prefix_chars     => $prefix_chars,
            hit              => $hit_prefix       ? 1 : 0,
            created          => $cache_tokens > 0 ? 1 : 0,
            breakpoint_count => $breakpoint_count,
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
            content => [{type => 'text', text => 'OK_ANTHROPIC_CACHE',}],
            usage   => $result->{usage},
        }
    );
}

sub _collect_tool_segments {
    my ($self, $body, $segments, $breakpoint_count_ref, $errors) = @_;
    return unless ref($body->{tools}) eq 'ARRAY';

    for my $tool (@{$body->{tools}}) {
        next unless ref($tool) eq 'HASH';
        push @$segments,
          $self->_segment(
            location             => 'tools',
            value                => $tool,
            breakpoint_count_ref => $breakpoint_count_ref,
            errors               => $errors,
          );
    }
}

sub _collect_system_segments {
    my ($self, $body, $segments, $breakpoint_count_ref, $errors) = @_;
    return unless exists $body->{system};

    if (ref($body->{system}) eq 'ARRAY') {
        for my $block (@{$body->{system}}) {
            next unless ref($block) eq 'HASH';
            push @$segments,
              $self->_segment(
                location             => 'system',
                value                => $block,
                breakpoint_count_ref => $breakpoint_count_ref,
                errors               => $errors,
              );
        }
        return;
    }

    push @$segments,
      {
        location   => 'system',
        value      => {type => 'text', text => ($body->{system} // '')},
        breakpoint => 0,
      };
}

sub _collect_message_segments {
    my ($self, $body, $segments, $breakpoint_count_ref, $errors, $warnings)
      = @_;
    return unless ref($body->{messages}) eq 'ARRAY';

    for my $message (@{$body->{messages}}) {
        next unless ref($message) eq 'HASH';
        my $content = $message->{content};

        if (ref($content) eq 'ARRAY') {
            for my $block (@$content) {
                next unless ref($block) eq 'HASH';
                push @$segments,
                  $self->_segment(
                    location => 'messages',
                    value    => {role => $message->{role}, block => $block,},
                    breakpoint_count_ref => $breakpoint_count_ref,
                    errors               => $errors,
                  );
            }
            next;
        }

        push @$segments,
          {
            location => 'messages',
            value    => {role => $message->{role}, text => ($content // ''),},
            breakpoint => 0,
          };
    }

    if (@$segments && !$segments->[-1]{breakpoint}) {
        push @$warnings,
          'Anthropic cache contract warning: volatile suffix appears after last cache breakpoint';
    }
}

sub _segment {
    my ($self, %args) = @_;
    my $value = $args{value};
    my $cache_control;

    if (ref($value) eq 'HASH' && exists $value->{cache_control}) {
        $cache_control = $value->{cache_control};
    }
    elsif (ref($value) eq 'HASH'
        && ref($value->{block}) eq 'HASH'
        && exists $value->{block}{cache_control})
    {
        $cache_control = $value->{block}{cache_control};
    }

    my $breakpoint = 0;
    if (defined $cache_control) {
        $breakpoint = 1;
        ${$args{breakpoint_count_ref}}++;
        $self->_validate_cache_control($cache_control, $args{errors});
    }

    return {
        location   => $args{location},
        value      => $value,
        breakpoint => $breakpoint,
    };
}

sub _validate_cache_control {
    my ($self, $cache_control, $errors) = @_;

    if (ref($cache_control) ne 'HASH') {
        push @$errors,
          'Anthropic cache contract violation: cache_control is not an object';
        return;
    }

    push @$errors,
      'Anthropic cache contract violation: cache_control.type must be ephemeral'
      unless ($cache_control->{type} // '') eq 'ephemeral';

    push @$errors,
      'Anthropic cache contract violation: cache_control.ttl must be 1h when present'
      if exists($cache_control->{ttl})
      && ($cache_control->{ttl} // '') ne '1h';
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
            input_tokens                => 0,
            output_tokens               => 0,
            cache_creation_input_tokens => 0,
            cache_read_input_tokens     => 0,
        },
        cache => $args{cache} // {
            provider         => 'anthropic',
            key              => undef,
            prefix_chars     => 0,
            hit              => 0,
            created          => 0,
            breakpoint_count => 0,
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
