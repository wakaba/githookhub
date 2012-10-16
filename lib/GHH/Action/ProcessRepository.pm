package GHH::Action::ProcessRepository;
use strict;
use warnings;
use File::Temp;
use Path::Class;
use AnyEvent;
use AnyEvent::Util;
use List::Ish;
use Git::Parser::Log;
use MIME::Base64 qw(decode_base64);
use GHH::Config;
use Web::UserAgent::Functions qw(http_post http_post_data);
use JSON::Functions::XS qw(file2perl perl2json_bytes_for_record);

my $DEBUG = $ENV{GHH_DEBUG};

sub new_from_url {
    return bless {url => $_[1]}, $_[0];
}

sub url {
    return $_[0]->{url};
}

sub onmessage {
    if (@_ > 1) {
        $_[0]->{onmessage} = $_[1];
    }
    return $_[0]->{onmessage} ||= sub { };
}

sub refname {
    if (@_ > 1) {
        $_[0]->{refname} = $_[1];
    }
    return $_[0]->{refname};
}

sub commits {
    if (@_ > 1) {
        $_[0]->{commits} = List::Ish->new([split /\s+/, $_[1]]);
    }
    return $_[0]->{commits} || List::Ish->new;
}

sub old_commit {
    return $_[0]->commits->[-1];
}

sub new_commit {
    return $_[0]->commits->[0];
}

sub event {
    if (@_ > 1) {
        $_[0]->{event} = $_[1];
    }
    return $_[0]->{event};
}

sub hook_args {
    if (@_ > 1) {
        $_[0]->{hook_args} = $_[1];
    }
    return $_[0]->{hook_args};
}

sub print_message {
    my ($self, $msg) = @_;
    $self->onmessage->($msg);
}

sub die_message {
    my ($self, $msg) = @_;
    $self->onmessage->($msg, die => 1);
    die $msg;
}

sub temp_repo_temp {
    my $self = shift;
    return $self->{temp_repo_temp} ||= File::Temp->newdir(CLEANUP => !$DEBUG);
}

sub temp_repo_d {
    my $self = shift;
    return $self->{temp_repo_d} ||= dir($self->temp_repo_temp->dirname);
}

sub git_as_cv {
    my ($self, $cmd, %args) = @_;
    $self->print_message('$ ' . join ' ', 'git', @$cmd);
    my $onmessage = $self->onmessage;
    if (defined $args{chdir} and length $args{chdir}) {
        $cmd = ['sh', '-c', 'cd ' . (quotemeta $args{chdir}) . ' && git ' . join ' ', map { quotemeta } @$cmd];
    } else {
        $cmd = ['git', @$cmd];
    }
    return run_cmd $cmd, 
        '>' => $args{onstdout} || sub {
            $onmessage->($_[0]) if defined $_[0];
        },
        '2>' => sub {
            $onmessage->($_[0]) if defined $_[0];
        },
    ;
}

sub clone_depth {
    return 200;
}

sub clone_as_cv {
    my $self = shift;
    return $self->git_as_cv(['clone', '--depth' => $self->clone_depth, $self->url => $self->temp_repo_d->stringify]);
}

sub _datetime ($) {
    my @time = gmtime $_[0];
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
}

