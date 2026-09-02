#!/usr/bin/env perl

use 5.044;
no source::encoding;
use warnings FATAL => 'all';
use autodie ':default';
#use DDP {output => 'STDOUT', array_max => 10, show_memsize => 1};
use Devel::Confess 'color';
use Markdown::To::POD 'markdown_to_pod';
use List::MoreUtils 'first_index';
use Test::More;
use Test::Pod;
use Test::CPAN::Changes;
use Module::CPANTS::Analyse;

sub file2string {
	my $file = shift;
	open my $fh, '<', $file;
	return do { local $/; <$fh> };
}

# GitHub-flavoured-Markdown heading -> anchor slug (lowercase, punctuation
# dropped, spaces -> hyphens). Used to resolve "#anchor" links back to a
# heading title so they can become proper POD section links.
sub gfm_slug {
	my ($s) = @_;
	$s = lc $s;
	$s =~ s/[^\w\- ]//g; # keep word chars, hyphen and space
	$s =~ s/ /-/g;
	return $s;
}

# Build { anchor-slug => heading title (formatting stripped) } from the
# Markdown headings, so internal links can target the real section name.
sub build_anchor_map {
	my ($text) = @_;
	my %anchor2title;
	for my $line (split /\n/, $text) {
		next unless $line =~ /^\s*#{1,6}\s+(.+?)\s*#*\s*$/;
		(my $title = $1) =~ s/[`*_]//g;   # strip inline code/emphasis markers
		$title =~ s/^\s+|\s+$//g;
		my $slug = gfm_slug($title);
		$anchor2title{$slug} //= $title;  # first heading wins on a slug clash
	}
	return \%anchor2title;
}

# Turn one Markdown link into the cleanest POD equivalent:
#   [text](#anchor)                         -> L</"Section">      (or L<text|/"Section">)
#   [text](https://metacpan.org/pod/Mod)    -> L<Mod>             (canonical module link)
#   [text](other-url)                       -> L<text|other-url>
sub link_to_pod {
	my ($text, $target, $anchor2title) = @_;
	(my $plain = $text) =~ s/[`*_]//g;       # POD L<> text should be plain
	$plain =~ s/^\s+|\s+$//g;

	if ($target =~ /^#(.+)$/) {              # internal section link
		my $title = $anchor2title->{$1};
		if (defined $title) {
			return $plain eq $title ? qq{L</"$title">}
			                        : qq{L<$plain|/"$title">};
		}
		return $plain;                       # unknown anchor: drop the dead link
	}
	if ($target =~ m{^https?://metacpan\.org/pod/([\w:]+)/?$}) {
		return "L<$1>";                      # idiomatic CPAN module link
	}
	return qq{L<$plain|$target>};            # ordinary external link
}

# Pull Markdown links out of prose and stash their POD form behind a delimited
# placeholder, so markdown_to_pod() can't re-mangle them. The trailing
# PODLINKEND sentinel makes restoration unambiguous (placeholder 1 can never
# match inside placeholder 10, 11, ...). Links are inline, so -- unlike the
# block-level table placeholders -- no surrounding blank lines are added.
sub extract_and_convert_links {
	my ($text, $anchor2title) = @_;
	my @saved;
	$text =~ s{
		\[ ( [^\]]+ ) \] \( ( [^)]+ ) \)
	}{
		push @saved, link_to_pod($1, $2, $anchor2title);
		'PODLINKPLACEHOLDER' . $#saved . 'PODLINKEND'
	}gex;
	return ($text, \@saved);
}

