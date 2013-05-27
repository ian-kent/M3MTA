package My::Email;

use MongoDB::Simple;
our @ISA = ('MongoDB::Simple');

database 'mojosmtp';
collection 'email';

string 'helo';
string 'from';
array 'to';
string 'data';
string 'id';
date 'created';

1;
