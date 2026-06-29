#!/usr/bin/env perl

require 5.010;
use feature 'say';
use warnings FATAL => 'all';
use autodie ':default';
#use DDP {output => 'STDOUT', array_max => 10, show_memsize => 1};
use Devel::Confess 'color';
use Markdown::To::POD 'markdown_to_pod';
use List::MoreUtils 'first_index';

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

my @pod = split /\n/, $pod;
unshift @pod, "=encoding utf8\n";

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
