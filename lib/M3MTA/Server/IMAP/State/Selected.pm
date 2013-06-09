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

	return 0 if $cmd !~ /(UID|SELECT)/i;

	$cmd = lc $cmd;
	return $self->$cmd($session, $id, $data);
}

#------------------------------------------------------------------------------

sub select {
	my ($self, $session, $id, $data) = @_;

	return $session->imap->get_rfc('RFC3501.Authenticated')->select($session, $id, $data);
}

#------------------------------------------------------------------------------

sub uid {
	my ($self, $session, $id, $data) = @_;

	my ($cmd, $args) = $data =~ /^(FETCH|SEARCH|COPY|STORE)\s(.*)$/i;
	$cmd = uc $cmd;

	$session->log("UID command got subcommand [$cmd] with args [$args]");

	for($cmd) {
		when (/FETCH/) {
			$session->log("Performing UID FETCH");
			return $self->uid_fetch($session, $id, $args);
		}
		when (/SEARCH/) {

		}
		when (/COPY/) {

		}
		when (/STORE/) {

		}
	}

	return 0;	
}

#------------------------------------------------------------------------------

sub uid_fetch {
	my ($self, $session, $id, $args) = @_;

	if($args =~ /^(\d+)(:(\d+|\*))? \((.*)\)/) {
        my $from = $1;
        my $to = $3;
        my $params = $4;
        $session->log("Got FROM: $1, 2[$2], TO: $3, ARGS: $params");
        my $query = {
            mailbox => {
                domain => $session->auth->{user}->{domain},
                user => $session->auth->{user}->{mailbox},
            },
            path => $session->selected,
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
        $session->log(Dumper $query);
        my $messages = $session->imap->store->find($query);

        my $i = 0;
        my $prevkey = '';
        my $buffer = '';
        my $pmap = {};
        my $ctx = [$pmap];
        while(my $c = substr($params, $i++, 1)) {

        	# if char is a letter and end of buffer is space, its a key
        	if($c =~ /[\w\s\.]/) {
        		if($buffer =~ /\s$/) {
        			$buffer =~ s/\s+$//;
        			$ctx->[0]->{$buffer} = 1;
        			$prevkey = $buffer;
        			$buffer = '';
        		}
        		# Set buffer to new char and continue
        		$buffer .= $c;
        		next;
        	}

        	# if we've got an opening bracket, we want to change the context
        	if($c =~ /[\[\(]/) {
        		if($buffer && $buffer !~ /^\s+$/) {
        			$buffer =~ s/\s+$//;
        			$prevkey = $buffer;
        		}
        		$ctx->[0]->{$prevkey} = {};
        		$buffer = '';
        		unshift $ctx, $ctx->[0]->{$prevkey};
        		next;
        	}

        	# or a closing bracket
        	if($c =~ /[\]\)]/) {
        		$buffer = '';
        		shift $ctx;
        		next;
        	}
        }
        if($buffer && $buffer !~ /^\s+$/) {
        	$buffer =~ s/\s+$//;
        	$pmap->{$buffer} = 1;
        }

       	$session->log(Dumper $pmap);

       	while (my $email = $messages->next) {   

       		my $response = "* " . $email->{uid} . " FETCH (UID " . $email->{uid} . " ";
       		my $extra = '';

	        if($pmap->{'FLAGS'}) {
                my $flags = "";
                for my $flag (@{$email->{flags}}) {
                	next if $flag =~ /^\s*$/;
                    $flags .= "$flag ";
                }
                $response .= "FLAGS ($flags) ";
	        } 

	        if($pmap->{'RFC822.SIZE'}) {
	        	$response .= 'RFC822.SIZE '.$email->{message}->{size}.' ';
	        }

			if ($pmap->{'BODY.PEEK'}) {
                # BODY[HEADER.FIELDS ("From" "To" "Cc" "Bcc" "Subject" "Date" "Message-ID" "Priority" "X-Priority" "References" "Newsgroups" "In-Reply-To" "Content-Type")] {306}
                if($pmap->{'BODY.PEEK'}->{'HEADER.FIELDS'}) {
                	my @list;
					for my $hdr (keys %{$email->{message}->{headers}}) {
						push @list, $hdr;
	                    my $h = $email->{message}->{headers}->{$hdr};
	                    if(ref $h =~ /ARRAY/) {
	                        for my $i (@$h) {
	                            $extra .= $hdr . ': ' . $i . "\r\n";
	                        }
	                    } else {
	                        $extra .= $hdr . ': ' . $h . "\r\n";
	                    }
	                }
	                @list = map { "\"$_\"" } @list;
	                my $headers = join ' ', @list;
	                $response .= 'BODY[HEADER.FIELDS (' . $headers . ')] ';
            	}

                #$response .= 'ENVELOPE ("'.$email->{message}->{headers}->{Date}.'" "'.$email->{message}->{headers}->{Subject}.'")';
	        }

			if ($pmap->{'BODY'} || $pmap->{'RFC822'}) {               
                for my $hdr (keys %{$email->{message}->{headers}}) {
                    my $h = $email->{message}->{headers}->{$hdr};
                    if(ref $h =~ /ARRAY/) {
                        for my $i (@$h) {
                            $extra .= $hdr . ': ' . $i . "\r\n";
                        }
                    } else {
                        $extra .= $hdr . ': ' . $h . "\r\n";
                    }
                }
                $extra .= "\r\n" . $email->{message}->{body};
                if($pmap->{'BODY'}) {
                	$response .= 'BODY[] ';
            	} else {
            		$response .= 'RFC822[] ';
            	}
	        }

	        if($extra) {
	        	$extra .= "\r\n";
	        	$response .= "{" . (length $extra) . "}\r\n$extra\r\n";
			}

	        $response .= ")";
			$session->respond($response);
	    }
    }
    $session->respond($id, 'OK');

	return 1;
}

1;