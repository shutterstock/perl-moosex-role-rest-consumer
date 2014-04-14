#! /usr/bin/env perl
use strict;
use warnings;

use Test::More tests => 11;
use Test::Exception;
use Test::Deep;
use Test::Easy qw(resub wiretap);
use List::MoreUtils;
use Test::MockObject;
use Time::HiRes;
use Timed::Logger;
use Timed::Logger::Dancer::AdoptPlack;

my $rest_consumer_log = Timed::Logger->new;
my $adopt_plack_new = resub(
  'Timed::Logger::Dancer::AdoptPlack::logger',
  sub { return $rest_consumer_log }
 );

sub get_mock {
    #Need to sleep for a moment to make sure that logger sees positive time
    Time::HiRes::sleep(0.25);
    return
}
sub post_mock {
    #Need to sleep for a moment to make sure that logger sees positive time
    Time::HiRes::sleep(0.25);
    return 'stuff'
}

use_ok 'MooseX::Role::REST::Consumer';
subtest "Standard GET request" => sub {
  plan tests => 5;

  {
    package FooTestParams;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions/:{id}/:param/:last_param',
      query_params_mapping => { query_id => 'id' }
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get', &get_mock;
  my $consumer_new_wt = wiretap 'REST::Consumer::new';

  my ($obj, $get_req, $post_req);
  lives_ok { $obj = FooTestParams->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  subtest "Some basic tests to make sure that parameter replacing is working as expected" => sub {
    plan tests => 11;
    is($obj->request_path('/:id/', { id => 123 }), '/123/');
    is($obj->request_path('/:id', { id => 123 }), '/123');
    is($obj->request_path('/:{id}/', { id => 123 }), '/123/');
    is($obj->request_path('/:{id}', { id => 123 }), '/123');
    is($obj->request_path('/aaa/:{id}.json', { id => 123 }), '/aaa/123.json');
    is($obj->request_path('/aaa/:{id.id}.json', { "id.id" => 123 }), '/aaa/123.json');
    is($obj->request_path('/:id/:id_new/', { id => 123, id_new => 321 }), '/123/321/');
    is($obj->request_path('/:id:id_new/', { id => 123, id_new => 321 }), '/123321/');
    is($obj->request_path('/:id:id_new', { id => 123, id_new => 321 }), '/123321');
    throws_ok { $obj->request_path('/:id/:id_new/', { id => 123 }) } qr/Found parameter id_new/,
        'Die if parameter is not found';
    is($obj->request_path('/:id:id_new/', { id => ":id_new", id_new => ":id" }), '/%3Aid_new%3Aid/',
       'make sure we do not subsitute in values');
  };

  lives_ok { $get_req = $obj->get(params => {
    id => 123, param => 'param_value', last_param => 'last/param/value',
    query_id => 1
   }, content => 'content') } "Calling get returns something";

  cmp_deeply($consumer_new_wt->named_method_args, [{
    timeout => 1,
    host => 'session.dev.shuttercorp.net'
   }]);

  cmp_deeply $consumer_get_rs->named_method_args,[
    {
      params => {
        id => 1
      },
      content_type => 'application/json',
      headers => undef,
      content => 'content',
      path => '/sessions/123/param_value/last%2Fparam%2Fvalue'
    }
  ];

};

subtest "GET/POST request" => sub {
  plan tests => 9;

  {
    package Foo::Test;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
      timeout => 0.5,
    };
  }

  my $consumer_new_wt = wiretap 'REST::Consumer::new';
  my $consumer_get_rs = resub 'REST::Consumer::get', \&get_mock;
  my $consumer_post_rs = resub 'REST::Consumer::post', \&post_mock;

  my ($obj, $get_req, $post_req);

  lives_ok { $obj = Foo::Test->new } "Creating a class that implments MX::R::REST::Consumer lives!";
  lives_ok { $get_req = $obj->get(path => 1) } "Calling get returns something";
  lives_ok { $post_req = $obj->post(path => 1, content => { content => 'POST!' } ) }
      "Calling post returns something";

  cmp_deeply($consumer_new_wt->named_method_args, [{
    timeout => 0.5,
    'host' => 'session.dev.shuttercorp.net'
   }]);

  cmp_deeply $consumer_get_rs->named_method_args, [
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => undef,
      path => '/sessions/1'
    }
  ];

  cmp_deeply $consumer_post_rs->named_method_args, [
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => {
        content => 'POST!'
      },
      path => '/sessions/1'
    }
  ];


  #Call get and post again and make sure we create only one REST::Consumer after all
  lives_ok { $obj->get(path => 1) } "Calling get returns something";
  lives_ok { $obj->post(path => 1, content => { content => 'POST!' } ) }
      "Calling post returns something";

  cmp_deeply($consumer_new_wt->named_method_args, [{
    timeout => 0.5,
    host => 'session.dev.shuttercorp.net'
   }], 'Make sure that we create only one REST::Consumer instance');
};

