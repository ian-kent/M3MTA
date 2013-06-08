package M3MTA::Server::IMAP::State::Selected;

=head NAME
M3MTA::Server::IMAP::State::Selected
=cut

use Mouse;
use Modern::Perl;
use MIME::Base64 qw/ decode_base64 encode_base64 /;

#------------------------------------------------------------------------------

sub register {
	my ($self, $imap) = @_;
	
	$imap->register_rfc('RFC3501.Selected', $self);
	$imap->register_state('Selected', sub {
		$self->receive(@_);
	});
}

#------------------------------------------------------------------------------

sub receive {
	my ($self, $session, $id, $cmd, $data) = @_;
	$session->log("Received data in Selected state");

	return 0 if $cmd !~ /(UID)/i;

	$cmd = lc $cmd;
	return $self->$cmd($session, $id, $data);
}

#------------------------------------------------------------------------------

sub uid {
	my ($self, $session, $id, $data) = @_;

	if($data =~ /^fetch (\d+)(:(\d+|\*))? \((.*)\)/) {
        my $from = $1;
        my $to = $3;
        my $args = $4;
        print "Got FROM: $1, 2[$2], TO: $3, ARGS: $args\n";
        my $query = {
            mailbox => {
                domain => $session->auth->{user}->{domain},
                user => $session->auth->{user}->{mailbox},
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
        my $messages = $session->imap->store->find($query);
        my $count = 0;
        if($args eq 'FLAGS') {
            while (my $email = $messages->next) {   
                my $flags = "";
                for my $flag (@{$email->{flags}}) {
                    $flags .= "\\$flag ";
                }
                $count++;
                $session->respond($count . ' '.$email->{uid}.' FETCH (UID '.$email->{uid}.' FLAGS ('.$flags.'))');
            }
        } elsif ($args =~ /BODY\.PEEK/) {
            while (my $email = $messages->next) {   
                my $flags = "";
                for my $flag (@{$email->{flags}}) {
                    $flags .= "\\$flag ";
                }
                #* 34632 FETCH (UID 34666 RFC822.SIZE 1796 FLAGS (\Recent) BODY[HEADER.FIELDS ("From" "To" "Cc" "Bcc" "Subject" "Date" "Message-ID" "Priority" "X-Priority" "References" "Newsgroups" "In-Reply-To" "Content-Type")] {306}
                $count++;
                $session->respond($count . ' '.$email->{uid}.' FETCH (UID '.$email->{uid}.' RFC822.SIZE '.$email->{message}->{size}.' FLAGS ('.$flags.')  ENVELOPE ("'.$email->{message}->{headers}->{Date}.'" "'.$email->{message}->{headers}->{Subject}.'"))');
            }
        } elsif ($args =~ /BODY\[\]/) {
            while (my $email = $messages->next) {   
                my $flags = "";
                for my $flag (@{$email->{flags}}) {
                    $flags .= "\\$flag ";
                }
                $session->respond('* '.$email->{uid}.' FETCH (UID '.$email->{uid}.' RFC822.SIZE '.$email->{message}->{size}.' BODY[] {'.$email->{message}->{size}.'}');
                for my $hdr (keys %{$email->{message}->{headers}}) {
                    my $h = $email->{message}->{headers}->{$hdr};
                    if(ref $h =~ /ARRAY/) {
                        for my $i (@$h) {
                            $session->respond($hdr . ': ' . $i);
                        }
                    } else {
                        $session->respond($hdr . ': ' . $h);
                    }
                }
                $session->respond('');
                $session->respond($email->{message}->{body});
                $session->respond(')');
                $count++;
                $session->respond($count . ' '.$email->{uid}.' FETCH (FLAGS ('.$flags.'))');
            }
        }
    }
    $session->respond($id, 'OK');

	return 1;
}

#------------------------------------------------------------------------------

1;