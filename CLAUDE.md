# SimpleFlow — instructions for Claude

SimpleFlow is a pure-Perl workflow manager: one `task()` call per pipeline
step, which validates the inputs, runs the command, decodes its exit status,
captures its output, checks the declared outputs, and returns a record of what
happened. It ships to CPAN, so it has to work on perls and platforms that are
not this one.

## Never hand-edit the generated files

Four things in this repo are generated from `README.md` by `perl md2pod.pl`:

- `read.me.pod`
- the POD block in `lib/SimpleFlow.pm` after the `1;` line — `md2pod.pl`
  truncates the file at `1;` and re-appends the POD, so anything written into
  that block by hand is destroyed on the next run
- `Changes`, built from the `# Changes` section of `README.md` and checked
  with `Test::CPAN::Changes`
- the `SimpleFlow-0.*/` directories and `SimpleFlow-0.*.tar.gz` tarballs, which
  are `dzil build` output

Documentation changes go into `README.md`, and then `perl md2pod.pl` is run.
Never `Edit`, `Write`, `sed -i` or patch the generated copies directly, and
never fix a POD problem in `lib/SimpleFlow.pm` — fix the Markdown it came from.

`cover_db/` is `Devel::Cover` output; regenerate it with `sh cover.sh` rather
than editing it. `backup.pm` is a stale copy of the 0.13 module kept out of the
distribution by `MANIFEST.SKIP`; it is not the module, is not loaded by
anything, and must not be edited or read as authoritative.

### Release notes are the maintainer's prose

The `# Changes` section of `README.md` is hand-written release notes. Do not
add, reword or reorder an entry there, not even for work Claude just did, and
not even when asked to "update the changelog" as part of a larger task. When a
change would warrant a release note, say so in the reply and leave the wording
to the maintainer. Everything else in `README.md` is ordinary documentation and
is editable in the normal way.

## Everything runs under `use warnings FATAL => 'all'`

The module says it, the tests say it, and the documentation tells callers to
say it. That is the single largest source of past defects here, because it
promotes every "uninitialized value" from a nuisance to a crash — in the
*caller's* program, not in SimpleFlow's. 0.13, 0.14 and 0.16 each shipped a fix
of exactly this shape.

- **Never let a filetest or `length` see an undef.** `-f undef` and
  `length undef` are fatal warnings here. Validate a name before it is
  filetested, which is why `_normalise_files` rejects undef and `''` before any
  `-f` runs; `-f ''` is merely false, so an unvalidated bad name used to
  surface as the misleading "missing or unreadable".
- **`-s $file` on a missing file is undef,** so `(-s $file) == 0` is a fatal
  comparison, not a size check. Default it (`($size{$_} // 0) == 0`) or test
  existence first.
- **The result hash has the same keys on every return path.** `exit`, `signal`,
  `stdout`, `stderr`, `timed.out`, `duration`, `will.do`, `done`,
  `out.of.date` and the resolved options are seeded before the first `return`,
  so that a caller reading `$t->{'exit'}` after a skip or a dry run does not
  die. A new field that a command produces must be seeded with its empty value
  alongside them; a field that exists on only one path is a bug.

## Perl idiom in this module

The module is written to a narrow house style; match it rather than the wider
Perl you would write elsewhere.

- **Indent with tabs.** Comments are `#`; a block comment is a run of `#` lines
  directly above the code, and a single fact about one line trails it. The
  `/* … */` formatting in the global `CLAUDE.md` is C-specific and does not
  apply — the rest of that comment doctrine does.
- **The accepted keys are the public API.** They live in one place,
  `@defined_args` inside `task`, each with a trailing comment naming its type
  and meaning (`'stale', # bool; also re-run when an input is newer than an
  output`). Adding a key means adding it there with its comment, documenting it
  in `README.md`, and giving it a resolved default; an unlisted key is a fatal
  argument error, which is deliberate.
- **Resolve each option exactly once, then read the resolved copy.**
  `$r{'die'} = $args->{'die'} // 1;` and every later test reads `$r{'die'}`.
  The 0.14 bug was a block testing the raw `$args->{'die'}` — undef when the
  caller omitted it — so the documented default of 1 was silently ignored on
  that path. Never test `$args->{...}` for an option that has a default.
- **Booleans are 0 or 1 on the result,** never undef and never the caller's
  original string, so that printing the record and comparing fields both work.
- **Enumerated values are commented at the declaration,** per the global
  doctrine. `will.do` is one of `yes`, `no`, `no: dry run`, `done`, `FAILED`;
  `done` is one of `before`, `not yet`, `now`. Changing that vocabulary is an
  incompatible change to the API.
- **Error paths dump the arguments with `p` and then `die` with a message that
  names the offending value** — the key, the index, the exit code, the file.
  "the above args are not recognized" is only useful because `p` printed them.
- **Prefer core to a new dependency.** `_autoflush` uses `select` rather than
  pulling in `IO::Handle`; 0.15 removed `Term::ANSIColor` in favour of a
  nine-line `colored` that maps the handful of colour names actually used. A new
  prereq must be justified, added to `dist.ini`, and confirmed installed on
  `perl-5.10.1` (see the support matrix below).