subtest "Testing a service exception" => sub {
  plan tests => 4;

  {
    package Foo::Test::Error;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
      timeout => 0.5,
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get', sub { get_mock(); die "error"; };

  my ($obj, $get_req);

  lives_ok { $obj = Foo::Test::Error->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";
  lives_ok { $get_req = $obj->get(path => 1) } "Calling get returns something";

  ok !$get_req->is_success, "the get was not successful";

  cmp_deeply $consumer_get_rs->named_method_args, [
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => undef,
      path => '/sessions/1'
    }
  ];

};

#check that requests from above were logged
subtest "Testing logging" => sub {
  plan tests => 6;

  is(0 + keys(%{$rest_consumer_log->log}), 1, 'got only 1 type on logs');
  my $log = $rest_consumer_log->log->{'REST'};
  is(0 + @$log, 6, 'got 6 log entries');
  ok(List::MoreUtils::all(sub { $_->elapsed > 0 }, @$log), 'all elapsed times are positive');
  ok(List::MoreUtils::all(sub { $_->started > 0 }, @$log), 'all started times are positive');
  ok(List::MoreUtils::all(sub { $_->bucket eq 'REST' }, @$log), 'all have expected type');
  ok(List::MoreUtils::all(sub { defined($_->data) && $_->data->{path} }, @$log), 'all have data with path');
};

subtest "We should be able to set custom headers" => sub {
  plan tests => 3;
  {
    package CustomHeadersTest;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get', sub {};
  my ($obj, $get_req);

  lives_ok { $obj = CustomHeadersTest->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  lives_ok {
    $get_req = $obj->get(path => 1, headers => {
      'X-Foo-Bar' => 'Random header 1',
      'X-Baz-Jazz' => 'Random header 2'
     });
  } "Calling get returns something";

  cmp_deeply($consumer_get_rs->named_method_args, [{
    path => '/sessions/1',
    headers => [
      'X-Baz-Jazz',
      'Random header 2',
      'X-Foo-Bar',
      'Random header 1'
     ],
    content_type => 'application/json',
    params => {},
    content => undef
   }], "we called the service with custom headers");
};

subtest "We should be able to use custom user agent" => sub {
  plan tests => 4;
  {
    package CustomUserAgentTest;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
      useragent_class => 'MooseX::Role::REST::Consumer::UserAgent::Curl',
    };
  }

  my $consumer_new_wt = wiretap 'REST::Consumer::new';
  my $consumer_get_rs = resub 'REST::Consumer::get', sub {};
  my ($obj, $get_req);

  lives_ok { $obj = CustomUserAgentTest->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  lives_ok {
    $get_req = $obj->get(path => 1);
  } "Calling get returns something";

  cmp_deeply($consumer_new_wt->named_method_args, [{
    ua => isa('MooseX::Role::REST::Consumer::UserAgent::Curl'),
    timeout => 1,
    host => 'session.dev.shuttercorp.net'
   }], "we called the service");

  cmp_deeply($consumer_get_rs->named_method_args, [{
    path => '/sessions/1',
    headers => undef,
    content_type => 'application/json',
    params => {},
    content => undef
   }], "we called the service");
};

subtest "Testing a service exception with timeout_retry set" => sub {
  plan tests => 4;

  {
    package Foo::Test::ErrorWithTimeout;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
      timeout => 0.5,
      retry => 2,
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get', sub { get_mock(); die "had a read timeout"; };

  my ($obj, $get_req);

  lives_ok { $obj = Foo::Test::ErrorWithTimeout->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  lives_ok { $get_req = $obj->get(path => 1) } "Calling get returns something";

  ok !$get_req->is_success, "the get was not successful";

  cmp_deeply $consumer_get_rs->named_method_args, [
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => undef,
      path => '/sessions/1'
    },
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => undef,
      path => '/sessions/1'
    },
    {
      params => {},
      content_type => 'application/json',
      headers => undef,
      content => undef,
      path => '/sessions/1'
    }
  ];

};

#check that requests from above were logged
subtest "Testing logging" => sub {
  plan tests => 6;

  is(0 + keys(%{$rest_consumer_log->log}), 1, 'got only 1 type on logs');
  my $log = $rest_consumer_log->log->{'REST'};
  is(0 + @$log, 9, 'got 9 log entries');
  ok(List::MoreUtils::all(sub { $_->elapsed > 0 }, @$log), 'all elapsed times are positive');
  ok(List::MoreUtils::all(sub { $_->started > 0 }, @$log), 'all started times are positive');
  ok(List::MoreUtils::all(sub { $_->bucket eq 'REST' }, @$log), 'all have expected type');
  ok(List::MoreUtils::all(sub { defined($_->data) && $_->data->{path} }, @$log), 'all have data with path');
};

subtest "We should be able to set custom headers" => sub {
  plan tests => 3;
  {
    package CustomHeadersTest;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'session.dev.shuttercorp.net',
      resource_path => '/sessions',
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get', sub {};
  my ($obj, $get_req);

  lives_ok { $obj = CustomHeadersTest->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  lives_ok {
    $get_req = $obj->get(path => 1, headers => {
      'X-Foo-Bar' => 'Random header 1',
      'X-Baz-Jazz' => 'Random header 2'
     });
  } "Calling get returns something";

  cmp_deeply($consumer_get_rs->named_method_args, [{
    path => '/sessions/1',
    headers => [
      'X-Baz-Jazz',
      'Random header 2',
      'X-Foo-Bar',
      'Random header 1'
     ],
    content_type => 'application/json',
    params => {},
    content => undef
   }], "we called the service with custom headers");
};

subtest "overriding a timeout" => sub {
  plan tests => 5;
  {
    package OverrideTimeout;
    use Moose;
    with 'MooseX::Role::REST::Consumer' => {
      service_host => 'http://foo.com',
      resource_path => '/bar',
      timeout => '20',
    };
  }

  my $consumer_get_rs = resub 'REST::Consumer::get' => sub {};
  my $consumer_timout_wt = wiretap 'REST::Consumer::timeout' => sub {};

  my ($obj, $get_req);
  lives_ok { $obj = OverrideTimeout->new }
      "Creating a class that implments MX::R::REST::Consumer lives!";

  lives_ok {
    $get_req = $obj->get(timeout => 1);
  } "Calling get returns something";

  cmp_deeply($consumer_get_rs->named_method_args, [{
    path => '/bar',
    headers => ignore(),
    content_type => 'application/json',
    params => {},
    content => undef
   }], "we called the service with custom headers");

  is $obj->consumer->timeout, 20;
  is($consumer_timout_wt->method_args->[1][0],1);
};
