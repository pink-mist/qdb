#!/home/suppy/perl5/perlbrew/perls/perl-5.16.2/bin/perl

use strict;
use warnings;

use Mojolicious::Lite;
use Regexp::Common qw/ URI /;

plugin 'Config';

plugin 'Database'; #configuration in qdb.conf file

helper getquote => sub {
    my $self = shift;
    my $id   = shift;

    if ($id eq 'random') {
        my @ids = $self->getids();
        $id = $ids[rand @ids] // 0;
    }

    my $ref = { id => 0, text => 'No quote found', vote => 0 };
    my $sth; $sth = $self->db->prepare('SELECT * FROM quotes WHERE id = ?')
        and $sth->execute($id)
        and $ref = $sth->fetchrow_hashref() // $ref;
    chomp $ref->{text};
    $ref->{text} =~ s!\r!!g;
    $self->stash(id    => $ref->{id});
    $self->stash(quote => $ref->{text});
    $self->stash(vote  => $ref->{vote});
    return $ref;
};

helper getids => sub {
    my $self = shift;

    my $ref = [ [ 0 ] ];
    my $sth; $sth = $self->db->prepare('SELECT id FROM quotes')
        and $sth->execute()
        and $ref = $sth->fetchall_arrayref();

    return map { $_->[0] } @{$ref};
};

helper addquote => sub {
    my $self  = shift;
    my $quote = shift;
    $quote    =~ s!\r!!g;

    my $id = 0;
    my $sth; $sth = $self->db->prepare('INSERT INTO quotes (text) VALUES (?)')
        and $sth->execute($quote)
        and $id = $self->db->last_insert_id('', '', 'quotes', '');
    $self->getquote($id);
};

helper dbinit => sub {
    my $self = shift;

    $self->db->do('CREATE TABLE IF NOT EXISTS quotes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT,
        vote INTEGER DEFAULT 0)')
    and return $self->render(text => 'DB Initialized.');
    $self->render(text => 'DB Failed to initialize.');
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

helper vote => sub {
    my $self = shift;
    my $id   = shift;
    my $vote = shift;

    my $ref = $self->getquote($id);
    my $sth; $sth = $self->db->prepare('UPDATE quotes SET vote = ? WHERE id = ?')
        and $sth->execute($ref->{'vote'} + $vote, $id);

    $self->getquote($id);
};

helper search => sub {
    my $self = shift;
    my $text = shift;

    $text    =~ s/^| |$/%/g;
    my $ref  = [ [ 0 ] ];
    my $sth; $sth = $self->db->prepare('SELECT id FROM quotes WHERE text LIKE ?')
        and $sth->execute($text)
        and $ref  = $sth->fetchall_arrayref() // [];

    my @ids  = map { $_->[0] } @{$ref};
    my $id   = $ids[rand @ids] // 0;

    #$self->getquote($id);
    return $id;
};

helper delquote => sub {
    my $self = shift;
    my $id   = shift;

    $self->getquote($id);
    my $sth; $sth = $self->db->prepare('DELETE FROM quotes WHERE id = ?')
        and $sth->execute($id);
};

helper editquote => sub {
    my $self = shift;
    my $id   = shift;
    my $text = shift;

    my $sth; $sth = $self->db->prepare('UPDATE quotes SET text = ? WHERE id = ?')
        and $sth->execute($text, $id);
    $self->getquote($id);
};

get '/' => sub {
    my $self = shift;
    
    $self->getquote('random');
    $self->render('quote');
};

any '/init' => sub {
    shift->dbinit();
};

get '/add' => sub {
    my $self = shift;

    $self->render('add');
};

post '/add' => sub {
    my $self  = shift;
    my $quote = $self->param('quote');

    $self->addquote($quote);
    $self->render('quote');
};

get '/edit/:id' => sub {
    my $self  = shift;
    my $id    = $self->param('id');

    $self->getquote($id);
    $self->render('edit');
};

post '/edit/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');
    my $text = $self->param('quote');

    $self->editquote($id, $text);
    $self->render('edit');
};

get '/list' => sub {
    my $self = shift;

    $self->render('list');
};

post '/search' => sub {
    my $self   = shift;
    my $search = $self->param('search');

    my $id = $self->search($search);

    $self->getquote($id);
    $self->render('quote');
};

get '/voteup/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->vote($id, 1);
    $self->render('quote');
};

get '/votedn/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->vote($id, -1);
    $self->render('quote');
};

get '/del/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->getquote($id);
    $self->render('del');
};

post '/del/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');
    my $pass = $self->param('pass');

    return $self->render(text => 'Access denied') if $pass ne app->config()->{password};

    $self->delquote($id);
    $self->render('deleted');
};

get '/:id' => sub {
    my $self = shift;
    my $id   = $self->param('id');

    $self->getquote($id);
    $self->render('quote');
};

app->secret(app->config()->{secrets});
app->start();

__DATA__

@@ del.html.ep
% layout 'base';
% title "Really delete quote $id?";
Do you really want to delete this quote?
<br />
%= form_for url_for("/del/$id") => (method => 'post') => begin
  Confirm with password:
  %= text_field 'pass'
  %= submit_button 'Confirm'
%= end
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
  %= tag div => (class => 'control') => begin
    %= link_to Edit => url_for("/edit/$id");
    |
    %= link_to Del  => url_for("/del/$id");
  %= end
  %= link_to "#$id" => url_for("/$id");
  (
  %= $vote
  %= link_to '+' => url_for("/voteup/$id") => (class => 'vote')
  /
  %= link_to '-' => url_for("/votedn/$id") => (class => 'vote')
  )
  <br />
  %== $self->quotetohtml
%= end


@@ list.html.ep
% layout 'base';
% title 'List';
% foreach my $id ($self->getids()) {
  % $self->getquote($id);
  %= include 'quotediv'
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
%= form_for url_for("/edit/$id") => (method => 'post') => (class => 'edit') => begin
%= text_area 'quote' => $quote
<br />
%= submit_button 'Edit!'
%= end


@@ layouts/base.html.ep
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
      <title><%= title %> - #mylittlepony quotes</title>
      %= stylesheet '/res/style.css'
  </head>
  <body>
    %= tag div => (class => 'nav') => begin
    %= link_to List => url_for('/list')
    |
    %= link_to Add  => url_for('/add')
    %= end
    %= form_for url_for('/search') => (method => 'post') => (class => 'search') => begin
    %= text_field 'search'
    %= submit_button 'Search!'
    %= end
    %= content
  </body>
</html>
