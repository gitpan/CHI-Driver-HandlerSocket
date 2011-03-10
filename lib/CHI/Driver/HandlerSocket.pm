
package CHI::Driver::HandlerSocket;

use strict;
use warnings;

use Moose;
use Moose::Util::TypeConstraints;

use Net::HandlerSocket;
use Carp 'croak';

extends 'CHI::Driver';

use 5.006;
our $VERSION = '0.99';

=head1 NAME

CHI::Driver::HandlerSocket - Use DBI for cache storage, but access it using the Net::HandlerSocket API for MySQL

=head1 SYNOPSIS

 use CHI;

 # Supply a DBI handle
 #
 my $cache = CHI->new( driver => 'HandlerSocket', dbh => DBI->connect(...) );

 # or a DBIx::Connector
 my $cache = CHI->new( driver => 'HandlerSocket', dbh => DBIx::Connector->new(...) );

 # or code that generates a DBI handle
 #
 my $cache = CHI->new( driver => 'HandlerSocket', dbh => sub { ...; return $dbh } );

=head1 DESCRIPTION

This driver uses a MySQL database table to store the cache.  
It accesses it by way of the Net::HandlerSocket API and associated MySQL plug-in:

L<http://yoshinorimatsunobu.blogspot.com/2010/10/using-mysql-as-nosql-story-for.html>

L<https://github.com/ahiguti/HandlerSocket-Plugin-for-MySQL>

Why cache things in a database?  Isn't the database what people are trying to
avoid with caches?  

This is often true, but a simple primary key lookup is extremely fast in MySQL and HandlerSocket absolutely screams,
avoiding most of the locking that normally happens and completing as many updates/queries as it can at once under the same lock.
Avoiding parsing SQL is also a huge performance boost.

=head1 ATTRIBUTES

=over

=item host

=item read_port

=item write_port

Host and port the MySQL server with the SocketHandler plugin is running on.  The connection is TCP.
Two connections are used, one for reading, one for writing, following the design of L<Net::HandlerSocket>.
The write port locks the table even for reads, reportedly.
Default is C<localhost>, C<9998>, and C<9999>.

=item namespace

The namespace you pass in will be appended to the C<table_prefix> and used as a
table name.  That means that if you don't specify a namespace or table_prefix
the cache will be stored in a table called C<chi_Default>.

=item table_prefix

This is the prefix that is used when building a table name.  If you want to
just use the namespace as a literal table name, set this to undef.  Defaults to
C<chi_>.

=item dbh

The DBI handle used to communicate with the db. 

You may pass this handle in one of three forms:

=over

=item *

a regular DBI handle

=item *

a L<DBIx::Connector|DBIx::Connector> object

=item *

a code reference that will be called each time and is expected to return a DBI
handle, e.g.

    sub { My::Rose::DB->new->dbh }

=back

The last two options are valuable if your CHI object is going to live for
enough time that a single DBI handle might time out, etc.

=head1 Authors

L<CHI::Driver::HandlerSocket> by Scott Walters (scott@slowass.net) for Plain Black Corp, L<http://plainblack.com>.
L<CHI::Driver::HandlerSocket> is based on L<CHI::Driver::DBI>.

L<CHI::Driver::DBI> Authors:  Original version by Justin DeVuyst and Perrin Harkins. Currently maintained by
Jonathan Swartz.

=head1 COPYRIGHT & LICENSE

Copyright (c) Plain Black Corp 2011
Copyright (c) Scott Walters (scrottie) 2011
Copyright (c) Justin DeVuyst

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

my $type = __PACKAGE__;

subtype "$type.DBIHandleGenerator" => as 'CodeRef';
subtype "$type.DBIXConnector"      => as 'DBIx::Connector';
subtype "$type.DBIHandle"          => as 'DBI::db';

coerce "$type.DBIHandleGenerator" => from "$type.DBIXConnector" => via {
    my $dbixconn = $_;
    sub { $dbixconn->dbh }
};
coerce "$type.DBIHandleGenerator" => from "$type.DBIHandle" => via {
    my $dbh = $_;
    sub { $dbh }
};

has 'dbh' => ( is => 'ro', isa => "$type.DBIHandleGenerator", coerce => 1 );

has 'table_prefix' => ( is => 'rw', isa => 'Str', default => 'chi_', );

has 'host' => ( is => 'ro', default => 'localhost', );

has 'read_port' => ( is => 'ro', default => 9998, );

has 'write_port' => ( is => 'ro', default => 9999, );

has 'read_index' => ( is => 'ro', default => 1, );

has 'write_index' => ( is => 'ro', default => 1, );

has 'read_hs' => ( is => 'rw', isa => 'Net::HandlerSocket', );

has 'write_hs' => ( is => 'rw', isa => 'Net::HandlerSocket', );

__PACKAGE__->meta->make_immutable;