sub log_as_cv {
    my $self = shift;
    if ($self->{commit_logs}) {
        my $cv = AE::cv;
        $cv->send($self->{commit_logs});
        return $cv;
    }

    if ($self->{log_as_cvs}) {
        my $cv = AE::cv;
        push @{$self->{log_as_cvs}}, $cv;
        return $cv;
    }

    my $cv = AE::cv;
    $self->{log_as_cvs} = [$cv];
    my $log = [];
    $self->git_as_cv(
        ['log', '--raw', '--format=raw',
         $self->old_commit . '..' . $self->new_commit],
        chdir => $self->temp_repo_d->stringify,
        onstdout => sub {
            push @$log, $_[0] if defined $_[0];
        },
    )->cb(sub {
        my $commits = $self->{commit_logs} = [];
        my $parsed = Git::Parser::Log->parse_format_raw(join "\n", @$log);
        for my $commit (@{$parsed->{commits}}) {
            push @$commits, $commit;
            # <https://help.github.com/articles/post-receive-hooks>.
            $commit->{id} = delete $commit->{commit};
            $commit->{message} = delete $commit->{body};
            $commit->{timestamp} = _datetime $commit->{author}->{time};
            $commit->{added} = [grep { $commit->{files}->{$_}->{mod_type} eq 'A' } keys %{$commit->{files}}];
            $commit->{deleted} = [grep { $commit->{files}->{$_}->{mod_type} eq 'D' } keys %{$commit->{files}}];
            $commit->{modified} = [grep { $commit->{files}->{$_}->{mod_type} eq 'M' } keys %{$commit->{files}}];
            $commit->{author}->{email} = delete $commit->{author}->{mail};
            $commit->{committer}->{email} = delete $commit->{committer}->{mail};
        }
        for (@{$self->{log_as_cvs}}) {
            $_->send($commits);
        }
        delete $self->{log_as_cvs};
    });
    return $cv;
}

sub exists_file {
    my ($self, $path) = @_;
    return -f $self->temp_repo_d->file($path);
}

sub has_make_rule_as_cv {
    my ($self, $rule) = @_;
    my $dir = $self->temp_repo_d->stringify;

    my $cv = AE::cv;

    my $run = run_cmd(
        "cd @{[quotemeta $dir]} && make -q @{[quotemeta $rule]}",
    );
    $run->cb(sub {
        my $return = $_[0]->recv >> 8;
        $cv->send($return < 2);
    });

    # From textinfo of GNU make:
    # GNU make exits with a status of zero if all makefiles were
    # successfully parsed and no targets that were built failed.  A
    # status of one will be returned if the -q flag was used and make
    # determines that a target needs to be rebuilt.  A status of two
    # will be returned if any errors were encountered.

    return $cv;
}

sub processing_rules_d {
    return $GHH::Config::RulesD || die "\$GHH::Config::RulesD not defined";
}

sub action_defs_d {
    return $_[0]->processing_rules_d->subdir('actions');
}

sub processing_rules {
    my $self = shift;
    return [map {
        my $json = file2perl $_;
        if (defined $json and ref $json eq 'HASH') {
            $json->{f} = $_;
        } else {
            $json = {input => $_, f => $_, error => 1};
        }
        $json->{name} ||= $json->{f} . '';
        $json;
    } grep { -f and /\.json$/ } $self->processing_rules_d->children];
}

