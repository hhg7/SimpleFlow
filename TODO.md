# TODO

## Make the test suite independent of the signal dispositions it inherits (0.194)

### What went wrong

On 2026-10-05, `cpanm SimpleFlow` (0.193, from CPAN) failed to install because
`t/04.fixes.t` test 15 failed:

```
#   Failed test 'the calling program was ended by the interrupt'
#   at t/04.fixes.t line 371.
#          got: '0'
#     expected: '2'
#   Failed test 'an interrupt during a timed command kills the command too'
```

cpanm had been started as a background job, `( ... & )`, from a
non-interactive shell (HitList's `install.sh`, run in a test sandbox). POSIX
has such a shell start a background command with SIGINT and SIGQUIT ignored,
and an ignored disposition is inherited across `fork` and `exec`. A process
started that way showed `SigIgn: 0000000000000006` (SIGINT and SIGQUIT) in
`/proc/self/status`, and the same command started in the foreground showed
neither bit.

The module behaved as documented. `_run_forked` leaves a signal the caller
ignores ignored, as `system()` does, so the INT that `interrupt_probe` sent to
its child perl did nothing. The child slept out its command's 30 s and exited
0, and the test, which assumes INT kills the child, failed. I checked the
module side directly on 2026-10-05 with perl 5.44.0: with the caller ignoring
INT, and again with it ignoring TERM, a timed task (`timeout => 10`) and an
untimed one whose command sends the signal to `getppid` and to itself both
came back `will.do = done`, exit 0, with the command's output intact.

So the defect is in the tests: several of them rely on a signal's *default*
action without setting it, and fail whenever the harness inherits that signal
ignored. That happens under any background job started by a script, so a CPAN
client run that way cannot install SimpleFlow.

It was not proot, nor perl 5.32.1, nor load. The subtest, repeated 500 times
on this machine and inside proot, with perl 5.44.0 and with conda-forge's
5.32.1, idle and with 40 busy loops on 20 cores, passed every time.

### Which tests are affected

Measured on 2026-10-05 against the working copy (`$VERSION = '0.193'`, perl
5.44.0), running `prove -Ilib t/` with each set of signals inherited as
ignored:

| ignored on entry | result | failing tests |
|---|---|---|
| none | PASS, 29 s | |
| INT, QUIT (any background job) | FAIL, 59 s | `t/04.fixes.t` 15 (block 10) |
| HUP (`nohup`) | PASS | |
| TERM | FAIL, 89 s | `t/01.t` 11; `t/04.fixes.t` 2 (block 1) and 22 (block 17); `t/06.pipeline.t` 7 |
| TSTP | PASS | |
| CHLD | PASS | |

The longer run times are the 30 s sleeps of the probes' commands being waited
out, once per failing probe.

To reproduce:

```sh
perl -e '$SIG{$_} = "IGNORE" for qw(INT QUIT); exec @ARGV' prove -Ilib t/
perl -e '$SIG{TERM} = "IGNORE"; exec @ARGV' prove -Ilib t/
```

### The fix

Every test that depends on a signal's default action sets that default itself,
in the process that has to receive the signal, rather than inheriting it. I
prototyped the four changes below in a scratch copy of `t/`. With them, the
whole suite passed with nothing ignored, with INT and QUIT ignored, with HUP
ignored, with TERM ignored, and with all four ignored at once, in 28-29 s each
time.

1. `t/04.fixes.t`, `interrupt_probe` (line 60): in the forked child, before
   the `exec` at line 69, add

   ```perl
   $SIG{$_} = 'DEFAULT' foreach qw(HUP INT QUIT TERM);
   ```

   A default disposition survives `exec`, so the child perl starts with INT
   and TERM able to end it. This fixes block 10 (test 15) and block 17
   (test 22).

2. `t/04.fixes.t`, block 1, line 137: the command kills itself with TERM, and
   inherits TERM ignored along with everything else. Make it

   ```perl
   q{$SIG{TERM} = q{DEFAULT}; kill 'TERM', $$}
   ```

   (test 2). Block 1's other subtest uses `kill 9`, which cannot be ignored.

3. `t/01.t`, line 211: the same for the shell-routed command,

   ```perl
   my $cmd = qq{$PERL -e '\$SIG{TERM} = q{DEFAULT}; kill 15 => \$\$'};
   ```

   (test 11).

4. `t/06.pipeline.t`, subtest 'parallel: a TERM to perl ends every running
   step, and then perl' (line 143): in the forked child, before the `exec` at
   line 155, add the same line as in item 1 (test 7).

Each site should carry a short comment saying why: the harness may have
inherited the signal ignored (a background job of a non-interactive shell
starts with INT and QUIT ignored), and task() would then rightly leave it
ignored. `t/09.fixes.t` block 15 already does it this way, setting
`$SIG{TERM} = q{DEFAULT}` explicitly in the child that must die of TERM.

Per the CLAUDE.md rule that a regression test must be shown to fail first, the
reproduction commands above are the failing case against 0.193, and they must
pass once the fix is in.

### Test the promise the failure exercised by accident

No test sets a signal to `'IGNORE'` in the *caller* before calling `task()` or
`parallel()`, although the module promises (in the comments above
`_run_forked`, and in `@interrupts` at lines 766 and 2086) that a signal the
caller ignores stays ignored, by perl and, since it is inherited, by the
command. The background run is the only thing that has exercised that branch.
Add a block that, for INT and TERM at least, sets `local $SIG{$sig} =
'IGNORE'` and checks:

- a timed `task()` (`timeout => 10`) whose command sends the signal to
  `getppid` and then to itself, and then prints a sentinel: perl lives, the
  record is `done`, exit 0, signal 0, and stdout holds the sentinel (the
  positive assertion, so the test cannot pass by the command never running);
- the same with no timeout;
- the same through `parallel()`, which I did not try.

The `task()` cases above passed against 0.193 when I ran them by hand, so this
block is coverage of current behaviour, not a regression test, and belongs
with the feature tests rather than in a `fixes` file.

### Stop it recurring

- Add a test that re-runs the signal-dependent files as child processes with
  HUP, INT, QUIT, TERM and TSTP inherited ignored, and asserts that each exits
  0. Re-running `t/01.t`, `t/04.fixes.t` and `t/06.pipeline.t` that way took
  1.3 s, 5.1 s and 1.4 s with the fix in. Re-running every other `t/*.t`
  instead would also catch signal tests added later, at the cost of about
  29 s, the length of the whole suite now. I would take the whole-suite
  version: the failure it guards against arrives through a new test as easily
  as through an old one. It needs only `$^X`, so it runs on a bare smoker, and
  it should skip on MSWin32 like the other signal tests.
- Add a rule to CLAUDE.md, under "The suite must pass on a bare smoker": a test
  that needs a signal to end a process sets that signal to `'DEFAULT'` in the
  process concerned, because the harness may have inherited it ignored, and
  task() leaves an inherited ignore alone by design.

### Release

0.193 has shipped, so this is 0.194: prepend a `0.194` section to `Changes`
(a ` [Tests]` heading, saying that the suite no longer fails when run with
signals ignored, as under a background job, and naming the 0.193 symptom),
bump `$VERSION` in `lib/SimpleFlow.pm` to match, and run `test.all.perls.pl`
before building, as CLAUDE.md requires. No module code changes, and
`README.md` needs nothing.
