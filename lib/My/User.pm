package My::User;

use MongoDB::Simple;
our @ISA = ('MongoDB::Simple');

database 'mojosmtp';
collection 'users';

string 'username';
string 'password';
string 'email';

1;
