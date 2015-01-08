#!/usr/bin/env perl

use strict;
use warnings;

use DBI;

my $sqlite_db  = shift @ARGV;
my $sqlite_dsn = "dbi:SQLite:dbname=$sqlite_db";

print "Connecting to SQLite database: $sqlite_db\n";
my $sqlite     = DBI->connect($sqlite_dsn, undef, undef,
        { sqlite_unicode => 1, AutoCommit => 1, RaiseError => 1 });

print "Reading in Postgresql configuration\n";
my $config     = do 'qdb.conf';

my $pg_dsn     = $config->{database}{dsn};
my $pg_user    = $config->{database}{username};
my $pg_pass    = $config->{database}{password};
my $pg_options = $config->{database}{options};

print "Connecting to Postgresql database\n";
my $pg         = DBI->connect($pg_dsn, $pg_user, $pg_pass, $pg_options);

print "Recreating quotes table in the Postgresql database\n";
$pg->do('DROP TABLE quotes');
$pg->do(
'CREATE TABLE IF NOT EXISTS quotes (                                            
        id SERIAL PRIMARY KEY,                                                  
        text TEXT,                                                              
        vote INTEGER DEFAULT 0,                                                 
        approved BOOLEAN DEFAULT FALSE                                          
)');

my $sth; $sth = $sqlite->prepare('SELECT * FROM quotes') and $sth->execute();
my $ins; $ins = $pg->prepare('INSERT INTO quotes (id, text, vote, approved) VALUES (?, ?, ?, ?)');
while (defined( my $quote = $sth->fetchrow_hashref() )) {
    print "Inserting: " . $quote->{id} . "\n";
    $ins->execute(@{ $quote }{'id', 'text', 'vote', 'approved'});
}

$pg->do('SELECT setval("quotes_id_seq", (SELECT MAX(id) FROM quotes))');
