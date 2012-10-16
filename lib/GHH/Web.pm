package GHH::Web;
use strict;
use warnings;
use Wanage::HTTP;
use Warabe::App;
use JSON::Functions::XS qw(json_bytes2perl);

sub psgi_app {
    return sub {
        my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
        my $app = Warabe::App->new_from_http ($http);
        
        return $http->send_response(onready => sub {
            $app->execute (sub {
                GHH::Web->process ($app);
            });
        });
    };
}

sub process {
    my ($class, $app) = @_;

    my $path = $app->path_segments;
    if ($path->[0] eq '') {
        $app->requires_request_method ({POST => 1});
        my $repo_url = $app->bare_param('url')
            or $app->throw_error(400, reason_phrase => 'Param |url| not specified');
        $app->http->set_status(200);
        $app->http->send_response_body_as_text("Accepted\n");
        $app->http->close_response_body;

        require GHH::Action::ProcessRepository;
        my $action = GHH::Action::ProcessRepository->new_from_url($repo_url);
        $action->onmessage(sub {
            my ($msg, %args) = @_;
            if ($args{die}) {
                die '[', scalar gmtime, '] ', $msg, "\n";
            } else {
                warn '[', scalar gmtime, '] ', $msg, "\n";
            }
        });

        $action->refname($app->bare_param('refname'));
        $action->commits($app->bare_param('commits'));
        $action->event($app->bare_param('event') || 'push');
        
        my $cv = eval {
            $action->run_as_cv;
        };
        warn $@ if $@;

        return $app->throw;
    } elsif ($path->[0] eq 'hook' and not defined $path->[1]) {
        $app->requires_request_method ({POST => 1});
        my $json = json_bytes2perl ${$app->http->request_body_as_ref};
        $json = {} unless $json and ref $json eq 'HASH';

        my $repo_url = $json->{repository}->{url}
            or $app->throw_error(400, reason_phrase => 'Param |url| not specified');
        $app->http->set_status(200);
        $app->http->send_response_body_as_text("Accepted\n");
        $app->http->close_response_body;

        require GHH::Action::ProcessRepository;
        my $action = GHH::Action::ProcessRepository->new_from_url($repo_url);
        $action->onmessage(sub {
            my ($msg, %args) = @_;
            if ($args{die}) {
                die '[', scalar gmtime, '] ', $msg, "\n";
            } else {
                warn '[', scalar gmtime, '] ', $msg, "\n";
            }
        });

        my $ref = $json->{ref};
        if (defined $ref) {
            $ref =~ s{^refs/heads/}{};
            $action->refname($ref);
        }
        if (defined $json->{before} and defined $json->{after}) {
            $action->commits(join ' ', $json->{after}, $json->{before});
        } elsif (defined $json->{after}) {
            $action->commits($json->{after});
        }
        $action->event($json->{event} || 'push');
        
        my $cv = eval {
            $action->run_as_cv;
        };
        warn $@ if $@;

        return $app->throw;

    }

    return $app->throw_error(404);
}

1;
