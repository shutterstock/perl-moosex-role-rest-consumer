use strict;
use warnings;

package MooseX::Role::REST::Consumer;

use MooseX::Role::Parameterized;
use MooseX::Role::REST::Consumer::Response;
use Shutterstock::Temp::Net::OAuth2::Client;
use Shutterstock::WWW::Statsd;
use File::Spec;
use REST::Consumer;
use Timed::Logger::Dancer::AdoptPlack;
use Try::Tiny;
use URI::Escape;
use Module::Load;

our $VERSION = '0.001';
my @METHODS = qw(get put post delete);
parameter service_host => (
  lazy => 1,
  default => ''
);

parameter service_port => ();

parameter resource_path => (
  lazy => 1,
  default => sub { undef }
);

parameter content_type => (
  isa => 'Str',
  required => 1,
  default => 'application/json',
);

parameter header_exclude => ( isa => 'HashRef', default => sub {{}} );

parameter retry => ( required => 1, default => 0 );
parameter timeout => ( default => 1 );

parameter oauth_creds => (
  isa => 'HashRef',
  default => sub {{}},
);

parameter query_params_mapping => (
  isa => 'HashRef',
  default => sub {{}},
);

parameter useragent_class => (
  isa => 'Str'
 );

my $statsd = Shutterstock::WWW::Statsd->new->client;

