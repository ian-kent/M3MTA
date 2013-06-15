package M3MTA::Server::Backend::IMAP;

use Moose;
extends 'M3MTA::Server::Backend';

#------------------------------------------------------------------------------

sub get_user {
    my ($self, $username, $password) = @_;

    die("get_user not implemented by backend");
}

#------------------------------------------------------------------------------

sub append_message {
    my ($self, $session, $mailbox, $flags, $content) = @_;

    die("append_message not implemented by backend");
}

#------------------------------------------------------------------------------

sub fetch_messages {
	my ($self, $session, $query) = @_;

	die("fetch_messages not implemented by backend");
}

#------------------------------------------------------------------------------

sub create_folder {
	my ($self, $session, $path) = @_;

	die("create_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub delete_folder {
	my ($self, $session, $path) = @_;

	die("delete_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub rename_folder {
	my ($self, $session, $path, $to) = @_;

	die("rename_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub select_folder {
	my ($self, $session, $path, $mode) = @_;

	die("select_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub subcribe_folder {
	my ($self, $session, $path) = @_;

	die("subscribe_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub unsubcribe_folder {
	my ($self, $session, $path) = @_;

	die("unsubscribe_folder not implemented by backend");
}

#------------------------------------------------------------------------------

sub fetch_folders {
	my ($self, $session, $ref, $filter, $subscribed) = @_;

	die("fetch_folders not implemented by backend");
}

#------------------------------------------------------------------------------

sub uid_store {
	my ($self, $session, $from, $to, $params) = @_;

	die("uid_store not implemented by backend");
}

#------------------------------------------------------------------------------

sub parse {
    my ($self, $data) = @_;

    my $size = 0;

    # Extract headers and body
    my ($headers, $body) = split /\r\n\r\n/m, $data, 2;

    # Collapse multiline headers
    $headers =~ s/\r\n([\s\t])/$1/gm;

    my @hdrs = split /\r\n/m, $headers;
    my %h = ();
    for my $hdr (@hdrs) {
        #print "Processing header $hdr\n";
        my ($key, $value) = split /:\s/, $hdr, 2;
        #print "  - got key[$key] value[$value]\n";
        if($h{$key}) {
            $h{$key} = [$h{$key}] if ref $h{$key} !~ /ARRAY/;
            push $h{$key}, $value;
        } else {
            $h{$key} = $value;
        }
    }

    return {
        headers => \%h,
        body => $body,
        size => length($data) + (scalar @hdrs) + 2, # weird hack, length seems to count \r\n as 1?
    };
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;