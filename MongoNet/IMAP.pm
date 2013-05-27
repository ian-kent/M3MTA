package MongoNet::IMAP;

use v5.14;
use strict;
use warnings;

use Mouse;
use MouseX::Foreign 'Mojo::EventEmitter';
use MIME::Base64 qw/ decode_base64 encode_base64 /;

# Some data - probably needs outsourcing
has 'hostname'  => ( is => 'rw' );

# Callbacks
has 'user_auth' => ( is => 'rw' );

sub respond {
    my ($self, $stream, @cmd) = @_;

    my $c = join ' ', @cmd;
    $stream->write("$c\n");
    print "Sent: $c\n";
    return;
}

sub accept {
    my ($self, $loop, $stream, $id) = @_;

    print "Accepted connection\n";

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
                $self->respond($stream, $id, 'OK', '[CAPABILITY IMAP4REV1] User authenticated');
            }
            when (/^LSUB$/) {
                $self->respond($stream, '*', 'LSUB () "."', 'INBOX');
                $self->respond($stream, $id, 'OK');
            }
            when (/^LIST$/) {
                if($data eq '"" "INBOX"') {
                    $self->respond($stream, '*', 'LIST (\HasNoChildren) "." "INBOX"');
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^SELECT$/) {
                if($data eq '"INBOX"') {
                    $self->respond($stream, '*', 'FLAGS ()');
                    $self->respond($stream, '*', '1 EXISTS');
                    $self->respond($stream, '*', '0 RECENT');
                }
                $self->respond($stream, $id, 'OK');
            }
            when (/^UID$/) {
                if($data =~ /^fetch (\d+)(:(\d+|\*))? \((.*)\)/) {
                    my $from = $1;
                    my $to = $3;
                    my $args = $4;
                    print "Got ARGS: $args\n";
                    if($args eq 'FLAGS') {
                        $self->respond($stream, '* 1 FETCH (FLAGS (\Seen) UID 1234)');
                    } elsif ($args =~ /BODY\.PEEK/) {
                        $self->respond($stream, '* 1 FETCH (FLAGS (\Seen) RFC822.SIZE 192 ENVELOPE ("Mon, 27 May 2013 13:55:01 +0000 (GMT)" "Test message") UID 1234)');
                    } elsif ($args =~ /BODY\[\]/) {
                        $self->respond($stream, '* 1 FETCH (UID 1234 RFC822.SIZE 186 BODY[] {186}'); # size without newlines?
                        $self->respond($stream, 'Date: Mon, 27 May 2013 13:55:01 +0000 (GMT)');
                        $self->respond($stream, 'From: Test User <test@gateway.dc4>');
                        $self->respond($stream, 'Subject: Test message');
                        $self->respond($stream, 'To: iankent@gateway.dc4');
                        $self->respond($stream, 'Content-Type: TEXT/PLAIN; CHARSET=UTF-8');
                        $self->respond($stream, '');
                        $self->respond($stream, 'Test message content');
                        $self->respond($stream, ')');
                        $self->respond($stream, '* 1 FETCH (FLAGS (\Seen))');
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
