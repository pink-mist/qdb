#!/home/suppy/perl5/perlbrew/perls/perl-5.16.2/bin/perl

use strict;
use warnings;

use 5.010.001;

use Mojolicious::Lite; # gives us: app, plugin, helper, under, group, post, get
use Regexp::Common qw/ URI /;
use POSIX qw/ ceil /;
use Mojo::Pg;

plugin 'Config';

# Check if usergroup is configured
if (defined(my $usergroup = app->config()->{usergroup})) {
    plugin SetUserGroup => $usergroup;
}

# Check for captcha configuration
if (defined(my $captcha = app->config()->{captcha})) {
    plugin 'Captcha::reCAPTCHA' => $captcha;
    helper validate => sub {
       my $self = shift;

       my $params = $self->req->params->to_hash;

       return $self->validate_recaptcha($params);
    };
    helper captcha => sub {
        my $self = shift;
        $self->use_recaptcha();
        return $self;
    };
}
else {
    helper captcha => sub { shift->stash(recaptcha_html => '') };
    helper validate => sub { return 1 };
}

my $pg = do {
    my $dsn     = app->config()->{database}{dsn} // 'dbi:Pg:dbname=qdb';
    my $user    = app->config()->{database}{username} // '';
    my $pass    = app->config()->{database}{password} // '';
    my $options = app->config()->{database}{options};

    Mojo::Pg->new()->
        dsn($dsn)->
        options($options)->
        username($user)->
        password($pass);
};

app->secrets(app->config()->{secrets});

## Route section
under sub { shift->session(expiration => 604_800); }; #1 week

get  '/'                  => sub { shift->latest()->render('list');                                            };
get  '/quote/:id'         => sub { shift->loadquote()->render('quote');                                        };
post '/quote/:id'         => sub { shift->loadquote()->vote()->render('quote');                                };
get  '/random'            => sub { shift->loadquote('random')->render('quote');                                };
get  '/list'              => sub { shift->get_page(1)->stash(pagebase => '/list')->render('list');             };
get  '/list/:page'        => sub { shift->get_page( )->stash(pagebase => '/list')->render('list');             };
get  '/top'               => sub { shift->top()->get_page(1)->stash(pagebase => '/top')->render('list');       };
get  '/top/:page'         => sub { shift->top()->get_page( )->stash(pagebase => '/top')->render('list');       };
get  '/bottom'            => sub { shift->bottom()->get_page(1)->stash(pagebase => '/bottom')->render('list'); };
get  '/bottom/:page'      => sub { shift->bottom()->get_page( )->stash(pagebase => '/bottom')->render('list'); };
post '/search'            => sub { shift->searchquote()->stash(pagebase => '/search')->render('list');         };
get  '/search/:page'      => sub { shift->get_search_page()->stash(pagebase => '/search')->render('list');     };
get  '/admin'             => sub { shift->declare('error')->render('login');                                   };
post '/admin'             => sub { shift->login()->render('login');                                            };

group {
    get  '/add'               => sub { shift->captcha()->render('add');                                                       };

    under sub { shift->validate() and return 1; return undef; };

    post '/add'               => sub { shift->addquote()->render('quote');                                         };
};

group {
    under sub { shift->checklogin() and return 1; return undef; };

    get  '/waiting'           => sub { shift->render('waiting');                                                   };
    get  '/quote/:id/edit'    => sub { shift->loadquote()->render('edit');                                         };
    post '/quote/:id/edit'    => sub { shift->editquote()->render('quote');                                        };
    get  '/quote/:id/approve' => sub { shift->approvequote()->go_back()                                            };
    get  '/quote/:id/delete'  => sub { shift->deletequote()->go_back()                                             };
    get  '/logout'            => sub { shift->logout()->render('login');                                           };
};

## Helper section
helper db => sub { $pg->db() };

helper loadquote => sub {
    my $self = shift;
    my $id   = shift // $self->param('id');
    $self->getquote($id);

    return $self;
};

helper vote => sub {
    my $self = shift;
    my $id   = $self->param('id');
    my $vote = $self->param('vote'); $self->clamp($vote, -1, 1);

    my $ref = $self->getquote($id);
    $self->query('UPDATE quotes SET vote = ? WHERE id = ?', $ref->{'vote'} + $vote, $id);

    $self->loadquote($id);
};

