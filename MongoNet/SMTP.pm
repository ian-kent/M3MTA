package MongoNet::SMTP;

use v5.14;
use strict;
use warnings;

use Mouse;
use MouseX::Foreign 'Mojo::EventEmitter';
use MIME::Base64 qw/ decode_base64 encode_base64 /;

# Some data - probably needs outsourcing
has 'hostname'  => ( is => 'rw' );

# Callbacks
has 'queued'    => ( is => 'rw' );
has 'user_auth' => ( is => 'rw' );
has 'user_send' => ( is => 'rw' );
has 'mail_accept' => ( is => 'rw' );

sub respond {
    my ($self, $stream, @cmd) = @_;

    my $c = join ' ', @cmd;
    $stream->write("$c\n");
    print "SENT: $c\n";
    return;
}

sub accept {
    my ($self, $loop, $stream, $id) = @_;

    print "Accepted connection\n";

    $self->respond($stream, 220, $self->hostname . ".dc4 ESMTP Experimental SMTP Server");

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

        if($authtype) {
            $chunk =~ s/\r?\n$//s;
            if($authtype eq 'login') {
                if(!$auth->{username}) {
                    my $username;
                    eval {
                        $username = decode_base64($chunk);
                    };
                    $username =~ s/\r?\n$//s;
                    if($@ || !$username) {
                        $self->respond($stream, 535, "Error: authentication failed: another step is needed in authentication");
                        print "Auth error: $@\n";
                        $authtype = '';
                        $auth = {};
                        return;
                    }
                    $auth->{username} = $username;
                    $self->respond($stream, 334, "UGFzc3dvcmQ6");
                } else {
                    my $password;
                    eval {
                        $password = decode_base64($chunk);
                    };
                    $password =~ s/\r?\n$//s;
                    if($@ || !$password) {
                        $self->respond($stream, 535, "Error: authentication failed: another step is needed in authentication");
                        print "Auth error: $@\n";
                        $authtype = '';
                        $auth = {};
                        return;
                    }
                    $auth->{password} = $password;
                    print "LOGIN: Username [" . $auth->{username} . "], Password [$password]\n";

                    my $user = &{$self->user_auth}($auth->{username}, $password);
                    if(!$user) {
                        $self->respond($stream, 535, "LOGIN authentication failed");
                        $auth = {};
                    } else {
                        $self->respond($stream, 235, "authentication successful");
                        $auth->{success} = 1;
                        $auth->{user} = $user;
                    }
                    $authtype = '';
                }
            } elsif ($authtype eq 'plain') {
                my $decoded;
                eval {
                    $decoded = decode_base64($chunk);
                };
                if($@ || !$decoded) {
                    $self->respond($stream, 535, "authentication failed: another step is needed in authentication");
                    $auth = {};
                    $authtype = '';
                    return;
                }
                my @parts = split /\0/, $decoded;
                if(scalar @parts != 3) {
                    $self->respond($stream, 535, "authentication failed: another step is needed in authentication");
                    $auth = {};
                    $authtype = '';
                    return;
                }
                my $username = $parts[0];
                my $identity = $parts[1];
                my $password = $parts[2];

                print "PLAIN: Username [$username], Identity [$identity], Password [$password]\n";

                my $authed = &{$self->user_auth}($username, $password);
                if(!$authed) {
                    print "Authed: $authed\n";
                    $self->respond($stream, 535, "PLAIN authentication failed");
                    $auth = {};
                } else {
                    $self->respond($stream, 235, "authentication successful");
                    $auth->{username} = $username;
                    $auth->{password} = $password;
                    $auth->{user} = $authed;
                    $auth->{success} = 1;
                }
                $authtype = '';
            }
            return;
        }

        $buffer .= $chunk;

        if($datamode) {
            # in data recv mode
            if($buffer =~ /.*\r\n\.\r\n$/s) {
                $buffer =~ s/\r\n\.\r\n$//s;

                $email->{data} = $buffer;

                $self->respond($stream, &{$self->queued}($email));
                $datamode = 0;
                $buffer = '';
            }
            return;
        }

        return unless $buffer =~ /\r\n$/gs;

        my ($cmd, $data) = $buffer =~ m/^(\w+)\s?(.*)\r\n$/s;
        $buffer = '';

        print "Got cmd[$cmd], data[$data]\n";
        if($cmd !~ /^(HELO|EHLO|QUIT)$/ && !$email->{helo}) {
            $self->respond($stream, 503, "expecting HELO or EHLO");
            return;
        }
        for($cmd) {
            when (/^(HELO|EHLO)$/) {
                if(!$data || $data =~ /^\s*$/) {
                    $self->respond($stream, 501, "you didn't introduce yourself");
                    return;
                }
                $email->{helo} = $data;
                # Everything except last line has - between status and message
                $self->respond($stream, "250-Hello '$data'. I'm an experimental SMTP server using Mojo::IOLoop");
                $self->respond($stream, "250 AUTH PLAIN LOGIN");
            }
            when (/^AUTH$/) {
                print "Got AUTH: $data\n";
                if($auth->{success}) {
                    $self->respond($stream, 503, "Error: already authenticated");
                    return;
                }
                if(!$authtype) {
                    if(!$data) {
                        $self->respond($stream, 501, "Syntax: AUTH mechanism");
                        return;
                    }
                    for($data) {
                        when (/^PLAIN$/) {
                            $self->respond($stream, 334);
                            $authtype = 'plain';
                        }
                        when (/^LOGIN$/) {
                            $self->respond($stream, 334, "VXNlcm5hbWU6");
                            $authtype = 'login';
                        }
                        default {
                            $self->respond($stream, 535, "Error: authentication failed: no mechanism available");
                        }
                    }
                    return;
                }
            }
            when (/^MAIL$/) {
                if($email->{from}) {
                    $self->respond($stream, 503, "MAIL command already received");
                    return;
                }
                if($data =~ /^From:\s*<(.+)>$/i) {
                    print "Checking user against $1\n";
                    my $r = eval {
                        return &{$self->user_send}($auth, $1);
                    };
                    print "Error: $@\n" if $@;

                    if(!$r) {
                        $self->respond($stream, 535, "Not permitted to send from this address");
                        return;
                    }
                    $email->{from} = $1;
                    $self->respond($stream, 250, "$1 sender ok");
                    #$self->respond($stream, 250, "2.1.0 Ok");
                    return;
                }
                $self->respond($stream, 501, "Invalid sender");
            }
            when (/^RCPT$/) {
                if(!$email->{from}) {
                    $self->respond($stream, 503, "send MAIL command first");
                    return;
                }
                if($email->{data}) {
                    $self->respond($stream, 503, "DATA command already received");
                    return;
                }
                if($data =~ /^To:\s*<(.+)>$/i) {
                    print "Checking delivery for $1\n";
                    my $r = eval {
                        return &{$self->mail_accept}($auth, $1);
                    };
                    print "Error: $@\n" if $@;
                    print "RESULT IS: $r\n";
                    if(!$r) {
                        $self->respond($stream, 501, "Not permitted to send to this address");
                        return;
                    }
                    
                    push @{$email->{to}}, $1;
                    $self->respond($stream, 250, "$1 recipient ok");
                    return;
                }
                $self->respond($stream, 501, "Invalid recipient");
            }
            when (/^DATA$/) {
                if(scalar @{$email->{to}} == 0) {
                    $self->respond($stream, 503, "send RCPT command first");
                    return;
                }
                if($email->{data}) {
                    $self->respond($stream, 503, "DATA command already received");
                    return;
                }
                $email->{data} = '';
                $datamode = 1;
                $self->respond($stream, 354, "Send mail, end with \".\" on line by itself");
            }
            when (/^NOOP$/) {
                $self->respond($stream, 250, "Ok.");
            }
            when (/^QUIT$/) {
                $self->respond($stream, 221, "Bye.");
                $stream->on(drain => sub {
                    $stream->close;
                });
            }
            default {
                $self->respond($stream, 500, "Command not understood.");
            }
        }
    });
}

1;
