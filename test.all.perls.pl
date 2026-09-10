#!/usr/bin/env perl
# test.all.perls.pl - run SimpleFlow's test suite against every perlbrew perl.
#
# Automates the loop the project's CLAUDE.md prescribes by hand,
#
#     /home/con/perl5/perlbrew/perls/perl-5.10.1/bin/perl -Ilib \
#         -MTest::Harness -e 'runtests(glob "t/*.t")'
#
# once per installed perl, oldest first, and prints a pass/fail/skip summary.
# Exit status is non-zero if any perl failed.
#
# Modelled on ~/Scripts/stats/test.all.perls.pl, the Stats::LikeR helper of the
# same name; the option names, the fork/throttle/reap loop, the Dumper-across-a-
# fork result protocol and the summary format are all from there. Four things
# are deliberately absent, because SimpleFlow is pure Perl:
#
#   * no build. There is no Makefile.PL in this repo at all (dzil writes one
#     into the tarball), no XS, no blib, and nothing to install, so a "perl"
#     here means one interpreter running t/*.t against lib/ as it stands.
#   * no private copy of the tree per child. Its whole purpose there was that
#     one perl's LikeR.o must not be linked by another; here the children only
#     read. Measured on 2026-09-10: `ls` before and after a full `prove -Ilib
#     t/` is byte-identical, because every file the suite writes comes from
#     File::Temp. So the parallel children share this directory and it is left
#     exactly as it was found.
#   * no NV-width or x87 rows. Those exist to vary floating-point evaluation in
#     C; nothing here computes in C, and the version spread is the only axis.
#   * a perl whose prerequisites are not installed is reported as SKIP rather
#     than run and reported as a failure -- see the --deps note below. As of
#     2026-09-10 that is three of the six perls installed here: 5.42.3,
#     5.44.0-i686 and 5.44.0-quadmath each want Capture::Tiny, Data::Printer
#     (with DDP) and Devel::Size, and the quadmath build Devel::Confess too.
#
# -P 1 runs one perl at a time, which is the readable mode when something has
# already failed and the interleaved logs are in the way.

use 5.044;
use warnings FATAL => 'all';
use Getopt::Long 'GetOptions';
# -P (how many perls at once) and -p (which perl) are different options, so the
# default case-folding of single-letter aliases has to go.
Getopt::Long::Configure('no_ignore_case');
use File::Spec;
use IO::Handle;
use Cwd 'getcwd';
use Data::Dumper;
use POSIX 'strftime';
use Time::HiRes 'time';

my $PERLBREW_ROOT = $ENV{PERLBREW_ROOT} || File::Spec->catdir($ENV{HOME}, 'perl5', 'perlbrew');
my $MODULE        = File::Spec->catfile('lib', 'SimpleFlow.pm');

my ($help, $list, $deps, $stop, $quiet, $jobs, $log_dir, $par, @only);
# On by default: a perl that cannot load Capture::Tiny has not tested anything,
# and saying FAIL there would be a standing red row that nobody reads. --no-
# skip-missing turns those rows back into failures, for a run that is meant to
# prove the whole matrix is usable.
my $skip_missing = 1;
# All of them at once. The suite is 14.7s of wall clock for 0.68s of CPU on
# 5.44.0 (measured 2026-09-10): it spends nearly all of that asleep in the
# timeout and kill tests, so the number of perls that can usefully run at once
# has nothing to do with the number of cores.
$par     = 0;                                        # 0 = one child per perl
$jobs    = 0;                                        # 0 = serial harness
# Not .build/, which is where the Stats::LikeR original puts its logs: Dist::
# Zilla owns that name here and `dzil clean` -- which sh dzil.sh runs -- deletes
# it outright. A dot directory also keeps the logs out of the distribution for
# free, since [@Basic]'s GatherDir does not gather dotfiles.
$log_dir = '.multiperl';