sub run_as_cv {
    my $self = shift;
    my $actions_cv = AE::cv;
    $actions_cv->begin(sub { $_[0]->send });

    my $clone_cv = AE::cv;
    my $timer; $timer = AE::timer 2, 0, sub {
        my $cv = $self->clone_as_cv;
        $cv->cb(sub { $clone_cv->send });
        undef $timer;
    };
    $clone_cv->cb(sub {
        unless (-d $self->temp_repo_d) {
            $actions_cv->send({error => "Clone failed"});
        }

        my $url = $self->url;
        my $hook_args = $self->hook_args || {};
        $hook_args = {} unless ref $hook_args eq 'HASH';
        my @applicable_rule;
        my $rules_cv = AE::cv;
        $rules_cv->begin(sub { $_[0]->send });
        RULE: for my $rule (@{$self->processing_rules}) {
            $self->print_message("$rule->{name} ($rule->{f})...") if $DEBUG;
            next RULE if $rule->{error};

            unless (($rule->{event_match} || 'push') eq $self->event) {
                next RULE;
            }

            for my $args_key (keys %{$rule->{args_match} or {}}) {
                my $expected = $rule->{args_match}->{$args_key};
                $expected = '' unless defined $expected;
                my $actual = $hook_args->{$args_key};
                $actual = '' unless defined $actual;
                next RULE unless $expected eq $actual;
            }

            if (defined $rule->{url_match}) {
                unless ($url =~ /$rule->{url_match}/) {
                    next RULE;
                }
            }
            
            if ($rule->{has_file}) {
                $self->print_message("$rule->{name}: Has file $rule->{has_file}?") if $DEBUG;
                unless ($self->exists_file($rule->{has_file})) {
                    $self->print_message("$rule->{name}: $rule->{has_file} not found") if $DEBUG;
                    next RULE;
                }
            }

            $rules_cv->begin;
            my $cv = AE::cv;
            if ($rule->{can_make}) {
                $self->print_message("$rule->{name}: Can make $rule->{can_make}?") if $DEBUG;
                $self->has_make_rule_as_cv($rule->{can_make})->cb(sub {
                    if ($_[0]->recv) {
                        $cv->send(1);
                    } else {
                        $self->print_message("$rule->{name}: $rule->{can_make} can't make") if $DEBUG;
                        $cv->send(0);
                    }
                });
            } else {
                $cv->send(1);
            }
            $cv->cb(sub {
                if ($_[0]->recv) {
                    push @applicable_rule, $rule;
                    $self->print_message("$rule->{name}: Matched") if $DEBUG;
                }
                $rules_cv->end;
            });
        }
        $rules_cv->end;
        $rules_cv->cb(sub {
            my $repo = {
                url => $url,
            };
            for my $rule (@applicable_rule) {
                if ($rule->{http_post}) {
                    $actions_cv->begin;
                    $self->log_as_cv->cb(sub {
                        my $commits = $_[0]->recv;
                        http_post_data
                            url => $rule->{http_post},
                            basic_auth => $rule->{basic_auth} ? [$rule->{basic_auth}->[0], decode_base64 $rule->{basic_auth}->[1]] : undef,
                            content => (perl2json_bytes_for_record +{
                                hook_rule_name => $rule->{name},
                                hook_args => $rule->{args},
                                current => {
                                    event => $self->event,
                                    hook_args => $hook_args,
                                },
                                
                                # <https://help.github.com/articles/post-receive-hooks>.
                                before => $self->old_commit,
                                after => $self->new_commit,
                                ref => $self->refname,
                                repository => $repo,
                                commits => $commits,
                            }),
                            anyevent => 1,
                            cb => sub { $actions_cv->end };
                    });
                }

                if ($rule->{call_action}) {
                    $actions_cv->begin;
                    $self->log_as_cv->cb(sub {
                        my $commits = $_[0]->recv;
                        http_post
                            url => 'http://' . $rule->{call_action}->{host} . '/',
                            basic_auth => $rule->{basic_auth} ? [$rule->{basic_auth}->[0], decode_base64 $rule->{basic_auth}->[1]] : undef,
                            params => {
                                url => $self->url,
                                action => $rule->{call_action}->{name} || 'default',
                            },
                            anyevent => 1,
                            cb => sub { $actions_cv->end };
                    });
                }

                if ($rule->{ikachan}) {
                    $actions_cv->begin;
                    $self->log_as_cv->cb(sub {
                        my $commits = $_[0]->recv;
                        http_post
                            anyevent => 1,
                            url => qq{http://@{[$rule->{ikachan}->{host}]}/@{[$rule->{ikachan}->{privmsg} ? 'privmsg' : 'notice']}},
                            params => {
                                channel => $rule->{ikachan}->{channel},
                                message => (join "\n", map {
                                    my $repository = $repo;
                                    my $commit = $_;
                                    my $refname = $self->refname;
                                    $refname = '' unless defined $refname;
                                    my $args = $hook_args;
                                    my $code = $rule->{ikachan}->{construct_line} ||
                                        q{ sprintf "[%s] %s: %s %s", $repository->{url}, $commit->{author}->{name}, $commit->{message}, substr $commit->{id}, 0, 10 };
                                    eval $code or $@;
                                } @$commits),
                            },
                            cb => sub {
                                $actions_cv->end;
                            };
                    });
                }
            }
        });
    });

    $actions_cv->end;
    return $actions_cv;
}

1;