## Portability: POSIX and Windows

There is no local Windows perl, so this is discipline applied while writing,
not something a test run here will catch.

- **The command runs through `system`, and the wait status is decoded
  differently per platform.** The death signal is the low 7 bits of the *raw*
  status and the exit code is the high byte; the signal must be read before the
  shift. Reading it afterwards is the 0.13 bug — `$r{signal}` was always 0 and
  could never see a kill by 9 or 15. Windows has no POSIX signals, so `signal`
  is 0 there; a `system` return of -1 means the command never launched, and is
  reported as `exit => -1`.
- **Anything needing `fork`, process groups or signals is POSIX-only and must
  refuse on `MSWin32` with a message saying why,** as `timeout` does. Do not
  quietly degrade such a feature to a no-op.
- **Never wrap `system` in a `$SIG{ALRM}`.** An alarm that fires while `system`
  is blocked in `waitpid` unwinds the Perl stack and leaves the child running
  as an orphan. `_run_with_timeout` forks explicitly and puts the child in its
  own process group so the *group* can be killed: a shell command is usually a
  pipeline, and killing only the shell leaves its children behind. In the
  child, `POSIX::_exit`, not `exit` — `exit` runs END blocks and flushes the
  parent's buffers a second time.
- **ANSI colour is disabled on the legacy Windows console** by the `BEGIN`
  block, unless Windows Terminal, ConEmu or ANSICON is detected. Anything new
  that colours output goes through `colored`, which honours
  `$ENV{ANSI_COLORS_DISABLED}` at call time.
- **Tests may not assume Unix.** No `which`, `ls`, `ln` or `cp`, no hardcoded
  `/tmp`, no `/` pasted into a path. Run the interpreter that is already
  running — `my $PERL = qq{"$^X"}` (quoted, because its path can contain
  spaces) — take temporary files and directories from `File::Temp`, and build
  paths with `File::Spec`. `t/01.t`'s header explains this; follow it. The
  `$code` handed to `perl_cmd()` must not itself contain a double quote.
- **Log output is autoflushed.** Without it the record of the very task that
  killed the run is still in stdio's buffer when the process dies: measured
  with a `SIGKILL` part-way through a pipeline, a log that reached 862 bytes on
  a clean exit held 139 bytes after the kill. Any new routine that writes to
  `log.fh` autoflushes it first.

## Tests

`t/01.t` is the feature smoke test, `t/02.fixes.t` the regression suite for the
0.16 defects and the options added with them, and `t/more.coverage.t` reaches
the error branches the other two do not. All three pass under
`prove -Ilib t/`.

### A regression test must be shown to fail before the fix

The only evidence that a regression test tests anything is that it failed
against the release that had the bug. So, for every defect fixed here:

- Write the test first and **confirm it fails against the previous release**
  (unpack the `SimpleFlow-0.*/` tarball for that version, or `git stash` the
  fix) before the fix goes in. `t/02.fixes.t` blocks 1-11 were each confirmed
  against 0.15, and its header says so.
- **Use only arguments the old release accepted,** so the block can still be
  re-run against an old checkout. Tests for genuinely new options go in a
  clearly separated group — blocks 12-16 of `t/02.fixes.t` — because they
  cannot run against the older module at all.
- **Name the old behaviour in the test's comment and in its description**, so
  that a re-break is recognisable from the failure message alone.

### Never assert only that something is empty

An assertion that a list is empty, or that no warning was emitted, passes
whenever the probe producing it never ran. Assert a positive sentinel first —
that the probe did run and produced what it should — and only then assert the
absence. Two tests in `t/02.fixes.t` would once have passed for the wrong
reason; the comments at those sites say so.

### The suite must pass on a bare smoker

No network, no external tools, nothing installed beyond the prereqs in
`dist.ini`. That means no `qx{}` or `system` calls to anything but `$^X`, and
no `plan skip_all` or `SKIP` conditioned on some other program being present —
a test that skips on a CPAN smoker is a test that never runs there.

A child process that has to load the module itself gets the path the test file
loaded it from (`$INC{'SimpleFlow.pm'}`), never a bare `-MSimpleFlow`, so it
tests this working copy rather than whatever is installed system-wide.

### Coverage

`sh cover.sh` deletes the old database, re-runs the suite under
`Devel::Cover`, and writes `cover_db/coverage.html`. The committed `cover_db/`
is stale — it predates `t/02.fixes.t` — so regenerate before quoting a number
rather than reading the checked-in report.

Aim to exercise every path, not one representative call: each call form (hash
ref and flat key/value list, plus the odd-length error), each option and its
default, both `die => 1` and `die => 0`, every `die` and `warn` message, every
argument-validation branch, and each documented field of the returned record.
Choose any timeout or sleep in a test from a measurement and say so in a
comment; never lengthen one to make an intermittent failure go away.

## Every change must hold across the support matrix