role {
  my $p = shift;

  my $service_host  = $p->service_host;
  my $service_port  = $p->service_port;
  my $resource_path = $p->resource_path;
  my $content_type  = $p->content_type;
  my $retry         = $p->retry;
  my $timeout       = $p->timeout;
  my $oauth_creds   = $p->oauth_creds;
  my $query_params_mapping = $p->query_params_mapping;
  my $useragent_class = $p->useragent_class;

  #Note: since this is a parametrized role then only one class will be closing
  #over this variable and this instance only depends on role parameters
  my $consumer_instance;

  #Note: $class varible in methods of this role can be an instance and a class name
  #For GET requests this is usually a class name, for POST requests
  #this would usually be an instance.
  #Be carefull!

  method 'consumer' => sub {
    my ($class) = @_;
    return $consumer_instance if($consumer_instance);

    my $user_agent;
    if($useragent_class) {
      Module::Load::load($useragent_class);
      $user_agent = $useragent_class->new;
    };
    my $client = REST::Consumer->new(host => $service_host,
                                     timeout => $timeout,
                                     ($user_agent ? (ua => $user_agent) : ()),
                                     ($service_port ? (port => $service_port) : ()));

    $client->user_agent->use_eval(0);
    $consumer_instance = $client;
    return $client;
  };

  method 'call' => sub {
    my ($class, $method, %params) = @_;

    my %request_headers = ($params{headers} ? %{delete $params{headers}} : ());
    # Strange mutation going on here:
    # 1. First we set the content_type in the headers if we have one set in parameter definition
    # 2. However, we won't override anything that is passed explicitly into a method call Class->post
    # 3. Next we delete anything that needs to be removed from the header
    # 4. Finally we explicltly pull out content-type from the request_headers
    #    to make REST::Consumer happy
    $request_headers{'Content-Type'} = $p->content_type unless $request_headers{'Content-Type'};
    delete @request_headers{@{$p->header_exclude->{$method}}} if $p->header_exclude->{$method};
    $content_type = delete $request_headers{'Content-Type'};

    if($oauth_creds && %{$oauth_creds} && !$params{access_token}) {
      my $access_token = $class->get_access_token;
      $params{access_token} = $access_token->access_token;
    }

    if ($params{access_token}) {
      $request_headers{Authorization} = 'Bearer ' . $params{access_token};
    }

    my %query_params;
    if($params{params}) {
      while(my ($name, $url_name) = each(%$query_params_mapping)) {
        # Check for method canness here probably
        $query_params{$url_name} = delete($params{params}->{$name});
      }
    }

    my @path = (defined $resource_path ? $resource_path : ());
    if($params{path}) {
      if(ref($params{path}) eq 'ARRAY') {
        push(@path, @{$params{path}});
      } else {
        push(@path, $params{path});
      }
    }
    my $path = File::Spec->catfile(@path);
    $path = $class->request_path($path, $params{params}) if($params{params});

    my ($data, $error, $timeout_error) = (undef, '', 0);

    my $logger = Timed::Logger::Dancer::AdoptPlack->logger;
    my $log_entry = $logger->start('REST');
    my %request = (
      params       => \%query_params,
      content      => $params{content},
      content_type => $content_type,
      headers      => ( %request_headers ? [ %request_headers ] : undef ),
     );

    my $consumer = $class->consumer; #we want same instance throughout the whole process

    if (my $timeout_override = delete $params{timeout} ) {
      $consumer->timeout($timeout_override);
    }

    my $service_class_name = 'service.' . lc(ref($class) || $class);
    $service_class_name    =~ s{::}{.}g;
    my $timer              = $statsd->timer($service_class_name,1);

    my $try = 0;
    while ($try <= $retry) {
      my $is_success;
      try {
        $try++;
        $request{path} = $path;
        $data = $consumer->$method(%request);
        $is_success = 1;
      } catch {
        $error = $_;
        $timeout_error++ if $error =~ /read timeout/;
      };
      last if $is_success;
   }

    $timer->finish;
    $consumer->timeout($timeout);
    $logger->finish($log_entry, {
      type => $method,
      path => $path,
      response => $data,
      request => \%request
    });

    # This is post shutterstock centric and should not live here
    # But since I can't think of an easier alternative at this time
    # it will unfortunately be here :(
    try {
      $statsd->increment('service.all', 1);
      $statsd->increment($service_class_name . '.all', 1);
      if($error) {
        $statsd->increment('service.error', 1);
        $statsd->increment($service_class_name . '.error', 1);
      }
      if($timeout_error) {
        $statsd->increment('service.timeout_error', $timeout_error);
        $statsd->increment($service_class_name . '.timeout_error', $timeout_error);
        $statsd->increment($service_class_name . ".timeout_error.$timeout_error", 1);
      }
    };

    # TODO: It's confusing as to how we handle errors.
    # ie: message should be called "error_message" and
    # we should inspect the response content for possible error messages
    return MooseX::Role::REST::Consumer::Response->new(
      data         => $data,
      is_success   => !$error,
      message      => "$error",
      request      => $consumer->last_request,
      content_type => $content_type,
      response     => $consumer->last_response,
    );
  };
  # Note: REST::Consumer doesn't support OPTIONS/PATCH
  foreach my $method ( @METHODS ) {
      method $method => sub {
        my $class = shift;
        $class->call($method, @_);
      }
  }

  #NOTE: You should not need to use this anymore! Use proper user access token instead!
  #TODO: Get rid of the code.
  method 'get_access_token' => sub {
    my ($class, %params) = @_;

    my $client = Shutterstock::Temp::Net::OAuth2::Client->new(
      $oauth_creds->{client_id},
      $oauth_creds->{client_secret},
      site => $oauth_creds->{auth_host},
      access_token_method => 'POST',
    )->web_server(grant_type => $oauth_creds->{grant_type});

    #Note: is this an oauth client bug that we have to pass grant_type twice?
    $params{grant_type} ||= $oauth_creds->{grant_type};

    my $code = delete($params{code});

    my $logger = Timed::Logger::Dancer::AdoptPlack->logger;
    my $log_entry = $logger->start('REST');
    my $access_token = $client->get_access_token($code, %params);
    $logger->finish($log_entry, {type => "access token", path => $resource_path});

    return $access_token;
  };

  method 'request_path' => sub {
    my ($class, $path, $params) = @_;
    #We support two ways of substituting params here:
    # /:param/ - name has to have '/' or end of string after it
    # /has_:{param}_value - surround param name with '{}'
    #Note: we go through complete incremental parsing/fetching url params to avoid
    #params substituted values being mached against other params names
    #We also verify that all parameters have been substituted
    my $result = '';
    while($path =~ /\G(.*?)(:(?:\{([^}]+?)\}|(\w+)(?=\W|$)))/gc) {
      $result .= $1;
      if($2) {
        my $name = $3 || $4; # only one of them could match
        if(exists $params->{$name}) {
          $result .= URI::Escape::uri_escape_utf8($params->{$name} // '');
        }
        else {
          die "Found parameter $name in path but it wasn't set in parameters hash";
        }
      }
    }
    if($path =~ /\G(.+)$/g) {
      $result .= $1;
    }
    return $result;
  };

  method 'parameters' => sub { $p };

};

__END__

=pod

=head1 NAME

 MooseX::Role::REST::Consumer

=head1 VERSION

 version 0.001

=head1 SYNOPSIS

  package Foo;
  use Moose;
  with 'MooseX::Role::REST::Consumer' => {
    service_host => 'somewhere.over.the.rainbow',
    resource_path => '/path/to/my/resource'
  };

=head1 DESCRIPTION

  At Shutterstock we love REST and we take it so seriously that we think our code should be restifully
  lazy. Now one can have a Moose model without needing to deal with all the marshaling details.

=head1 METHODS

=head2 get( $str )

 Will use REST::Consumer::get to lookup a resource by a supplied id.

=head2 post( $str, $hashref )

 Will perform a POST request with REST::Consumer::post. The data will the Content-Type of application/json by default.

=head1 LICENSE

 Copyright Shutterstock Inc (http://shutterstock.com).  All rights reserved.  This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself

=head1 SEE ALSO

L<REST::Consumer>, L<MooseX::Role::Parameterized>, L<Moose>

=head1 AUTHOR

=head1 COPYRIGHT AND LICENSE

 This software is copyright (c) 2013 by Shutterstock Inc..

 This is free software; you can redistribute it and/or modify it under
 the same terms as the Perl 5 programming language system itself.

=cut