# Helper to build an HTML table from extracted Markdown rows
sub table_to_html {
	my ($header, $sep, $body_ref) = @_;
	my $html = "<table>\n";

	# Process header
	$html .= "<thead>\n<tr>\n";
	my @headers = split /\|/, $header;
	# Clean empty elements if the row was wrapped in leading/trailing pipes
	shift @headers if @headers && $headers[0] =~ /^\s*$/ && $header =~ /^\s*\|/;
	pop @headers   if @headers && $headers[-1] =~ /^\s*$/ && $header =~ /\|\s*$/;
	for my $h (@headers) {
		$h =~ s/^\s+|\s+$//g;
		$html .= "  <th>$h</th>\n";
	}
	$html .= "</tr>\n</thead>\n<tbody>\n";
	# Process body
	for my $row (@$body_ref) {
		$html .= "<tr>\n";
		my @cells = split /\|/, $row;
		shift @cells if @cells && $cells[0] =~ /^\s*$/ && $row =~ /^\s*\|/;
		pop @cells   if @cells && $cells[-1] =~ /^\s*$/ && $row =~ /\|\s*$/;

		for my $c (@cells) {
			$c =~ s/^\s+|\s+$//g;
			# Links first, so the URL/text aren't touched by the formatting
			# regexes below. Internal "#anchor" links become plain text (a
			# raw <a href="#..."> would not reliably match metacpan's POD
			# heading ids); external links become real anchors.
			$c =~ s{\[ ([^\]]+) \] \( ([^)]+) \)}{
				my ($t, $u) = ($1, $2);
				$u =~ /^#/ ? $t : qq{<a href="$u">$t</a>}
			}gex;
			# Convert Markdown inline formatting so it renders correctly inside the HTML block
			$c =~ s/`([^`]+)`/<code>$1<\/code>/g;
			$c =~ s/\*\*([^\*]+)\*\*/<b>$1<\/b>/g;
			$c =~ s/\*([^\*]+)\*/<i>$1<\/i>/g;
			$html .= "  <td>$c</td>\n";
		}

		# Pad with empty cells if a row was missing trailing pipes
		while (@cells < @headers) {
			$html .= "  <td></td>\n";
			push @cells, "";
		}
		$html .= "</tr>\n";
	}
	$html .= "</tbody>\n</table>\n";

	# Ensure blank lines around the =begin and =end directives for valid POD
	return "\n\n=begin html\n\n$html\n=end html\n\n";
}

# Pre-processor to extract GFM tables and replace them with alphanumeric placeholders
sub extract_and_convert_tables {
	my ($text) = @_;
	my @lines = split /\n/, $text;
	my @out;
	my @saved_tables;
	my $i = 0;

	while ($i < @lines) {
		# Look for a table header followed by a standard GFM separator row
		if ($i + 1 < @lines &&
			$lines[$i] =~ /\|/ &&
			$lines[$i+1] =~ /^[ \t]*\|?[ \t]*:?-+[-: \t]*\|/) {

			my $header = $lines[$i];
			my $sep = $lines[$i+1];
			my @body;
			$i += 2;

			# Consume consecutive data rows (must contain at least one pipe)
			while ($i < @lines && $lines[$i] =~ /\|/) {
				push @body, $lines[$i];
				$i++;
			}
			my $html = table_to_html($header, $sep, \@body);
			push @saved_tables, $html;
			# Use an alphanumeric placeholder to prevent Markdown parser interference
			push @out, "\n\nHTMLTABLEPLACEHOLDER" . ($#saved_tables) . "\n\n";
		} else {
			push @out, $lines[$i];
			$i++;
		}
	}
	return (join("\n", @out), \@saved_tables);
}

# The distribution's identity, read out of the module rather than repeated
# here: the package statement, the "# ABSTRACT:" line that dzil turns into
# META's abstract, and $VERSION.
sub module_identity {
	my ($file) = @_;
	my $src = file2string($file);
	my ($package)  = $src =~ /^\s*package\s+([\w:]+)\s*;/m;
	my ($version)  = $src =~ /^\s*our\s+\$VERSION\s*=\s*'([^']+)'/m;
	my ($abstract) = $src =~ /^\s*#\s*ABSTRACT:\s*(.+?)\s*$/m;
	die "Could not find a package statement in $file" unless defined $package;
	# Only the quoted form is matched on purpose. $VERSION is a string because
	# a bare 0.20 is stringified through %g to "0.2" and then compares as older
	# than "0.15" on CPAN; a bare number here is a defect to report, not to
	# quietly accept.
	die "Could not find a quoted \$VERSION in $file" unless defined $version;
	die "Could not find a '# ABSTRACT:' line in $file" unless defined $abstract;
	# dzil's abstract is the description on its own, but this one is written
	# with the module name in front of it and the NAME line supplies that name
	# again. Drop the duplicate rather than emit "SimpleFlow - SimpleFlow - ...".
	$abstract =~ s/^\Q$package\E\s*-+\s*//;
	return ($package, $version, $abstract);
}

# CPANTS scores a distribution's tarball, so the check below needs one, and the
# tarball that matters is the one for the version in lib/SimpleFlow.pm. `dzil
# clean` deletes every SimpleFlow-*.tar.gz before `dzil build` writes the new
# one, so at the point dzil.sh runs md2pod.pl the current version's tarball does
# not exist yet: fall back to the newest one present, and let the caller say so.
sub dist_tarball {
	my ($version) = @_;
	my @tarballs = glob 'SimpleFlow-*.tar.gz';
	my $current  = "SimpleFlow-$version.tar.gz";
	return $current if grep { $_ eq $current } @tarballs;
	# Perl versions of this shape are decimals, so 0.9 is newer than 0.16 and
	# only a numeric comparison -- not a string one -- picks the right tarball.
	my @newest_last =
		map  { $_->[1] }
		sort { $a->[0] <=> $b->[0] }
		map  { [ (/^SimpleFlow-([\d.]+)\.tar\.gz$/ ? $1 : 0), $_ ] } @tarballs;
	return $newest_last[-1];   # undef when the glob matched nothing
}

