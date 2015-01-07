#!/home/suppy/perl5/perlbrew/perls/perl-5.16.2/bin/perl

use strict;
use warnings;

use 5.010.001;

use Mojolicious::Lite;
use Regexp::Common qw/ URI /;
use POSIX qw/ ceil /;

plugin 'Config';

plugin 'Database', app->config()->{database}; #configuration in qdb.conf file


## Route section
under sub { shift->session(expiration => 604_800); }; #1 week

get  '/'                  => sub { shift->loadquote('random')->render('quote');                            };
get  '/quote/:id'         => sub { shift->loadquote()->render('quote');                                    };
get  '/quote/:id/voteup'  => sub { shift->vote(1)->render('quote');                                        };
get  '/quote/:id/votedn'  => sub { shift->vote(-1)->render('quote');                                       };
get  '/list'              => sub { shift->get_page(1)->stash(pagebase => '/list')->render('list');         };
get  '/list/:page'        => sub { shift->get_page()->stash(pagebase => '/list')->render('list');          };
get  '/add'               => sub { shift->render('add');                                                   };
post '/add'               => sub { shift->addquote()->render('quote');                                     };
post '/search'            => sub { shift->searchquote()->stash(pagebase => '/search')->render('list');     };
get  '/search/:page'      => sub { shift->get_search_page()->stash(pagebase => '/search')->render('list'); };
get  '/admin'             => sub { shift->declare('error')->render('login');                               };
post '/admin'             => sub { shift->login()->render('login');                                        };

under sub { shift->checklogin() and return 1; return undef; };

get  '/waiting'           => sub { shift->render('waiting');                                               };
get  '/quote/:id/edit'    => sub { shift->loadquote()->render('edit');                                     };
post '/quote/:id/edit'    => sub { shift->editquote()->render('quote');                                    };
get  '/quote/:id/approve' => sub { shift->approvequote()->go_back()                                        };
get  '/quote/:id/delete'  => sub { shift->deletequote()->go_back()                                         };
get  '/logout'            => sub { shift->logout()->render('login');                                       };

## Helper section
helper loadquote => sub {
    my $self = shift;
    my $id   = shift // $self->param('id');
    $self->getquote($id);

    return $self;
};

helper vote => sub {
    my $self = shift;
    my $id   = $self->param('id');
    my $vote = shift;

    my $ref = $self->getquote($id);
    $self->query('UPDATE quotes SET vote = ? WHERE id = ?', $ref->{'vote'} + $vote, $id);

    $self->loadquote($id);
};

helper addquote => sub {
    my $self  = shift;
    my $quote = $self->param('quote');
    $quote    =~ s!\r!!g;

    my $id = 0;
    $id = $self->db->last_insert_id('', '', 'quotes', '') if defined
        $self->query('INSERT INTO quotes (text) VALUES (?)', $quote);
    $self->loadquote($id);
};

helper searchquote => sub {
    my $self = shift;
    my $text = $self->param('search');

    $text    =~ s/^| |$/%/g;
    my $ref  = $self->query_all('SELECT id FROM quotes WHERE text LIKE ? AND approved = 1', $text) // [];

    my @ids  = map { $_->[0] } @{$ref};
    @ids = (0) unless @ids;
    $self->stash(results => [@ids]);
    $self->flash(results => [@ids]);
    warn "Flashing: @ids";

    return $self->get_page(1);
};

helper login => sub {
    my $self  = shift;
    my $pass  = $self->param('pass');
    my $admin = $self->param('admin');
    $self->declare('error');

    if (
            defined $admin
        and defined $pass
        and defined app->config()->{admins}
        and defined app->config()->{admins}->{$admin}
        and         app->config()->{admins}->{$admin} eq $pass) {
        $self->session()->{'admin'} = 1;
    }
    else {
        $self->session()->{'admin'} = 0;
        if (defined $pass) { $self->stash(error => 'Wrong username or password'); }
    }

    return $self;
};

helper logout => sub {
    my $self = shift;
    $self->session()->{'admin'} = 0;
    $self->declare('error');
};

helper checklogin => sub {
    my $self = shift;

    return 1 if $self->session()->{admin};

    $self->stash(error => 'Not logged in');
    $self->render('login');
    return 0;
};

helper deletequote => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->getquote($id);
    $self->query('DELETE FROM quotes WHERE id = ?', $id);

    return $self;
};

helper editquote => sub {
    my $self = shift;
    my $id   = $self->param('id');
    my $text = $self->param('quote');

    $self->query('UPDATE quotes SET text = ? WHERE id = ?', $text, $id);
    $self->loadquote($id);
};

