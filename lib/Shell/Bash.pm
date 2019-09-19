package Shell::Bash;

use strict;
use warnings;

use IPC::Open2;
use IO::Select;
use IO::String;
use Carp;

use constant BLKSIZE => 1024;

BEGIN {
		require Exporter;
		our
			$VERSION = '0.001';
		our @ISA = qw(Exporter);
		our @EXPORT = qw(bash);
}

our @shell = qw(/bin/bash -c);
our $debug;

sub bash ($$;$%) {
	# command to execute
	my $cmd = shift;
	print STDERR "executing cmd:\n$cmd\n" if $debug;

	# cmd output, make $output an alias to the second argument
	our $output;
	local *output = \$_[0];
	$output = '';
	shift;

	# cmd input
	my $input = shift;
	my $inh = IO::String->new;
	$inh->open($input);
	print STDERR "have input data\n" if $debug && $input;

	# additional environment entries for use as shell variables
	my %env = @_;
	local %ENV = %ENV;
	$ENV{$_} = $env{$_} foreach keys %env;
	if ($debug && %env) {
		print STDERR "setting env variables:\n";
		print STDERR "$_=$env{$_}\n" foreach keys %env;
	}

	# start cmd
	my ($c_in, $c_out);
	$c_in = '' unless $input;
	my $pid = open2($c_out, $c_in, @shell, $cmd);

	# ensure filehandles are blocking
	$c_in->blocking(1);
	$c_out->blocking(1);

	# create selectors for read and write filehandles
	my $sin = IO::Select->new;
	$sin->add($c_out);
	my $sout = IO::Select->new;
	$sout->add($c_in) if $input;

	# catch SIGPIPE on input pipe to cmd
	my $pipe_closed;
	local $SIG{PIPE} = sub {
		$pipe_closed = 1;
		print STDERR "got SIGPIPE\n" if $debug;
	};

	print STDERR "\n" if $debug;
	loop:
	while (1) {
		# get filehandles ready to read or write
		my ($read, $write) = IO::Select->select($sin, $sout, undef);
		
		# read from cmd
		foreach my $rh (@$read) {
			my $data;
			my $bytes =	sysread $rh, $data, BLKSIZE;
			unless (defined $bytes) {
				print STDERR "read from cmd failed\n" if $debug;
				carp "read from cmd failed";
				return 1;
			}
			print STDERR "read $bytes bytes from cmd\n" if $debug && $bytes;
			$output .= $data;

			# finish on eof from cmd
			if (! $bytes) {
				print STDERR "closing output from cmd\n" if $debug;
				close($rh);
				$sin->remove($rh);
				last loop;
			}
		}

		# write to cmd
		foreach my $wh (@$write) {
			# stop writing to input on write error / SIGPIPE
			if ($pipe_closed) {
				print STDERR "closing input to cmd as pipe is closed\n"
					if $debug;
				close $wh;
				$sout->remove($wh);
				next loop;
			}

			# save position in case of partial writes
			my $pos = $inh->getpos;

			# try to write chunk of data
			my $data = $inh->getline;
			my $to_be_written = length($data) < BLKSIZE ?
				length($data) : BLKSIZE;
			print STDERR "writing $to_be_written bytes to cmd\n"
				if $debug && $data;
			my $bytes = syswrite $wh, $data, BLKSIZE;

			# write failure mostly because of broken pipe
			unless (defined $bytes) {
				print STDERR "write to cmd failed\n" if $debug;
				carp "write to cmd failed";
				$pipe_closed = 1;
				next loop;
			}

			# log partial write
			print STDERR "wrote $bytes bytes to cmd\n"
				if $debug && $bytes < $to_be_written;
				
			# adjust input data position
			if ($bytes < length($data)) {
				$inh->setpos($pos + $bytes);
			}

			# close cmd input when data is exhausted
			if (eof($inh)) {
				print STDERR "closing input to cmd on end of data\n" if $debug;
				close $wh;
				$sout->remove($wh);
			}
		}

	}

	# avoid zombies and get return status
	waitpid $pid, 0;
	my $status = $? >> 8;
	print STDERR "cmd exited with rc=$status\n\n" if $debug;

	return !$status;
}

