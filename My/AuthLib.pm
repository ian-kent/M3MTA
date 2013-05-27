package My::AuthLib;

sub auth_user {
	my ($client, $username, $password) = @_;
	my $result = eval {
		my $user = $client->get_database('mojosmtp')->get_collection('users')->find_one({username => $username, password => $password});
		return 0 if !$user;
		$user = $user->as('My::User');
		if ($user && ($user->username eq $username) && ($user->password eq $password)) {
			return 1;
		}
		return 0;
	};
	print "Error: $@\n" if $@;
	return $result;
}

1;