helper approvequote => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->query('UPDATE quotes SET approved = 1 WHERE id = ?', $id);
    $self->loadquote($id);
};



## Helper utility methods
helper getquote => sub {
    my $self = shift;
    my $id   = shift;

    if ($id eq 'random') {
        my @ids = $self->getids();
        $id = $ids[rand @ids] // 0;
    }

    my $ref = { id => 0, text => 'No quote found', vote => 0 };
    if ($id != 0) {
        $ref = $self->query_row('SELECT * FROM quotes WHERE id = ?', $id) // $ref;
    }

    chomp $ref->{text};
    $ref->{text} =~ s!\r!!g;
    $self->stash(id       => $ref->{id});
    $self->stash(quote    => $ref->{text});
    $self->stash(vote     => $ref->{vote});
    $self->stash(approved => $ref->{'approved'});
    return $ref;
};

helper getids => sub {
    my $self = shift;
    my $approved = shift // 1;

    my $ref = $self->query_all('SELECT id FROM quotes WHERE approved = ?', $approved) // [ [ 0 ] ];
    $ref = [ [ 0 ] ] unless (@{$ref});

    return map { $_->[0] } @{$ref};
};

helper query_all => sub {
    my $self = shift;

    my $q = $self->query(@_);
    return $q->fetchall_arrayref() if defined $q;

    return undef;
};

helper query_row => sub {
    my $self = shift;

    my $q = $self->query(@_);
    return $q->fetchrow_hashref() if defined $q;

    return undef;
};

helper get_page => sub {
    my $self = shift;
    my $page = $self->param('page') // $_[0] // 1;

    my $res_per_page = 50;
    my @ids   = $self->results() ? $self->results() : $self->getids();
    my $pages = ceil( @ids / $res_per_page );
    my $start = ($page - 1) * $res_per_page;
    my $end   = $page * $res_per_page - 1;
    my @res   = grep { defined } @ids[$start .. $end];
       @res   = (0) unless @res;

    $self->stash(results => [ @res ]);
    $self->stash(pages   => $pages) if $pages > 1;
    $self->stash(page    => $page)  if $pages > 1;

    return $self;
};