1;

# vi:ts=4:
__END__

=head1 NAME

Shell::Bash - Execute bash commands

=head1 SYNOPSIS

	use Shell::Bash;
	
	$Shell::Bash::debug = 1;

	my ($input, $output);

	# input and output, status check
	$input = 'fed to cmd';
	bash 'cat', $output, $input or warn('bash failed');
	print "output is '$output'\n";
	
	# no input
	bash 'echo hello', $output;
	print "output is '$output'\n";
	
	# use shell variable
	bash 'echo $foo', $output, undef, foo => 'var from env';
	print "output is '$output'\n";

	# use bashism
	bash 'cat <(echo $foo)', $output, undef, foo => 'var from file';
	print "output is '$output'\n";

=head1 DESCIPTION
The C<Shell::Bash> module provides an alternative interface for executing
shell commands in addition to 

=over

=item *
C<qx{cmd}>

=item *
C<system('cmd')>

=item *
C<open CMD, '|-', 'cmd'>

=item *
C<open CMD, '-|', 'cmd'>

=back

While these are convenient for simple commands, at the same
time they lack support for some advanced shell features.

Here is an example for something rather simple within bash that cannot
be done straightforward with perl:

	export passwd=secret
	key="$(openssl pkcs12 -nocerts -nodes -in somecert.pfx \
		-passin env:passwd)"
	signdata='some data to be signed'
	signature="$(echo -n "$signdata" | \
		openssl dgst -sha256 -sign <(echo "key") -hex"
	echo "$signature"

As there are much more openssl commands available on shell level
than via perl modules, this is not so simple to adopt.
One had to write the private key into a temporary file and feed
this to openssl within perl.
Same with input and output from/to the script: one has to be
on file while the other may be written/read to/from a pipe.

Other things to consider:

=over

=item *
C<bash> might not be the default shell on the system.

=item *
There is no way to specify by which interpreter C<qx{cmd}> is executed.

=item *
The default shell might not understand constructs like C<<(cmd)>.

=item *
perl variables are not accessible from the shell.

=back

Another challenge consists in feeding the called command
with input from the perl script and capturing the output at
the same time.

The module C<Shell::Bash> tries to merge the possibilities of the
above named alternatives into one. I.e.:

=over

=item *
use a specific command interpreter, C</bin/bash> as default

=item *
provide the command to execute as a single string, like in C<system()>

=item *
give access to the full syntax of the command interpreter

=item *
enable feeding of standard input and capturing standard output
of the called command 

=item *
enable access to perl variables within the called command

=back

Using the C<Shell::Bash> module, the above given shell script example
might be implemented this way in perl:

	my $passwd = 'secret'
	my $key;
	bash 'openssl pkcs12 -nocerts -nodes -in demo.pfx \
		-passin env:passwd', $key, undef, passwd => $passwd;
	my $signdata = 'some data to be signed';
	my $signature;
	bash 'openssl dgst -sha256 -sign <(echo "$key") -hex',
		 $signature, $signdata, key => $key;
	print $signature;
Quite similar, isn't it?

Actually, the a call to C<openssl dgst> as above was the very reason
to create this module.

Commands given to C<bash> are execute via C</bin/bash -c>
by default.
This might be modified by assigning another interpreter
to C<@Shell::Bash::shell>.

Debugging output can be enabled by setting C<$Shell::Bash::debug> to true.

=head1 BUGS AND LIMITATIONS

There seems to be some race condition when the called script
closes its input file prior to passing all provided input
data to it.
Sometimes a SIGPIPE is caught and sometimes C<syswrite>
returns an error.
It is not clear if all situations are handled correctly.

Best efford has been made to avoid blocking situations
where neither reading output from the script
nor writing input to it is possible.
However, under some circumstance such blocking might occur.

=head1 AUTHOR

Joerg Sommrey

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2019, Joerg Sommrey. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.


=cut