# The kwalitee score, measured the way CPANTS itself measures it: with
# Module::CPANTS::Analyse on the built tarball. The score is out of the number
# of metrics the analyser reports, so "as good as it gets" is exactly "no
# metric came back false", and the diagnostics name any that did. 0.16 scored
# 30/33 before 2026-09-02, failing has_abstract_in_pod -- which the NAME header
# this script writes exists to fix -- plus has_meta_json and
# meta_yml_has_provides, fixed by [MetaJSON] and [MetaProvides::Package] in
# dist.ini. None of the three can be lost silently now.
sub kwalitee_test {
	my ($version) = @_;
	my $tarball = dist_tarball($version);
	unless (defined $tarball) {
		fail 'a SimpleFlow tarball is present to measure kwalitee on';
		diag 'No SimpleFlow-*.tar.gz in the repository root; run `dzil build`.';
		return;
	}
	diag "kwalitee measured on $tarball, not on the current version $version"
		unless $tarball eq "SimpleFlow-$version.tar.gz";
	my $analyse = Module::CPANTS::Analyse->new({dist => $tarball});
	$analyse->run;
	my $k = $analyse->d->{'kwalitee'};
	# One key per metric, plus the 'kwalitee' total itself.
	my @metrics = grep { $_ ne 'kwalitee' } sort keys %$k;
	my @failed  = grep { !$k->{$_} } @metrics;
	# Count the metrics before judging them: an analyser that returned nothing
	# leaves @failed empty too, and "nothing failed" would then pass for the
	# wrong reason. 33 is what Module::CPANTS::Analyse 1.03 reported on
	# SimpleFlow-0.16.tar.gz on 2026-09-02; a later release may add metrics, so
	# this is a floor rather than an equality.
	ok scalar(@metrics) >= 33,
		sprintf 'CPANTS reported %d kwalitee metrics on %s', scalar @metrics, $tarball;
	is $k->{'kwalitee'}, scalar @metrics,
		sprintf '%s scores kwalitee %d/%d', $tarball, $k->{'kwalitee'}, scalar @metrics;
	diag "failed kwalitee metric: $_" for @failed;
	return;
}

# dzil.sh re-invokes the script this way after `dzil build`, so that the score
# is measured on the tarball just built rather than on the previous release's,
# which is all that exists while the documentation above is being generated.
if (grep { $_ eq '--kwalitee-only' } @ARGV) {
	my (undef, $built_version) = module_identity('lib/SimpleFlow.pm');
	kwalitee_test($built_version);
	done_testing();
	# Test::Builder's END block still sets a failing exit status through this.
	exit 0;
}

