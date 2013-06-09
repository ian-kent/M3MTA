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
			$session->log("Performing UID STORE");
			return $self->uid_store($session, $id, $args);
		}
	}

	return 0;	
}

#------------------------------------------------------------------------------

sub get_param_map {
	my ($self, $session, $params) = @_;

	my $i = 0;
    my $prevkey = '';
    my $buffer = '';
    my $pmap = {};
    my $ctx = [$pmap];
    use Data::Dumper;
    while(my $c = substr($params, $i++, 1)) {

    	#$session->log("Character: $c");

    	# if char is a letter and end of buffer is space, its a key
    	if($c =~ /[\+\w\s\.\\]/) {
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
    		#$session->log("Changing context, prevkey is: $prevkey");
    		$ctx->[0]->{$prevkey} = {};
    		$buffer = '';
    		unshift $ctx, $ctx->[0]->{$prevkey};
    		#print Dumper $ctx;
    		next;
    	}

    	# or a closing bracket
    	if($c =~ /[\]\)]/) {
    		if($buffer && $buffer !~ /^\s+$/) {
    			$buffer =~ s/\s+$//;
    			$ctx->[0]->{$buffer} = 1;
    		}
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

    return $pmap;
}

#------------------------------------------------------------------------------

sub uid_store {
	my ($self, $session, $id, $args) = @_;

	if($args =~ /^(\d+)(:(\d+|\*))? (.*)/) {
        my $from = $1;
        my $to = $3;
        my $params = $4;
        $session->log("Got FROM: $1, 2[$2], TO: $3, ARGS: $params");

        my $pmap = $self->get_param_map($session, $params);

        my $query = {
            mailbox => {
                domain => $session->auth->{user}->{domain},
                user => $session->auth->{user}->{mailbox},
            },
            path => $session->selected,
            uid => int($from),
        };
        my $query2 = {
            mailbox => {
                domain => $session->auth->{user}->{domain},
                user => $session->auth->{user}->{mailbox},
            },
        };
        print Dumper $query;
        my $msg = $session->imap->store->find_one($query);
        my $mbox = $session->imap->mailboxes->find_one($query2);

        if(!$msg) {
        	$session->respond($id, 'BAD', 'Message not found');
        	return 1;
        }

        my $dirty = 0;
        my $dirty2 = 0;

        if($pmap->{'+Flags'}) {
        	my @flags = $msg->{flags} ? @{$msg->{flags}} : ();
	        $session->log("Message already has flags: [%s]", (join ', ', @flags));
	        my %flag_map = map { $_ => 1 } @flags;

        	for my $flag (keys %{$pmap->{'+Flags'}}) {
				if(!$flag_map{$flag}) {
					$flag_map{$flag} = 1;
					$dirty = 1;
					if($flag_map{'\\Unseen'}) {
						delete $flag_map{'\\Unseen'};
						$mbox->{store}->{$session->selected}->{unseen}--;
						$dirty2 = 1;
					}
					if($flag_map{'\\Recent'}) {
						delete $flag_map{'\\Recent'};
						$mbox->{store}->{$session->selected}->{recent}--;
						$dirty2 = 1;
					}
				}
        	}

        	$msg->{flags} = [keys %flag_map];
        	print Dumper $msg->{flags};
        }

        if($dirty) {
        	$session->log("Updating message in store");
        	$session->imap->store->update($query, $msg);
    	}
    	if($dirty2) {
    		$session->log("Updating mailbox");
    		$session->imap->mailboxes->update($query2, $mbox);
    	}

        $session->respond($id, 'OK', 'STORE successful');
        return 1;
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

        my $pmap = $self->get_param_map($session, $params);

       	while (my $email = $messages->next) {   

       		my $response = "* " . $email->{uid} . " FETCH (UID " . $email->{uid} . " ";
       		my $extra = '';

	        if($pmap->{'FLAGS'}) {
                my $flags = "";
                print Dumper $email->{flags};
                for my $flag (@{$email->{flags}}) {
                	next if $flag =~ /^\s*$/;
                    $flags .= "$flag ";
                }
                $response .= "FLAGS ($flags) ";
	        } 

	        if($pmap->{'RFC822.SIZE'}) {
	        	$response .= 'RFC822.SIZE '.$email->{message}->{size}.' ';
	        }

	        if($pmap->{'BODYSTRUCTURE'}) {
	        	$session->log("Content-Type: %s", $email->{message}->{headers}->{'Content-Type'});
	        	my ($mime, $charset) = $email->{message}->{headers}->{'Content-Type'} =~ /([\w\/]+);(\scharset=([\w\d\.\-]+);)?/;
	        	$session->log("Got mime [%s], charset [%s]", $mime, $charset);
	        	my @mtype = split /\//, uc $mime;
	        	$response .= 'BODYSTRUCTURE (';
	        	$response .= '"' . $mtype[0] . '" "' . $mtype[1] . '" ("CHARSET" "UTF-8")';
	        	my @bodylines = split /\r\n/m, $email->{message}->{body};
	        	my $lines = (scalar keys %{$email->{message}->{headers}}) + (scalar @bodylines) ;
	        	my $len = 0;
	        	for my $hdr (keys %{$email->{message}->{headers}}) {
	        		my $h = $email->{message}->{headers}->{$hdr};
	        		my $ht = '';
	        		if(ref $h =~ /ARRAY/) {
                        for my $i (@$h) {
                            $ht .= $hdr . ': ' . $i . "\r\n";
                        }
                    } else {
                        $ht .= $hdr . ': ' . $h . "\r\n";
                    }
	        		$len += length($ht);
	        	}
	        	$len += length($email->{message}->{body}) + 4;
	        	$response .= ' NIL NIL "7BIT" ' . $lines . ' ' . $len . ')';
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