sub BUILD {
    my ( $self, $args ) = @_;
    
    my $dbh = $self->dbh->();

    my $table   = $self->_table; # don't quote it
    
    my $database_name = do { 
        my $sth = $dbh->prepare( qq{ SELECT database() AS dbname } ) or die $dbh->errstr;
        $sth->execute or die $sth->errstr;
        my @row = $sth->fetchrow_array or die "couldn't figure out the name of the database";
        $sth->finish;
        $row[0];
    };

    # warn "host: @{[ $self->host ]} port: @{[ $self->read_port ]} database_name: $database_name table: $table read_index: @{[ $self->read_index ]} write_index: @{[ $self->write_index ]}";

    # if ( $args->{create_table} ) {
        $dbh->do( qq{
            CREATE TABLE IF NOT EXISTS $table ( `key` VARCHAR( 600 ), `value` TEXT, PRIMARY KEY ( `key` ) )
        } ) or croak $dbh->errstr;
    # }

    # from https://github.com/ahiguti/HandlerSocket-Plugin-for-MySQL/blob/master/docs-en/perl-client.en.txt:

    # The first argument for open_index is an integer value which is
    # used to identify an open table, which is only valid within the
    # same Net::HandlerSocket object. The 4th argument is the name of
    # index to open. If 'PRIMARY' is specified, the primary index is
    # open. The 5th argument is a comma-separated list of column names.

    my $read_hs = Net::HandlerSocket->new({ host => $self->host, port => $self->read_port, }) or die;
    $read_hs->open_index($self->read_index, $database_name, $table, 'PRIMARY', 'value') and die $read_hs->get_error;
    $self->read_hs($read_hs);

    my $write_hs = Net::HandlerSocket->new({ host => $self->host, port => $self->write_port, });
    $write_hs->open_index($self->write_index, $database_name, $table, 'PRIMARY', 'key,value') and die $write_hs->get_error;
    $self->write_hs($write_hs);

    return;
}
 
sub _table {
    my $self = shift;
    return $self->table_prefix() . $self->namespace();
}

sub fetch {
    my ( $self, $key, ) = @_;

    my $index = $self->read_index;
    my $hs = $self->read_hs;

    # from https://github.com/ahiguti/HandlerSocket-Plugin-for-MySQL/blob/master/docs-en/perl-client.en.txt:

    # The first argument must be an integer which has specified as the
    # first argument for open_index on the same Net::HandlerSocket
    # object. The second argument specifies the search operation. The
    # current version of handlersocket supports '=', '>=', '<=', '>',
    # and '<'. The 3rd argument specifies the key to find, which must
    # an arrayref whose length is equal to or smaller than the number
    # of key columns of the index. The 4th and the 5th arguments
    # specify the maximum number of records to be retrieved, and the
    # number of records skipped before retrieving records. The columns
    # to be retrieved are specified by the 5th argument for the
    # corresponding open_index call.

    my $res = $hs->execute_single($index, '=', [ $key ], 1, 0);
    my $status = shift @$res;  $status and die $hs->get_error;
    return $res->[0];

}   

    
sub store_xx {
    my ( $self, $key, $data, ) = @_;

    my $dbh = $self->dbh->();
    my $table   = $dbh->quote_identifier( $self->_table );

    my $sth = $dbh->prepare_cached( qq{
          INSERT INTO $table
           ( `key`, `value` )
           VALUES ( ?, ? )
           ON DUPLICATE KEY UPDATE `value`=VALUES(`value`)
    } );
    $sth->execute( $key, $data );
    $sth->finish;

    return;
}

sub store {
    my ( $self, $key, $data, ) = @_;

    my $index = $self->write_index;
    my $hs = $self->write_hs;

    # from https://github.com/ahiguti/HandlerSocket-Plugin-for-MySQL/blob/master/docs-en/perl-client.en.txt:

    # The 6th argument for execute_single specifies the modification
    # operation. The current version supports 'U' and 'D'. For the 'U'
    # operation, the 7th argument specifies the new value for the row.

    my $res;
    my $status;

    my $rarr = $hs->execute_multi( [
        [ $index, '=', [ $key ], 1, 0, 'D' ],                   # gaaah
        [ $index, '+', [ $key, $data ] ],
    ] );
    for my $res (@$rarr) {
      die $hs->get_error() if $res->[0] != 0;
      # results in shift(@$res);
    }

    return;
}

sub remove {
    my ( $self, $key, ) = @_;

    my $index = $self->write_index;
    my $dbh = $self->dbh->();
    my $hs = $self->write_hs;

    my $res = $hs->execute_single($index, '=', [ $key ], 1, 0, 'D');
    my $status = shift @$res;  $status and die $hs->get_error;

    return;
}

sub clear { 
    my $self = shift;

    my $dbh = $self->dbh->();
    my $table   = $dbh->quote_identifier( $self->_table );
            
    my $sth = $dbh->prepare_cached( qq{ DELETE FROM $table } ) or croak $dbh->errstr;
    $sth->execute() or croak $sth->errstr;
    $sth->finish();
    
    return;
}

sub get_keys {
    my ( $self, ) = @_;

    my $dbh = $self->dbh->();
    my $table   = $dbh->quote_identifier( $self->_table );
    
    my $sth = $dbh->prepare_cached( "SELECT DISTINCT `key` FROM $table" ) or croak $dbh->errstr;
    $sth->execute() or croak $sth->errstr;
    my $results = $sth->fetchall_arrayref( [0] );
    $_ = $_->[0] for @{$results};

    return @{$results};
}

sub get_namespaces { croak 'not supported' }
    
1;

__END__

#=item read_index
#
#=item write_index
#
#L<Net::SocketHandler> wants user-selected index numbers rather than statement handles for each table/primary key/server port
#combination it is to operate on.
#C<read_index> and C<write_index> will often be the same number; one slot is on the read port, the other on the write port.
#Right now, it doesn't keep track of the highest number used or otherwise aid the user with allocating these numbers.
#You have to do it yourself.  And you have to tell this module which index slot numbers you've allocated to it.
#You don't have to do anything else with these numbers other than not use them in your own calls to L<Net::SocketHandler>.
#If you aren't using L<Net::SocketHandler> directly and none of the other modules you're using are either, C<1> and C<1> are
#perfectly acceptable choices and is in fact are the defaults.