`dist.ini` declares `perl = 5.010` and `lib/SimpleFlow.pm` says
`require 5.010`. A change is not finished when it works on the default perl.

### Back-compatible to perl 5.10

- 5.10 syntax only: no signatures, no postfix dereference, no `s///r` (5.14),
  no `package NAME BLOCK` (5.14), no `keys`/`each`/`values` on a reference, no
  `__SUB__` or `fc` (5.16), no lexical subs. `//`, `state` and `say` are 5.10,
  but `say` needs `use feature 'say'`, which the module and every test already
  have.
- Test files follow the existing header — `use strict; use warnings FATAL =>
  'all'; require 5.010; use feature 'say';` — not `use 5.044`.
- `md2pod.pl` is exempt: it is an author-only script, kept out of the
  distribution by `MANIFEST.SKIP`, and may use modern perl (it says
  `use 5.044`).
- Raising the minimum is a maintainer decision, not a way to make an error go
  away. If a change truly needs a newer perl, say so in the reply and stop.

### The perls installed here

Under `/home/con/perl5/perlbrew/perls/`: `perl-5.44.0` (the default),
`perl-5.42.3`, `perl-5.12.5`, `perl-5.10.1`, and `5.44.0-quadmath`. The module
is pure Perl, so NV width is irrelevant; the *version* spread is what matters.

The prereqs (`Capture::Tiny`, `Data::Printer`, `Devel::Confess`,
`Test::Exception`) are installed on `perl-5.10.1` and `perl-5.12.5` but **not**
on `perl-5.42.3`, so 5.42.3 cannot run the suite as it stands. Check the oldest
supported perl for anything touching `lib/SimpleFlow.pm`:

    /home/con/perl5/perlbrew/perls/perl-5.10.1/bin/perl -Ilib \
        -MTest::Harness -e 'runtests(glob "t/*.t")'

As of 2026-09-02 that passes all 48 tests, as does `prove -Ilib t/` on 5.44.0.

## Compatibility of the interface itself

The keys accepted by `task` and the keys of the record it returns are the
public API, documented in `README.md` and depended on by pipelines already
written.

- **New behaviour that would change what an existing pipeline does defaults to
  off.** `stale` re-runs a step whose input is newer than its output — the rule
  `make` and `snakemake` use — and is off by default precisely because turning
  it on unconditionally would silently start re-running steps in pipelines
  written against 0.15.
- **Removing, renaming or changing the type of a returned field is an
  incompatible change** and must be reported as such in the reply, so the
  maintainer can note it in the release notes. 0.16 made `input.files` always
  an array ref, matching `output.files`; that was flagged as incompatible.
- **`$VERSION` stays a quoted string.** As a bare number it is stringified
  through `%g`, so a future `0.20` becomes `"0.2"` and compares as older than
  `"0.15"` on CPAN. `dist.ini` takes the version from the module
  (`[VersionFromModule]`), so the module is the one place it is set.

## Releasing

`sh dzil.sh` regenerates the documentation, commits the generated files, and
runs `dzil clean` and `dzil build`; it deliberately stops before
`dzil release`, which the maintainer runs by hand. Do not run `dzil release`,
and do not commit or push unless asked.

`dzil clean` prunes every `SimpleFlow-*` directory and tarball in the root,
including the older ones that are tracked in git (0.14, 0.15). If a build was
run for any reason other than a release, restore them:
`git checkout -- SimpleFlow-0.15 SimpleFlow-0.15.tar.gz`.

## Kwalitee stays at 33/33

Measured with `Module::CPANTS::Analyse` 1.03 on the built tarball, which is
what CPANTS itself runs:

    perl -MModule::CPANTS::Analyse -e '
        my $a = Module::CPANTS::Analyse->new({dist => shift});
        $a->run;
        my $k = $a->d->{kwalitee};
        printf "%s\n", $k->{kwalitee};
        print "FAILED: $_\n" for grep { $_ ne "kwalitee" && !$k->{$_} } sort keys %$k;
    ' SimpleFlow-0.16.tar.gz

0.16 scored 30/33 before 2026-09-02, failing `has_abstract_in_pod`,
`has_meta_json` and `meta_yml_has_provides`. Three things now keep it at 33:

- `md2pod.pl` writes the `=head1 NAME` / `=head1 VERSION` header itself, taking
  the package, the `# ABSTRACT:` line and `$VERSION` from `lib/SimpleFlow.pm`.
  CPANTS scans `=head` sections for a `<Package> - <abstract>` line
  (`Module::CPANTS::Kwalitee::Pod` 1.03, `_parse_abstract`), and nothing in
  `README.md` supplies one. `md2pod.pl` re-checks both generated files for that
  line, so the metric cannot be lost silently.
- `[MetaJSON]` in `dist.ini` (`has_meta_json`).
- `[MetaProvides::Package]` in `dist.ini` (`meta_yml_has_provides`).

Anything added to the repo root that should not ship — `CLAUDE.md` is the
current example — needs a `MANIFEST.SKIP` entry, or `[@Basic]`'s GatherDir
sweeps it into the distribution.