helper addquote => sub {
    my $self  = shift;
    my $quote = $self->param('quote');
    $quote    =~ s!\r!!g;

    my $id = 0;
    $id = $self->db->dbh->last_insert_id('', '', 'quotes', '') if defined
        $self->query('INSERT INTO quotes (text) VALUES (?)', $quote);
    $self->loadquote($id);
};

helper searchquote => sub {
    my $self = shift;
    my $text = $self->param('search');

    $text    =~ s/^| |$/%/g;
    my $ref  = $self->query_all('SELECT id FROM quotes WHERE LOWER(text) LIKE LOWER(?) AND approved = TRUE ORDER BY id ASC', $text) // [];

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

    $self->query('UPDATE quotes SET approved = TRUE WHERE id = ?', $id);
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
    my $approved = shift // 'TRUE';

    my $ref = $self->query_all('SELECT id FROM quotes WHERE approved = ? ORDER BY id ASC', $approved) // [ [ 0 ] ];
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

helper top => sub {
    my $self = shift;
    my $ref  = $self->query_all('SELECT id FROM quotes WHERE approved = TRUE ORDER BY vote DESC, id ASC') // [ [ 0 ] ];
       $ref  = [ [ 0 ] ] unless (@{$ref});
    my @ids  = map { $_->[0] } @{$ref};

    $self->stash(results => [@ids]);

    return $self;
};

helper bottom => sub {
    my $self = shift;
    my $ref  = $self->query_all('SELECT id FROM quotes WHERE approved = TRUE ORDER BY vote ASC, id ASC') // [ [ 0 ] ];
       $ref  = [ [ 0 ] ] unless (@{$ref});
    my @ids  = map { $_->[0] } @{$ref};

    $self->stash(results => [@ids]);

    return $self;
};

helper latest => sub {
    my $self = shift;
    my $ref  = $self->query_all('SELECT id FROM quotes WHERE approved = TRUE ORDER BY id DESC') // [ [ 0 ] ];
       $ref  = [ [ 0 ] ] unless (@{$ref});
    my @ids  = map { $_->[0] } @{$ref};
    my @res   = grep { defined } @ids[0 .. 4];
       @res   = (0) unless @res;

    $self->stash(results => [ @res ]);

    return $self;
};

helper query => sub {
    my $self = shift;
    my ($query, @args) = @_;

    my $res = eval {
        my $sth = $self->db->dbh->prepare($query);
        $sth->execute(@args);
        $sth;
    };

    app->log->error("Could not execute DB Query:", $query, "With args:", @args, "Error: $@") if not defined $res;
    return $res;
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

helper clamp => sub {
    my $self = shift;
    my ($val, $min, $max) = @_;

    $val = $max if $val > $max;
    $val = $min if $val < $min;

    $_[0] = $val;

    return $self;
};

app->query_row('SELECT * FROM pg_class WHERE relname=?', 'quotes') //
app->db->dbh->do(
'CREATE TABLE IF NOT EXISTS quotes (
        id SERIAL PRIMARY KEY,
        text TEXT,
        vote INTEGER DEFAULT 0,
        approved BOOLEAN DEFAULT FALSE
)');

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

      %= form_for url_for("/quote/$id") => (method => 'post') => ( id => "vote-form-$id" ) => (class => 'vote') => begin
      %= hidden_field 'vote'
      %= link_to '+' => "javascript:vote('vote-form-$id', '1')" => (class => 'vote')
      /
      %= link_to '-' => "javascript:vote('vote-form-$id', '-1')" => (class => 'vote')
      %= end

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
% foreach my $id ($self->getids('FALSE')) {
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
%== $recaptcha_html;
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
      <script language="JavaScript" type="text/javascript">
        function vote ( id, vote ) {
            var form = document.getElementById( id );
            form.vote.value = vote;
            form.submit();
        }
      </script>
  </head>
  <body>
    %= tag div => (class => 'nav') => begin
    %= link_to Latest => url_for('/')
    |
    %= link_to List => url_for('/list')
    |
    %= link_to Top => url_for('/top')
    |
    %= link_to Bottom => url_for('/bottom')
    |
    %= link_to Random => url_for('/random')
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
