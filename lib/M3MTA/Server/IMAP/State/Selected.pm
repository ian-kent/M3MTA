package M3MTA::Server::IMAP::State::Selected;

=head NAME
M3MTA::Server::IMAP::State::Selected
=cut

use Modern::Perl;
use Moose;

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

    return 0 if $cmd !~ /FETCH|SEARCH|COPY|STORE/;

    $session->log("Performing UID $cmd");
    $cmd = lc "uid_$cmd";
    if($self->can($cmd)) {
        return $self->$cmd($session, $id, $args);
    } else {
        $session->log("Unable to call $cmd, not implemented");
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
            $prevkey = uc $prevkey;
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

sub uid_copy {
    my ($self, $session, $id, $args) = @_;

    my $argset = $self->parse_uid_store_args($args);
    my %ranges = %{$argset->{ranges}};
    my $params = $argset->{params};

    $params =~ s/^\s*\"(.*)\"\s*$/$1/;

    $session->log("Got RANGES [" . (Dumper \%ranges) . "], ARGS: $params");

    my $result;
    while(my ($from, $to) = each %ranges) {
        $result = $session->imap->uid_copy($session, $from, $to, $params);
        #last if !$result;
    }

    if($result) {
        $session->respond($id, 'OK', 'COPY successful');
    } else {
        $session->respond($id, 'BAD', 'Message not found');
    }

    return 1;
}

sub uid_store {
	my ($self, $session, $id, $args) = @_;

    my $argset = $self->parse_uid_store_args($args);
    my %ranges = %{$argset->{ranges}};
    my $params = $argset->{params};
    $session->log("Got RANGES [" . (Dumper \%ranges) . "], ARGS: $params");

    my $pmap = $self->get_param_map($session, $params);

    my $result;
    while(my ($from, $to) = each %ranges) {
        $result = $session->imap->uid_store($session, $from, $to, $pmap);
        last if !$result;
    }

    if($result) {
        $session->respond($id, 'OK', 'STORE successful');
    } else {
        $session->respond($id, 'BAD', 'Message not found');
    }
    
    return 1;
}

sub parse_uid_store_args {
    my ($self, $args) = @_;

    my ($ranges, $params) = $args =~ /^([\d:\*,\s]*)\s*(.*)/;

    my @groups = split /,/, $ranges;
    my %rng = ();
    for my $group (@groups) {
        $group =~ s/\s*([^\s]*)\s*/$1/;
        my ($from, $to) = split /:/, $group;
        $rng{$from} = $to;
    }

    return {
        ranges => \%rng,
        params => $params
    };
}

sub parse_uid_fetch_args {
    my ($self, $args) = @_;

    my ($ranges, $params) = $args =~ /^([\d:\*,\s]*)\s*\((.*)\)/;

    my @groups = split /,/, $ranges;
    my %rng = ();
    for my $group (@groups) {
        $group =~ s/\s*([^\s]*)\s*/$1/;
        my ($from, $to) = split /:/, $group;
        $rng{$from} = $to;
    }

    return {
        ranges => \%rng,
        params => $params
    };
}

#------------------------------------------------------------------------------

sub uid_fetch {
	my ($self, $session, $id, $args) = @_;

    my $argset = $self->parse_uid_fetch_args($args);
    my %ranges = %{$argset->{ranges}};
    my $params = $argset->{params};
    $session->log("Got RANGES [" . (Dumper \%ranges) . "], ARGS: $params");

    my $query = {
        "mailbox.domain" => $session->auth->domain,
        "mailbox.mailbox" => $session->auth->mailbox,
        "path" => $session->selected,
    };

    my $messages = [];
    use Data::Dumper;
    while (my ($from, $to) = each %ranges) {
        if(!defined $to) {
            $query->{uid} = int($from);
        } else {
            $query->{uid}->{'$gte'} = int($from);
            if ($to && $to ne '*') {
                $query->{uid}->{'$lte'} = int($to);
            } else {
                # TODO * actually means always include the last message
                # with the higest UID, even if $from is higher than that
                # so will need to adjust the $gte parameter
                delete $query->{uid}->{'$lte'};
            }
        }  
        $session->log(Dumper $query);
        my $msgs = $session->imap->fetch_messages($session, $query);
        push $messages, @$msgs;
    }

    my $pmap = $self->get_param_map($session, $params);

    print Dumper $messages;

   	foreach my $email (@$messages) {   
        # TODO should be sequence not uid for first number?
   		my $response = "* " . $email->uid . " FETCH (UID " . $email->uid . " ";
   		my $extra = '';

        if($pmap->{'FLAGS'}) {
            print Dumper $email->flags;
            $response .= "FLAGS (" . (join ' ', @{$email->flags}) . ") ";
        } 

        if($pmap->{'RFC822.SIZE'}) {
        	$response .= 'RFC822.SIZE '.$email->content->size.' ';
        }

        if($pmap->{'BODYSTRUCTURE'}) {
        	$session->log("Content-Type: %s", $email->content->headers->{'Content-Type'});
        	my ($mime, $charset) = $email->content->headers->{'Content-Type'} =~ /([\w\/]+);(\scharset=([\w\d\.\-]+);)?/;
        	$session->log("Got mime [%s], charset [%s]", $mime, $charset);
        	my @mtype = split /\//, uc $mime;
        	$response .= 'BODYSTRUCTURE (';
        	$response .= '"' . $mtype[0] . '" "' . $mtype[1] . '" ("CHARSET" "UTF-8")';
        	my @bodylines = split /\r\n/m, $email->content->body;
        	my $lines = (scalar keys %{$email->content->headers}) + (scalar @bodylines) ;
        	my $len = $email->content->size;
        	$response .= ' NIL NIL "7BIT" ' . $lines . ' ' . $len . ')';
        }

		if ($pmap->{'BODY.PEEK'}) {
            # BODY[HEADER.FIELDS ("From" "To" "Cc" "Bcc" "Subject" "Date" "Message-ID" "Priority" "X-Priority" "References" "Newsgroups" "In-Reply-To" "Content-Type")] {306}
            if($pmap->{'BODY.PEEK'}->{'HEADER.FIELDS'}) {
            	my @list;
				for my $hdr (keys %{$email->content->headers}) {
					push @list, $hdr;
                    my $h = $email->content->headers->{$hdr};
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
            for my $hdr (keys %{$email->content->headers}) {
                my $h = $email->content->headers->{$hdr};
                if(ref $h =~ /ARRAY/) {
                    for my $i (@$h) {
                        $extra .= $hdr . ': ' . $i . "\r\n";
                    }
                } else {
                    $extra .= $hdr . ': ' . $h . "\r\n";
                }
            }
            $extra .= "\r\n" . $email->content->body . "\r\n";
            if($pmap->{'BODY'}) {
            	$response .= 'BODY[] ';
        	} else {
        		$response .= 'RFC822[] ';
        	}
        }

        if($extra) {
        	$response .= "{" . (length $extra) . "}\r\n$extra";
		}

        $response .= ")";
		$session->respond($response);
    }
    $session->respond($id, 'OK');

	return 1;
}

__PACKAGE__->meta->make_immutable;