helper get_search_page => sub {
    my $self = shift;
    my @ids  = @{ $self->flash('results') // [ 0 ] };

    $self->flash(results => [ @ids ]);
    warn "Flashing search: @ids";
    $self->stash(results => [ @ids ]);

    return $self->get_page();
};

helper query => sub {
    my $self = shift;
    my ($sql, @args) = @_;

    my $sth; $sth = $self->db->prepare($sql)
        and $sth->execute(@args)
        and return $sth;

    return undef;
};

helper quotetohtml => sub {
    my $self  = shift;
    my $quote = $self->stash('quote');

    $quote =~ s!&!&amp;!g;
    $quote =~ s!<!&lt;!g;
    $quote =~ s!>!&gt;!g;
    $quote =~ s!\n!<br />!g;
    $quote =~ s!($RE{URI}{HTTP}{-scheme=>'https?'})!<a href="$1">$1</a>!g;

    return $quote;
};

helper go_back => sub {
    my $self = shift;

    my $results = $self->flash('results');
    $self->flash(results => $results) if defined $results;
    warn "Flashing back: @{ $results }" if defined $results;
    warn "Not flashing back!" if not defined $results;

    $self->redirect_to($self->req->headers->referrer() // $self->url_for('/list'));
};

helper declare => sub {
    my $self  = shift;
    my $param = shift;
    $self->stash($param, undef) if defined $param;

    return $self;
};

helper results => sub {
    my $self = shift;
    my $res = $self->stash('results');

    return defined $res if not wantarray;
    return @{ $res // [] };
};

helper make_link => sub {
    my $self = shift;
    my $num  = shift;
    my $name = shift // $num;
    my $base = $self->stash('pagebase');

    return sprintf '<a href="%s">%s</a>', $self->url_for("$base/$num"), $name;
};

app->db->do(
'CREATE TABLE IF NOT EXISTS quotes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT,
        vote INTEGER DEFAULT 0,
        approved BOOLEAN DEFAULT 0
)');

app->secrets(app->config()->{secrets});
app->start();

__DATA__

@@ login.html.ep
% layout 'base';
% title 'Admin login';
% my $logindiv = 'loginformdiv';
% $logindiv = 'loginsuccessfuldiv' if session 'admin';
%= include "$logindiv"


@@ loginformdiv.html.ep
% if (defined $error) { include 'loginerrordiv' }
<div class="form">
%= form_for url_for("/admin") => (method => 'post') => begin
  Login using admin username:
  %= text_field 'admin'
  And password:
  %= password_field 'pass'
  %= submit_button 'Login'
%= end
</div>


@@ loginsuccessfuldiv.html.ep
<div class="success">Logged in</div>


@@ loginerrordiv.html.ep
<div class="error">
  Error: <%= $error =>
</div>


@@ approved.html.ep
% layout 'base';
% title 'Quote approved!';
Quote approved:
%= include 'quotediv'


@@ deleted.html.ep
% layout 'base';
% title 'Quote deleted!';
Quote deleted:
%= include 'quotediv'

@@ deleted.txt.ep
DELETED <%= $id =%>: <%= $quote =%>

@@ deleted.json.ep
% use JSON;
%== to_json({deleted => {id => $id, vote => $vote, text => $quote}});


@@ quote.html.ep
% layout 'base';
% title "Quote $id";
%= include 'quotediv'

@@ quote.txt.ep
<%== $id %> (<%== $vote %>):
<%== $quote =%>

@@ quote.json.ep
% use JSON;
%== to_json({id => $id, vote => $vote, text => $quote});


@@ quotediv.html.ep
%= tag div => (class => 'quote') => (id => $id) => begin
  %= tag div => (class => 'controls') => begin
      % if (session 'admin') {
          %= tag div => (class => 'control') => begin
            % if (not $approved) {
            %= link_to Approve => url_for("/quote/$id/approve");
            |
            % }
            %= link_to Edit => url_for("/quote/$id/edit");
            |
            %= link_to Del  => url_for("/quote/$id/delete");
          %= end
      % }
      %= link_to "#$id" => url_for("/quote/$id");
      (
      %= $vote
      %= link_to '+' => url_for("/quote/$id/voteup") => (class => 'vote')
      /
      %= link_to '-' => url_for("/quote/$id/votedn") => (class => 'vote')
      )
  %= end
  %= tag div => (class => 'text') => begin
  %== $self->quotetohtml
  %= end
%= end


@@ pager.html.ep
%= tag div => (class => 'pager') => begin
  %= include 'prev-link'
  %= include 'page-list'
  %= include 'next-link'
%= end


@@ prev-link.html.ep
% if ( $page == 1 ) {
  &lt;&lt; Prev
% }
% else {
  %== make_link($page-1, '<< Prev')
% }


@@ next-link.html.ep
% if ( $page == $pages ) {
  Next &gt;&gt;
% }
% else {
  %== make_link($page+1, 'Next >>')
% }

@@ page-list.html.ep
% foreach my $link ( 1 .. $pages ) {
  % if ( $link == $page ) {
    %= $link
  % }
  % else {
    %== make_link($link)
  % }
% }

@@ waiting.html.ep
% layout 'base';
% title 'Waiting approval';
% foreach my $id ($self->getids(0)) {
  % $self->getquote($id);
  %= include 'quotediv'
% }


@@ list.html.ep
% layout 'base';
% title 'List';
% my @list = $self->results() ? $self->results() : $self->getids();
% foreach my $id (@list) {
  % $self->getquote($id);
  %= include 'quotediv'
% }
% if (defined stash 'pages') {
  %= include 'pager'
% }

@@ list.txt.ep
% foreach my $id ($self->getids()) {
% $self->getquote($id);
<%= include 'quote' %>
% }

@@ list.json.ep
% use JSON;
% my @list = ();
% foreach my $id ($self->getids()) {
%   push @list, $self->getquote($id);
% }
%== to_json(\@list); 


@@ add.html.ep
% layout 'base';
% title 'Add new quote';
Add a new quote:
%= form_for url_for('/add') => (method => 'post') => (class => 'add') => begin
%= text_area 'quote'
<br />
%= submit_button 'Submit!'
%= end


@@ edit.html.ep
% layout 'base';
% title "Edit quote $id";
%= include 'quotediv'
%= form_for url_for("/quote/$id/edit") => (method => 'post') => (class => 'edit') => begin
%= text_area 'quote' => $quote
<br />
%= submit_button 'Edit!'
%= end


@@ layouts/base.html.ep
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
      <title><%= title %> - <%= app->config()->{title} %></title>
      %= stylesheet '/res/style.css'
  </head>
  <body>
    %= tag div => (class => 'nav') => begin
    %= link_to List => url_for('/list')
    |
    %= link_to Add  => url_for('/add')
    |
    % if (session 'admin') {
    %= link_to 'Waiting approval' => url_for('/waiting')
    |
    %= link_to 'Logout' => url_for('/logout')
    % }
    % else {
    %= link_to 'Login' => url_for('/admin')
    % }
    %= end
    %= form_for url_for('/search') => (method => 'post') => (class => 'search') => begin
    %= text_field 'search'
    %= submit_button 'Search!'
    %= end
    %= content
  </body>
</html>
