package M3MTA::Server::IMAP::Session;

use Modern::Perl;
use Mouse;
use Data::Dumper;

#------------------------------------------------------------------------------

has 'imap'   => ( is => 'rw' );
has 'stream' => ( is => 'rw' );
has 'ioloop' => ( is => 'rw' );
has 'id' 	 => ( is => 'rw' );
has 'server' => ( is => 'rw' );

# clean up these
has 'buffer'   => ( is => 'rw' );
has 'auth'     => ( is => 'rw' );
has 'authtype' => ( is => 'rw' );
has 'datamode' => ( is => 'rw' );
has 'email'    => ( is => 'rw' );

#------------------------------------------------------------------------------

sub log {
	my $self = shift;
	return if !$self->imap->debug;

	my $message = shift;
	$message = '[SESSION %s] ' . $message;

	$self->imap->log($message, $self->id, @_);
}

#------------------------------------------------------------------------------

sub respond {
    my ($self, @cmd) = @_;

    my $c = join ' ', @cmd;
    $self->stream->write("$c\r\n");
    $self->log("[SENT] %s", $c);
    return;
}

#------------------------------------------------------------------------------

sub begin {
    my ($self) = @_;

    $self->respond('* OK', '[CAPABILITY IMAP4REV1 AUTH=LOGIN]', $self->imap->config->{hostname}, " " . $self->imap->ident);

    $self->stream->on(error => sub {
        my ($stream, $error) = @_;
        $self->log("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->log("Stream closed");
    });
    $self->stream->on(read => sub {
        my ($stream, $chunk) = @_;

        $self->buffer(($self->buffer ? $self->buffer : '') . $chunk);
        $self->receive if $self->buffer =~ /\n$/m;
    });
}

#------------------------------------------------------------------------------

sub receive {
	my ($self) = @_;

	$self->log("[RECD] %s", $self->buffer);

#    # Check if we have a state hook
#    for my $ar (@{$self->smtp->states}) {
#        if($self->state =~ $ar->[0]) {
#            return &{$ar->[1]}($self);
#        }
#    }
#    
    # Only continue if we had an EOL
    my $buffer = $self->buffer;
    return unless $buffer =~ /\n$/gs; #FIXME not necessary? done above
    $self->buffer('');


    my ($id, $cmd, $data) = $buffer =~ m/^([\w\d]+)\s*(\w+)\s?(.*)\r\n$/s;
    $self->log("Got id[%s], cmd[%s], data[%s]", $id, $cmd, $data);

    for(uc $cmd) {
        when (/^LOGIN$/) {
            my ($username, $password) = $data =~ /"(.*)"\s"(.*)"/;
            my $user = $self->_user_auth($username, $password);
            if($user) {
                $self->auth({});
                $self->auth->{success} = 1;
                $self->auth->{username} = $username;
                $self->auth->{password} = $password;
                $self->auth->{user} = $user;
                $self->respond($id, 'OK', '[CAPABILITY IMAP4REV1] User authenticated');
            } else {
                $self->auth({});
                $self->respond($id, 'BAD', '[CAPABILITY IMAP4REV1] User authentication failed');
            }
        }
        when (/^LSUB$/) {
            if($self->auth && $self->auth->{success}) {
                for my $sub (keys %{$self->auth->{user}->{store}->{children}}) {
                    $self->respond('*', 'LSUB () "."', $sub);
                }
            }
            $self->respond($id, 'OK');
        }
        when (/^LIST$/) {
            my ($um, $sub) = $data =~ /"(.*)"\s"(.*)"/;
            if($self->auth && $self->auth->{success}) {
                if($self->auth->{user}->{store}->{children}->{$sub}) {
                    $self->respond('*', 'LIST (\HasNoChildren) "." "' . $sub . '"');
                }
            }
            $self->respond($id, 'OK');
        }
        when (/^SELECT$/) {
            my ($sub) = $data =~ /"(.*)"/;
            if($self->auth->{user}->{store}->{children}->{$sub}) {
                my $exists = $self->auth->{user}->{store}->{children}->{$sub}->{seen} + $self->auth->{user}->{store}->{children}->{$sub}->{unseen};
                my $recent = $self->auth->{user}->{store}->{children}->{$sub}->{unseen};
                $self->respond('*', 'FLAGS ()');
                $self->respond('*', $exists . ' EXISTS');
                $self->respond('*', $recent . ' RECENT');
            }
            $self->respond($id, 'OK');
        }
        when (/^UID$/) {
            if($data =~ /^fetch (\d+)(:(\d+|\*))? \((.*)\)/) {
                my $from = $1;
                my $to = $3;
                my $args = $4;
                print "Got FROM: $1, 2[$2], TO: $3, ARGS: $args\n";
                my $query = {
                    mailbox => {
                        domain => $self->auth->{user}->{domain},
                        user => $self->auth->{user}->{mailbox},
                    },
                };
                if($to) {
                    $query->{uid}->{'$gte'} = int($from);
                    if($to ne '*') {
                        $query->{uid}->{'$lte'} = int($to);
                    }
                } else {
                    $query->{uid} = int($from);
                }
                use Data::Dumper;
                print Dumper $query;
                my $messages = $self->imap->store->find($query);
                my $count = 0;
                if($args eq 'FLAGS') {
                    while (my $email = $messages->next) {   
                        my $flags = "";
                        for my $flag (@{$email->{flags}}) {
                            $flags .= "\\$flag ";
                        }
                        $count++;
                        $self->respond($count . ' '.$email->{uid}.' FETCH (UID '.$email->{uid}.' FLAGS ('.$flags.'))');
                    }
                } elsif ($args =~ /BODY\.PEEK/) {
                    while (my $email = $messages->next) {   
                        my $flags = "";
                        for my $flag (@{$email->{flags}}) {
                            $flags .= "\\$flag ";
                        }
                        #* 34632 FETCH (UID 34666 RFC822.SIZE 1796 FLAGS (\Recent) BODY[HEADER.FIELDS ("From" "To" "Cc" "Bcc" "Subject" "Date" "Message-ID" "Priority" "X-Priority" "References" "Newsgroups" "In-Reply-To" "Content-Type")] {306}
                        $count++;
                        $self->respond($count . ' '.$email->{uid}.' FETCH (UID '.$email->{uid}.' RFC822.SIZE '.$email->{message}->{size}.' FLAGS ('.$flags.')  ENVELOPE ("'.$email->{message}->{headers}->{Date}.'" "'.$email->{message}->{headers}->{Subject}.'"))');
                    }
                } elsif ($args =~ /BODY\[\]/) {
                    while (my $email = $messages->next) {   
                        my $flags = "";
                        for my $flag (@{$email->{flags}}) {
                            $flags .= "\\$flag ";
                        }
                        $self->respond('* '.$email->{uid}.' FETCH (UID '.$email->{uid}.' RFC822.SIZE '.$email->{message}->{size}.' BODY[] {'.$email->{message}->{size}.'}');
                        for my $hdr (keys %{$email->{message}->{headers}}) {
                            my $h = $email->{message}->{headers}->{$hdr};
                            if(ref $h =~ /ARRAY/) {
                                for my $i (@$h) {
                                    $self->respond($hdr . ': ' . $i);
                                }
                            } else {
                                $self->respond($hdr . ': ' . $h);
                            }
                        }
                        $self->respond('');
                        $self->respond($email->{message}->{body});
                        $self->respond(')');
                        $count++;
                        $self->respond($count . ' '.$email->{uid}.' FETCH (FLAGS ('.$flags.'))');
                    }
                }
            }
            $self->respond($id, 'OK');
        }
        when (/^NOOP$/) {
            $self->respond(250, "Ok.");
        }
        when (/^LOGOUT$/) {
            $self->respond('*', 'BYE', $self->imap->config->{hostname}, 'server terminating connection');
            $self->respond($id, 'OK LOGOUT completed');
            $self->stream->on(drain => sub {
                $self->stream->close;
            });
        }
        default {
            $self->respond($id, 'BAD', "Command not understood.");
        }
    }

#    # Get the command and data
#    my ($cmd, $data) = $buffer =~ m/^(\w+)\s?(.*)\r\n$/s;
#    $self->log("Got cmd[%s], data[%s]", $cmd, $data);
#
#    # Call the command hook, and exit if we get a negative response
#    my $result = $self->smtp->call_hook('command', $self, $cmd, $data);
#    return if !$result;
#
#    # Check if command is registered by an RFC
#    if($self->smtp->commands->{$cmd}) {
#        return &{$self->smtp->commands->{$cmd}}($self, $data);
#    }
#
#    # Respond with command not understood
#    $self->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Command not understood.");
}

#------------------------------------------------------------------------------

sub _user_auth {
    my ($self, $username, $password) = @_;
    print "User auth for username [$username] with password [$password]\n";

    my $user = $self->imap->mailboxes->find_one({username => $username, password => $password});
    print "Error: $@\n" if $@;

    return $user;
}

#------------------------------------------------------------------------------

1;