GetOptions(
	'perl|p=s@'      => \@only,
	'deps!'          => \$deps,
	'skip-missing!'  => \$skip_missing,
	'stop-on-fail!'  => \$stop,
	'jobs|j=i'       => \$jobs,
	'parallel|P:i'   => \$par,
	'log-dir=s'      => \$log_dir,
	'quiet|q'        => \$quiet,
	'list|l'         => \$list,
	'help|h'         => \$help,
) or usage(1);
usage(0) if $help;

sub usage {
	my $rc = shift;
	print STDERR <<"END";
usage: $0 [options]

Runs the test suite in the current directory against each perl installed under
$PERLBREW_ROOT. Nothing is built and nothing is
installed -- each perl runs t/*.t against lib/ -- so this directory is left
exactly as it was found, in parallel mode as well as serial.

Run order is oldest perl first. 5.10.1 is the one that catches a use of syntax
newer than the declared minimum, so it is the row that should report first and
the one --stop-on-fail should stop on.

A perl that is missing a prerequisite from dist.ini cannot run the suite; it is
listed as SKIP, with the modules it wants, and does not change the exit status
unless --no-skip-missing is given. --deps installs them with cpanm first.

options:
  -p, --perl VERSION   only this perl (repeatable, comma-separated); accepts
                       "5.10.1", "perl-5.10.1" or an exact directory name such
                       as "5.44.0-quadmath". default: every installed perl
  -l, --list           list the perls that would be tested, in run order, with
                       each one's reported version and any missing
                       prerequisites, then exit
      --deps           cpanm any missing prerequisite for that perl first
      --no-skip-missing  count a perl with missing prerequisites as a failure
                       rather than a skip
      --stop-on-fail   abort at the first perl that fails (with -P: launch no
                       more perls; the running ones finish)
  -P, --parallel [N]   run N perls at once. bare -P, or -P 0, runs one child
                       per perl, which is the default: the suite is almost all
                       sleep, so the cores are not the constraint. -P 1 runs
                       them one at a time.
  -j, --jobs N         HARNESS_OPTIONS=j<N>, i.e. N test files at once within
                       one perl. Off by default: t/02.fixes.t is 13.4s of the
                       suite's 14.7s, so -j3 saves about a second and buys it
                       with interleaved TAP in the log.
      --log-dir DIR    where per-perl logs go (default: $log_dir)
  -q, --quiet          only write logs; do not echo output. implied by more
                       than one perl at a time, where the interleaving would be
                       unreadable
  -h, --help           this message

exit status: 0 if every perl that ran passed, else 1.
END
	exit $rc;
}

# Scrubbed once, before anything runs a target perl: a PERL5LIB or PERL_MM_OPT
# inherited from the calling shell points one perl at another perl's site_perl,
# which is exactly how a prerequisite comes to look installed here and be
# missing on a smoker. It has to go before the --list probe too, or --list and
# the run it is predicting disagree about what is installed.
delete @ENV{qw(PERL5LIB PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
	PERLBREW_LIB PERL_MM_USE_DEFAULT HARNESS_OPTIONS HARNESS_PERL_SWITCHES)};

die "$0: no $MODULE in " . getcwd() . " -- run this from the distribution root\n"
	unless -f $MODULE;
die "$0: no t/ directory in " . getcwd() . "\n" unless -d 't';

# ---------------------------------------------------------------- discovery --

my $perls_dir = File::Spec->catdir($PERLBREW_ROOT, 'perls');
die "$0: no perlbrew perls directory at $perls_dir\n" unless -d $perls_dir;

opendir my $dh, $perls_dir or die "$0: cannot read $perls_dir: $!\n";
my @installed = grep { -x File::Spec->catfile($perls_dir, $_, 'bin', 'perl') }
	grep { !/^\.\.?$/ } readdir $dh;
closedir $dh;

# numeric sort, oldest first, which is the run order.
sub vkey {
	my $v = shift;
	$v =~ s/^perl-//;
	my @p = ($v =~ /(\d+)/g);
	push @p, 0 while @p < 3;
	# the trailing name keeps two builds of one version -- 5.44.0 and
	# 5.44.0-quadmath -- in a stable order rather than an arbitrary one
	return sprintf('%05d%05d%05d', @p[0 .. 2]) . $v;
}
@installed = sort { vkey($a) cmp vkey($b) } @installed;

my @targets = @installed;
if (@only) {
	my %have = map { $_ => 1 } @installed;
	my (@want, @missing);
	for my $arg (map { split /,/ } @only) {
		# an exact directory name wins, so a build installed without the
		# perl- prefix ("5.44.0-quadmath") is selectable by its real name
		my ($match) = grep { $have{$_} } $arg, "perl-$arg";
		if (defined $match) { push @want, $match }
		else                { push @missing, $arg }
	}
	die "$0: not installed under perlbrew: @missing\n(installed: @installed)\n" if @missing;
	my %seen;
	@targets = sort { vkey($a) cmp vkey($b) } grep { !$seen{$_}++ } @want;
}
die "$0: no perls found in $perls_dir\n" unless @targets;

sub perl_bin { return File::Spec->catfile($perls_dir, shift, 'bin', 'perl') }

# ------------------------------------------------------------------- probes --

# What each perl reports itself to be. The version has to come from the
# interpreter rather than from the directory name: "5.44.0-quadmath" is a local
# naming habit, not a promise, and a row labelled with a name nobody checked is
# how a perl gets tested twice and another not at all. A perl that will not
# answer is described as '?' and still gets run -- the suite is the real probe.
my %reported;
sub reported {
	my $version = shift;
	return $reported{$version} if defined $reported{$version};
	my $r = '?';
	if (open my $fh, '-|', perl_bin($version), '-MConfig', '-e',
			'printf "%vd%s", $^V, $Config{useithreads} ? "-thr" : ""') {
		my $line = <$fh>;
		close $fh;
		# -thr is reported because it is the one configuration difference that
		# can reach pure Perl here: on a threaded build fork() is emulated,
		# and _run_with_timeout forks, sets a process group and kills it.
		$r = $line if defined $line && length $line;
	}
	return $reported{$version} = $r;
}

# The runtime prerequisites, read out of dist.ini so this cannot drift from the
# distribution's own declaration.
sub prereqs {
	open my $fh, '<', 'dist.ini' or die "$0: cannot read dist.ini: $!\n";
	my ($in, @mods) = (0);
	while (my $line = <$fh>) {
		if ($line =~ /^\s*\[(.+?)\]/) { $in = $1 eq 'Prereqs'; next }
		next unless $in;
		next unless $line =~ /^\s*([A-Za-z_][\w:]*)\s*=/;
		next if $1 eq 'perl';                # a version, not a module
		push @mods, $1;
	}
	close $fh;
	# DDP ships inside Data::Printer but is a separate file, and it is what
	# lib/SimpleFlow.pm and t/01.t actually load, so a Data::Printer install
	# that somehow lacks it has to show up here and not as a test failure.
	push @mods, 'DDP';
	return @mods;
}
my @prereqs = prereqs();

# Which of @prereqs that perl cannot load, in one child rather than one child
# per module. Load, not exists: the failure this guards against is a `use` in
# the suite dying, and only requiring the file reproduces that.
sub missing_prereqs {
	my $version = shift;
	my $code = 'my @m; for my $m (@ARGV) { (my $f = $m) =~ s{::}{/}g;'
		. ' eval { require "$f.pm"; 1 } or push @m, $m } print join " ", @m';
	open my $fh, '-|', perl_bin($version), '-e', $code, @prereqs
		or return ('?');
	my $out = do { local $/; <$fh> };
	close $fh;
	return split ' ', (defined $out ? $out : '');
}

if ($list) {
	for my $version (@targets) {
		my @missing = missing_prereqs($version);
		printf "%-18s %-12s %-28s %s\n", $version, reported($version),
			(@missing ? 'missing: ' . join(' ', @missing) : 'prereqs ok'),
			perl_bin($version);
	}
	exit 0;
}

# ------------------------------------------------------------------ logging --

sub mkdirp {
	my @parts = File::Spec->splitdir(shift);
	my $path;   # undef, not '': splitdir gives an absolute path a leading '',
	            # and catdir('', 'home') is '/home' where 'home' would be a
	            # directory of that name in the cwd.
	for my $p (@parts) {
		$path = defined $path ? File::Spec->catdir($path, $p) : $p;
		next if !length($path) || -d $path;
		mkdir $path or die "$0: mkdir $path: $!\n";
	}
}

mkdirp($log_dir);
my $stamp = strftime '%Y%m%d-%H%M%S', localtime;

# ------------------------------------------------------------- parallelism --

$par = 0 if $par < 0;
$par ||= scalar @targets;                  # bare -P, or the default
$par = @targets if $par > @targets;

# ------------------------------------------------------------- child runner --

# Run @cmd with STDERR folded into STDOUT, echoing to the terminal and to
# $logfh. Returns ($exit_code, \@lines).
sub run_cmd {
	my ($cmd, $logfh) = @_;
	print $logfh "\n\$ @$cmd\n";
	print "\$ @$cmd\n" unless $quiet;

	my $pid = open my $fh, '-|';
	die "$0: fork failed: $!\n" unless defined $pid;
	if (!$pid) {                              # child
		open STDERR, '>&', \*STDOUT or die "$0: dup STDERR: $!\n";
		$| = 1;
		{ exec { $cmd->[0] } @$cmd; }
		print "exec @$cmd failed: $!\n";
		exit 127;
	}

	my @lines;
	while (defined(my $line = <$fh>)) {
		push @lines, $line;
		print $logfh $line;
		print $line unless $quiet;
	}
	close $fh;
	my $status = $?;
	# the death signal is the low 7 bits of the raw status and the exit code
	# the high byte, so the signal is read before the shift -- the same order
	# lib/SimpleFlow.pm decodes system()'s status in, and for the same reason
	my $code = $status == -1  ? -1
		: ($status & 127) ? 128 + ($status & 127)
		: ($status >> 8);
	return ($code, \@lines);
}

# ---------------------------------------------------------- run one perl --

# Run the suite with one perl. Returns the result hashref, and prints its own
# progress unless $silent: a parallel child is silent and the parent reports
# for it.
sub run_one {
	my ($version, $silent) = @_;
	my $bin  = File::Spec->catdir($perls_dir, $version, 'bin');
	my $perl = File::Spec->catfile($bin, 'perl');

	my $log = File::Spec->catfile($log_dir, "$version.$stamp.log");
	# Re-create the log directory rather than trusting that it survived: a
	# whole matrix is 15s in parallel and about a minute serial, and anything
	# that removes the log directory meanwhile should not turn a perl that was
	# testing fine into a failure with no log to read.
	mkdirp($log_dir);
	open my $logfh, '>', $log or die "$0: cannot write $log: $!\n";
	$logfh->autoflush(1);
	STDOUT->autoflush(1);

	unless ($silent) {
		print "\n", '=' x 72, "\n";
		printf "== %s   (log: %s)\n", $version, $log;
		print '=' x 72, "\n";
	}
	print $logfh "== $version at " . strftime('%F %T', localtime)
		. ' in ' . getcwd() . "\n";

	# Emulate `perlbrew use $version`: this perl's bin first and every other
	# perlbrew perl stripped out of PATH, so a test that shells out to `perl`
	# -- t/01.t runs $^X, but a future one might not -- cannot reach a
	# different version. The PERL5LIB scrub already happened, once, above.
	local %ENV = %ENV;
	my @path = grep { index($_, File::Spec->catdir($perls_dir, '')) != 0 }
		split /:/, ($ENV{PATH} || '/usr/bin:/bin');
	$ENV{PATH}          = join ':', $bin, @path;
	$ENV{PERLBREW_ROOT} = $PERLBREW_ROOT;
	$ENV{PERLBREW_PERL} = $version;
	$ENV{PERLBREW_PATH} = $bin;
	$ENV{HARNESS_OPTIONS} = "j$jobs" if $jobs;

	my $t0 = time;
	my %r = (version => $version, log => $log, steps => [], reported => '?',
		seconds => 0, failed => undef, skipped => []);
	$r{reported} = reported($version);

	my @missing = missing_prereqs($version);
	if (@missing && $deps) {
		my $cpanm = -x File::Spec->catfile($bin, 'cpanm')
			? File::Spec->catfile($bin, 'cpanm')
			: File::Spec->catfile($PERLBREW_ROOT, 'bin', 'cpanm');
		my $t_deps = time;
		my ($code, undef) = run_cmd([$perl, $cpanm, '--notest', @missing], $logfh);
		push @{ $r{steps} },
			{ label => 'deps', code => $code, seconds => time - $t_deps };
		# ask the interpreter again rather than believing cpanm's exit status:
		# --notest can report success for a module that still will not load
		@missing = missing_prereqs($version);
	}

	# A perl missing a prerequisite runs nothing at all: the first `use` in
	# t/01.t would die, and a suite that died there has tested nothing, so the
	# row says SKIP (or FAIL under --no-skip-missing) and names the modules.
	if (@missing) {
		$r{skipped} = [@missing];
		$r{failed}  = 'prereqs' unless $skip_missing;
		$r{seconds} = time - $t0;
		printf $logfh "-- not run: missing %s\n", join ' ', @missing;
		close $logfh;
		report_one(\%r) unless $silent;
		return \%r;
	}

	my @steps;
	# -c, not just the suite: a use of syntax newer than the declared 5.010
	# minimum is a compile error in the module, and naming it as its own step
	# tells that apart from a test that failed for its own reasons.
	push @steps, ['compile', [$perl, '-Ilib', '-c', $MODULE]];
	# The invocation from CLAUDE.md, sorted so the log reads in file order:
	# glob's order is already sorted, and saying so keeps it that way if the
	# list ever comes from somewhere else.
	push @steps, ['test', [$perl, '-Ilib', '-MTest::Harness', '-e',
		'runtests(sort glob q{t/*.t})']];

	my $failed;
	for my $step (@steps) {
		my ($label, $cmd) = @$step;
		my $t_step = time;
		my ($code, $lines) = run_cmd($cmd, $logfh);
		my $secs = time - $t_step;
		printf $logfh "-- step '%s' exited %d after %.1fs\n", $label, $code, $secs;

		if ($label eq 'test') {
			for my $l (@$lines) {
				$r{files}  = $1 if $l =~ /^(Files=\d+.*)/;
				$r{result} = $1 if $l =~ /^Result:\s*(\S+)/;
			}
		}

		push @{ $r{steps} }, { label => $label, code => $code, seconds => $secs };
		next if $code == 0;
		$failed = $label;
		last;
	}

	$r{seconds} = time - $t0;
	$r{failed}  = $failed if defined $failed;
	close $logfh;

	report_one(\%r) unless $silent;
	return \%r;
}

# the two progress lines a finished perl prints, from the parent in either mode
sub report_one {
	my $r = shift;
	my $what = $r->{failed}          ? "FAILED at '$r->{failed}'"
		: @{ $r->{skipped} } ? 'SKIPPED (missing ' . join(' ', @{ $r->{skipped} }) . ')'
		: 'ok';
	printf "-- %s: %s in %.1fs%s\n", $r->{version}, $what, $r->{seconds},
		(defined $r->{files} ? " ($r->{files})" : '');
	return unless @{ $r->{steps} };
	print '-- ', join('  ', map { sprintf '%s %.1fs', $_->{label}, $_->{seconds} }
		@{ $r->{steps} }), "\n";
}

# ------------------------------------------------------- result across a fork --

# The child's result has to cross a fork, and %r is plain data, so Dumper out /
# eval in beats any IPC here: it also leaves the numbers next to the log when
# something needs explaining afterwards.
sub write_result {
	my ($file, $r) = @_;
	mkdirp($log_dir);
	open my $fh, '>', $file or die "$0: cannot write $file: $!\n";
	local $Data::Dumper::Indent   = 0;
	local $Data::Dumper::Sortkeys = 1;
	print $fh Data::Dumper->Dump([$r], ['R']);
	close $fh or die "$0: close $file: $!\n";
}

sub read_result {
	my $file = shift;
	open my $fh, '<', $file or return undef;
	local $/;
	my $src = <$fh>;
	close $fh;
	my $R;
	eval $src;                      # our own Dumper output, nobody else's
	return ref $R eq 'HASH' ? $R : undef;
}

# ------------------------------------------------------------------ drivers --

sub run_serial {
	my @queue = @_;
	my @out;
	for my $version (@queue) {
		my $r = run_one($version);
		push @out, $r;
		next unless $r->{failed} && $stop;
		my %done = map { $_->{version} => 1 } @out;
		my @rest = grep { !$done{$_} } @queue;
		print "-- --stop-on-fail: skipping @rest\n" if @rest;
		last;
	}
	return @out;
}

# Fork up to $par children, reaping them as they finish and starting the next
# perl in the freed slot. Unlike the Stats::LikeR original the children share
# this directory: they only read it (see the header).
sub run_parallel {
	my @order = @_;
	my @queue = @order;
	my %kid;                        # pid => { version, result, log }
	my (@out, $halt);

	my $reaper = sub {
		my ($pid, $status) = @_;
		my $kid = delete $kid{$pid} or return;
		my $r   = read_result($kid->{result});
		if (!$r) {
			# The child died without reporting: exec failure, signal, OOM, or
			# a log directory that disappeared under it. Naming a log file
			# that was never created sends the reader looking for evidence
			# that is not there, so distinguish the two.
			my $log = -e $kid->{log} ? $kid->{log}
				: "$kid->{log} (never written)";
			$r = { version => $kid->{version}, log => $log, reported => '?',
				steps => [], seconds => 0, skipped => [],
				failed => sprintf('child exited %d%s', $status >> 8,
					($status & 127) ? ' on signal ' . ($status & 127) : '') };
		}
		push @out, $r;
		report_one($r);
		$halt = 1 if $r->{failed} && $stop;
	};

	local $SIG{INT} = local $SIG{TERM} = sub {
		my $sig = shift;
		print "\n-- $sig: stopping " . keys(%kid) . " running perl(s)\n";
		# each child leads its own process group (see the fork below), so one
		# signal per group takes its harness and the test files' own children
		# with it. The suite forks and sleeps -- t/02.fixes.t kills a task
		# part-way through on purpose -- so signalling the child perl alone
		# would leave those behind.
		kill 'TERM', map { -$_ } keys %kid;
		# not sleep(): the parent is in the middle of reaping, and a sleep
		# here would be interrupted by the SIGCHLDs it is about to get
		select undef, undef, undef, 0.5;
		kill 'KILL', map { -$_ } keys %kid;
		exit 130;
	};

	while (@queue || %kid) {
		while (@queue && keys(%kid) < $par && !$halt) {
			my $version = shift @queue;
			my $result  = File::Spec->catfile($log_dir, "$version.$stamp.result");
			my $log     = File::Spec->catfile($log_dir, "$version.$stamp.log");

			printf "-- %-18s starting\n", $version;
			my $pid = fork;
			die "$0: fork failed: $!\n" unless defined $pid;
			if (!$pid) {                              # child
				$SIG{$_} = 'DEFAULT' for qw(INT TERM);
				setpgrp 0, 0;   # so ^C reaches this whole run, once, via the
						# parent's handler and not the terminal
				# A die in here would otherwise reach the parent as nothing
				# but an exit status, reported as a bare 'child exited N'
				# with no steps and no elapsed time -- indistinguishable
				# from a run that never started. Catch it and put the reason
				# where the parent actually looks, the result file.
				my $r = eval { run_one($version, 1) };
				unless ($r) {
					my $why = $@ || 'run_one returned nothing';
					chomp $why;   # $r->{failed} is printed inside quotes
					$r = { version => $version, log => $log, reported => '?',
						steps => [], seconds => 0, skipped => [],
						failed => $why };
				}
				# last resort: the result file is unwritable, so the only
				# place left to say why is the terminal
				eval { write_result($result, $r); 1 }
					or print STDERR "$0: $version: $@";
				exit 0;
			}
			$kid{$pid} = { version => $version, result => $result, log => $log };
		}
		last unless %kid;
		my $pid = waitpid -1, 0;
		last if $pid <= 0;
		$reaper->($pid, $?);
	}

	print "-- --stop-on-fail: skipping @queue\n" if $halt && @queue;
	# report in version order, not in the order they happened to finish
	my %by = map { $_->{version} => $_ } @out;
	return map { $by{$_} } grep { $by{$_} } @order;
}

# --------------------------------------------------------------- main loop --

my @results;
my $t_all = time;

if ($par > 1 && @targets > 1) {
	$quiet = 1;   # N interleaved test runs on one terminal is noise
	printf "-- %d perl(s), %d at a time%s; per-perl output goes to the logs\n",
		scalar @targets, $par, ($jobs ? " with HARNESS_OPTIONS=j$jobs each" : '');
	print "-- note: --deps has the children sharing one ~/.cpanm; if a "
		. "prerequisite install misbehaves, run once with -P 1 --deps first\n"
		if $deps;
	@results = run_parallel(@targets);
}
else {
	@results = run_serial(@targets);
}

# ----------------------------------------------------------------- summary --

my $bad     = grep { $_->{failed} } @results;
my @skipped = grep { !$_->{failed} && @{ $_->{skipped} } } @results;
print "\n", '=' x 72, "\n";
printf "%-18s %-12s %-7s %-7s %s\n", qw(PERL REPORTED STATUS TIME TESTS);
print '-' x 72, "\n";
for my $r (@results) {
	printf "%-18s %-12s %-7s %6.1fs %s\n",
		$r->{version},
		$r->{reported},
		($r->{failed} ? 'FAIL' : @{ $r->{skipped} } ? 'SKIP' : 'PASS'),
		$r->{seconds},
		# Send the reader to the log only when there is one to read: if
		# whatever removed the log directory mid-run took the log with it,
		# "see <path>" is an invitation to hunt for a file that is not there.
		($r->{failed}
			? "failed at '$r->{failed}' - "
				. (-e $r->{log} ? "see $r->{log}" : "log gone: $r->{log}")
			: @{ $r->{skipped} }
				? 'needs ' . join(' ', @{ $r->{skipped} })
				: ($r->{result} ? "Result: $r->{result}" : 'no test summary'));
}
print '-' x 72, "\n";
my $not_run = @targets - @results;
printf "%d/%d perl(s) passed%s%s in %.1fs.  Logs in %s\n",
	scalar(@results) - $bad - scalar(@skipped), scalar(@targets),
	(@skipped ? ' (' . scalar(@skipped) . ' skipped)' : ''),
	($not_run ? " ($not_run not run)" : ''),
	time - $t_all, $log_dir;
print "-- nothing was built or installed; this directory is untouched\n";

# A skipped perl is a version this run says nothing about, so the way to stop
# skipping it goes on the screen rather than in the log.
if (@skipped) {
	my %want;
	$want{$_} = 1 for map { @{ $_->{skipped} } } @skipped;
	printf "-- %s tested nothing. To fix: %s --deps -p %s\n",
		join(', ', map { $_->{version} } @skipped), $0,
		join(',', map { $_->{version} } @skipped);
	print "   (missing between them: ", join(' ', sort keys %want), ")\n";
}

exit($bad || $not_run ? 1 : 0);