my $md = file2string('README.md');

# 0. Map heading anchors to titles so internal links can be resolved.
my $anchor2title = build_anchor_map($md);

# 1. Pre-process the Markdown to convert GFM tables into POD HTML blocks
#    (links inside table cells are handled by table_to_html).
my ($md_processed, $tables_ref) = extract_and_convert_tables($md);

# 1b. Pre-process prose links into clean POD codes, stashed behind placeholders.
my ($md_links, $links_ref) = extract_and_convert_links($md_processed, $anchor2title);

# 2. Convert standard markdown to POD
my $pod = markdown_to_pod($md_links);

# 3. Restore the POD links, then the HTML tables, into the generated POD.
for my $idx (0 .. $#$links_ref) {
	my $link_pod = $links_ref->[$idx];
	# The PODLINKEND sentinel makes this unambiguous without a \b anchor.
	$pod =~ s/PODLINKPLACEHOLDER${idx}PODLINKEND/$link_pod/g;
}
for my $idx (0 .. $#$tables_ref) {
	my $table_html = $tables_ref->[$idx];
	# Anchor the end of the number with \b: without it the /g replace for a
	# short index (e.g. 1) also matches the prefix of longer placeholders
	# (HTMLTABLEPLACEHOLDER10, ...11), dropping the wrong table there and
	# leaving a stray leftover digit. \b stops after the last digit, so
	# HTMLTABLEPLACEHOLDER1 no longer matches inside HTMLTABLEPLACEHOLDER10.
	$pod =~ s/HTMLTABLEPLACEHOLDER${idx}\b/$table_html/g;
}

my ($package, $version, $abstract) = module_identity('lib/SimpleFlow.pm');

my @pod = split /\n/, $pod;
shift @pod while (scalar @pod > 0) && ($pod[0] =~ /^\s*$/);

# CPANTS reads a distribution's abstract out of the POD itself: it scans =head
# sections for a "<Package> - <abstract>" line (Module::CPANTS::Kwalitee::Pod
# 1.03, _parse_abstract) and fails has_abstract_in_pod when no file in the
# distribution has one, which is why SimpleFlow 0.16 scored 30/33 where
# Stats::LikeR scores 33/33. README.md has no NAME heading and should not grow
# one -- it is read as a web page -- so the section is written here instead, in
# the form Pod::Weaver emits for Stats::LikeR.
my @header = (
	'=encoding utf8',
	'',
	'=head1 NAME',
	'',
	"$package - $abstract",
	'',
	'=head1 VERSION',
	'',
	"version $version",
	'',
);

# README.md opens with prose, and POD has nowhere to put a paragraph that comes
# before every heading: left where it is, it renders as the body of the VERSION
# section. Give it the heading a reader expects to find it under.
push @header, ('=head1 DESCRIPTION', '') if (scalar @pod > 0) && ($pod[0] !~ /^=/);

unshift @pod, @header;

say 'Writing read.me.pod from README.md, which must be copied into lib/SimpleFlow.pm';
open my $fh, '>', 'read.me.pod';
say $fh join ("\n", @pod);
close $fh;

my $lib = file2string('lib/SimpleFlow.pm');
my @lib = split /\n/, $lib;
my $line = first_index {$_ eq '1;'} @lib;
if ($line == -1) {
	die 'Could not find correct line index';
}

# Trim everything after `1;` to prep for new POD insertion. Keep lines
# 0..$line (the code, up to and including `1;`) and drop the rest. NB:
# $line+1 is correct whether or not POD already trails `1;`; the earlier
# `1-(scalar @lib - $line)` form only worked when POD followed and silently
# wiped the whole module on a first run where `1;` was the last line.
splice @lib, $line + 1;
push @lib, '', @pod;   # blank line so the POD '=' directive is recognised

