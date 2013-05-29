package MongoNet::IMAP;

use v5.14;
use strict;
use warnings;

use Mouse;
use MouseX::Foreign 'Mojo::EventEmitter';
use MIME::Base64 qw/ decode_base64 encode_base64 /;

# Some data - probably needs outsourcing
has 'hostname'  => ( is => 'rw' );
has 'db' => ( is => 'rw' );

# Callbacks
has 'user_auth' => ( is => 'rw' );

sub respond {
    my ($self, $stream, @cmd) = @_;

    my $c = join ' ', @cmd;
    $stream->write("$c\r\n");
    print "Sent: $c\n";
    return;
}

sub accept {
    my ($self, $loop, $stream, $id) = @_;

    print "Accepted connection\n";

    my $db = $self->db;
    my $mailboxes = $db->get_collection('mailboxes');
    my $store = $db->get_collection('store');

    $self->respond($stream, '* OK', '[CAPABILITY IMAP4REV1 AUTH=LOGIN]', $self->hostname, " IMAP4rev1 - Experimental Mojo::IOLoop IMAP4 Server");

    my $buffer = '';
    my $datamode = 0;
    my $auth = undef;
    my $authtype = '';
    my $email = {};

    $stream->on(error => sub {
        print "Stream error\n";
    });
    $stream->on(close => sub {
        print "Stream closed\n";
    });
    $stream->on(read => sub {
        my ($stream, $chunk) = @_;

        print "Received chunk '$chunk'\n";

        $buffer .= $chunk;

        return unless $buffer =~ /\r\n$/gs;

        my ($id, $cmd, $data) = $buffer =~ m/^([\w\d]+)\s*(\w+)\s?(.*)\r\n$/s;
        $buffer = '';

        print "Got id[$id], cmd[$cmd], data[$data]\n";

        for(uc $cmd) {
            when (/^LOGIN$/) {
                my ($username, $password) = $data =~ /"(.*)"\s"(.*)"/;
                my $user = &{$self->user_auth}($username, $password);
                if($user) {
                    $auth->{success} = 1;
                    $auth->{username} = $username;
                    $auth->{password} = $password;
                    $auth->{user} = $user;
                    $self->respond($stream, $id, 'OK', '[CAPABILITY IMAP4REV1] User authenticated');
                } else {
                    $auth = {};
                    $self->respond($stream, $id, 'BAD', '[CAPABILITY IMAP4REV1] User authentication failed');
                }
            }
            when (/^LSUB$/) {
                if($auth && $auth->{success}) {
                    for my $sub (keys %{$auth->{user}->{store}->{children}}) {
                        $self->respond($stream, '*', 'LSUB () "."', $sub);
                    }
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^LIST$/) {
                my ($um, $sub) = $data =~ /"(.*)"\s"(.*)"/;
                if($auth && $auth->{success}) {
                    if($auth->{user}->{store}->{children}->{$sub}) {
                        $self->respond($stream, '*', 'LIST (\HasNoChildren) "." "' . $sub . '"');
                    }
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^SELECT$/) {
                my ($sub) = $data =~ /"(.*)"/;
                if($auth->{user}->{store}->{children}->{$sub}) {
                    my $exists = $auth->{user}->{store}->{children}->{$sub}->{seen} + $auth->{user}->{store}->{children}->{$sub}->{unseen};
                    my $recent = $auth->{user}->{store}->{children}->{$sub}->{unseen};
                    $self->respond($stream, '*', 'FLAGS ()');
                    $self->respond($stream, '*', $exists . ' EXISTS');
                    $self->respond($stream, '*', $recent . ' RECENT');
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^UID$/) {
                if($data =~ /^fetch (\d+)(:(\d+|\*))? \((.*)\)/) {
                    my $from = $1;
                    my $to = $3;
                    my $args = $4;
                    print "Got FROM: $1, 2[$2], TO: $3, ARGS: $args\n";
                    my $query = {
                        mailbox => {
                            domain => $auth->{user}->{domain},
                            user => $auth->{user}->{mailbox},
                        },
                    };
                    if($to) {
                        $query->{uid} = {
                            '$gte' => int($from)
                        };
                        if($to ne '*') {
                            $query->{uid} = {
                                '$lte' => int($to)
                            };
                        }
                    } else {
                        $query->{uid} = int($from);
                    }
                    my $messages = $store->find($query);
                    if($args eq 'FLAGS') {
                        while (my $email = $messages->next) {   
                            my $flags = "";
                            for my $flag (@{$email->{flags}}) {
                                $flags .= "\\$flag ";
                            }
                            $self->respond($stream, '* '.$email->{uid}.' FETCH (FLAGS ('.$flags.') UID '.$email->{uid}.')');
                        }
                    } elsif ($args =~ /BODY\.PEEK/) {
                        while (my $email = $messages->next) {   
                            my $flags = "";
                            for my $flag (@{$email->{flags}}) {
                                $flags .= "\\$flag ";
                            }
                            $self->respond($stream, '* '.$email->{uid}.' FETCH (FLAGS ('.$flags.') RFC822.SIZE '.$email->{message}->{size}.' ENVELOPE ("'.$email->{message}->{headers}->{Date}.'" "'.$email->{message}->{headers}->{Subject}.'") UID '.$email->{uid}.')');
                        }
                    } elsif ($args =~ /BODY\[\]/) {
                        while (my $email = $messages->next) {   
                            my $flags = "";
                            for my $flag (@{$email->{flags}}) {
                                $flags .= "\\$flag ";
                            }
                            $self->respond($stream, '* '.$email->{uid}.' FETCH (UID '.$email->{uid}.' RFC822.SIZE '.$email->{message}->{size}.' BODY[] {'.$email->{message}->{size}.'}');
                            for my $hdr (keys %{$email->{message}->{headers}}) {
                                my $h = $email->{message}->{headers}->{$hdr};
                                if(ref $h =~ /ARRAY/) {
                                    for my $i (@$h) {
                                        $self->respond($stream, $hdr . ': ' . $i);
                                    }
                                } else {
                                    $self->respond($stream, $hdr . ': ' . $h);
                                }
                            }
                            $self->respond($stream, '');
                            $self->respond($stream, $email->{message}->{body});
                            $self->respond($stream, ')');
                            $self->respond($stream, '* '.$email->{uid}.' FETCH (FLAGS ('.$flags.'))');
                        }
                    }
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^NOOP$/) {
                $self->respond($stream, 250, "Ok.");
            }
            when (/^LOGOUT$/) {
                $self->respond($stream, '*', 'BYE', $self->hostname, 'server terminating connection');
                $self->respond($stream, $id, 'OK LOGOUT completed');
                $stream->on(drain => sub {
                    $stream->close;
                });
            }
            default {
                $self->respond($stream, $id, 'BAD', "Command not understood.");
            }
        }
    });
}

1;