open my $out_fh, '>', 'lib/SimpleFlow.pm';
say $out_fh join ("\n", @lib);
close $out_fh;


pod_file_ok( 'lib/SimpleFlow.pm' );

# The NAME section above exists for has_abstract_in_pod, so check the files that
# were actually written the way CPANTS reads them -- the abstract line must sit
# inside a =head section and match "<Package> - <abstract>"
# (Module::CPANTS::Kwalitee::Pod 1.03, _parse_abstract) -- rather than trust
# that the header was emitted.
foreach my $generated ('lib/SimpleFlow.pm', 'read.me.pod') {
	like(
		file2string($generated),
		qr/^=head1 NAME\n\n\Q$package\E\s+-+\s+\S/m,
		"$generated carries a NAME abstract that CPANTS can read"
	);
}

my $outfile = 'Changes';
my $dist    = 'SimpleFlow'; # Inferred from your documentation

open my $out, '>', $outfile or die "Cannot write $outfile: $!\n";

# Write the mandatory CPAN::Changes::Spec header
say $out "Revision history for $dist\n";

my ($needs_bullet, $in_code_block) = (0, 0);
my @md_later = split /\n/, $md;
my $fi = first_index {$_ eq '# Changes'} @md_later;
die 'Could not find a "# Changes" heading in README.md' if $fi == -1;
# Start *after* the "# Changes" heading so the title itself is not emitted.
foreach my $i ($fi + 1 .. $#md_later) {
	my $line = $md_later[$i];
	# Stop at the copyright footer; skip any other stray top-level heading.
	last if $line =~ /^#\s+COPYRIGHT AND LICENSE\s*$/i;
	next if $line =~ /^#\s+\S/ && $line !~ /^#{2,}/;
	# Toggle markdown code blocks (```)
	if ($line =~ /^```/) {
	  $in_code_block = !$in_code_block;
	  next;
	}
	# Handle Versions (e.g., "## 0.21 2026-01-13" or "## 0.21"). The date/note
	# after the version is optional so a version line is always recognised as a
	# release (and never mis-parsed as body text) even if a date is omitted.
	if ($line =~ /^##\h+([\d\._]+)(?:\h+(.+))?\s*$/) {
	  say $out defined $2 ? "$1 $2" : $1;
	  $needs_bullet = 1;
	} elsif ($line =~ /^###\s+(.+)/) {# Handle Groups (e.g., "### read_table")
	  print $out " [$1]\n";
	  $needs_bullet = 1;
	} elsif ($line =~ /^####\s+(.+)/) {
	# Handle Sub-Groups (e.g., "#### Bug fixes")
	  # CPAN Spec doesn't formally have sub-groups, so we format it as a distinct bulleted header
	  say $out " - $1:";
	  $needs_bullet = 1;
	} elsif ($line =~ /^\s*[-*]\s+(.+)/) {	# Handle explicit Markdown bullets
	  print $out " - $1\n";
	  $needs_bullet = 0;
	} elsif ($line =~ /^\s*$/) {# Handle empty lines
	  say $out '';
	  $needs_bullet = 1; # Reset so the next text block gets a bullet
	} else {# Handle normal text or indented code
		# If it's 4-space indented code from Markdown, keep it indented for CPAN
		if ($line =~ /^\s{4,}(.+)/ || $in_code_block) {
			my $code_line = $1 || $line;
			$code_line =~ s/^\s+//; # strip leading space to normalize
			say $out "     $code_line";
		} else {
			# Strip leading/trailing formatting like **bold** just in case it breaks flow, 
			# though CPAN::Changes technically allows it as raw text.
			$line =~ s/\*\*(.+?)\*\*/$1/g; 
			if ($needs_bullet) {
				 print $out " - $line\n";
				 $needs_bullet = 0;
			} else {
				 # Continuation of the previous bullet
				 print $out "   $line\n";
			}
		}
	}
}

close $out;

say "Successfully generated '$outfile' from 'README.md'";
changes_file_ok('Changes');

kwalitee_test($version);
done_testing();
