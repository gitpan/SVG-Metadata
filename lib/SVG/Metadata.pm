=head1 NAME

SVG::Metadata - Perl module to capture metadata info about an SVG file

=head1 SYNOPSIS

 use SVG::Metadata;

 $svgmeta->parse($filename) 
     or die "Could not parse $filename: " . $svgmeta->errormsg();
 $svgmeta2->parse($filename2)
     or die "Could not parse $filename: " . $svgmeta->errormsg();

 # Do the files have the same metadata (author, title, license)?
 if (! $svgmeta->compare($svgmeta2) ) {
    print "$filename is different than $filename2\n";
 }

 if ($svgmeta->title() eq '') {
     $svgmeta->title('Unknown');
 }

 if ($svgmeta->author() eq '') {
     $svgmeta->author('Unknown');
 }

 if ($svgmeta->license() eq '') {
     $svgmeta->license('Unknown');
 }

 if (! $svgmeta->keywords()) {
     $svgmeta->addKeyword('unsorted');
 } elsif ($svgmeta->hasKeyword('unsorted') && $svgmeta->keywords()>1) {
     $svgmeta->removeKeyword('unsorted');
 }

 print $svgmeta->to_text();

=head1 DESCRIPTION

This module provides a way of extracting, browsing and using RDF
metadata embedded in an SVG file.

=head1 FUNCTIONS

=cut


# TODO:
#   * Test the example script
#   * Fill in the rest of the POD stuff

package SVG::Metadata;

use 5.006;
use strict;
use warnings;
use XML::Simple;

use vars qw($VERSION @ISA);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = ();

our $VERSION = '0.01';


use fields qw(
              _title
	      _author
	      _license
              _keywords
              _errormsg
	      );
use vars qw( %FIELDS );


=head2 new

Creates a new SVG::Metadata object.  Optionally, can pass in arguments
'title', 'author', and/or 'license'.

=cut

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = bless [\%FIELDS], $class;

    $self->{_title}    = $args{title} || '';
    $self->{_author}   = $args{author} || '';
    $self->{_license}  = $args{license} || '';
    $self->{_keywords} = $args{keywords} || {};
    $self->{_errormsg} = '';

    return $self;
}

=head2 errormsg

Returns the last encountered error message.  Most of the error messages
are encountered during file parsing.

=cut

sub errormsg {
    my $self = shift;
    return $self->{_errormsg};
}


=head2 parse

Extracts RDF metadata out of an existing SVG file.

    $svgmeta->parse($filename) || die "Error: " . $svgmeta->errormsg();

This routine looks for a field in the rdf:RDF section of the document
named 'ns:Work' and then attempts to load the following keys from it:
'dc:title', 'dc:rights'->'ns:Agent', and 'ns:license'.  If any are
missing, it 

Returns undef if there was a problem parsing the file, and sets an 
error message appropriately.  The conditions under which it will return
undef are as follows:  No 'filename' parameter given

=cut

sub parse {
    my $self = shift;
    my $filename = shift;

    if (! defined($filename)) {
	$self->{_errormsg} = "No filename argument defined for parsing";
	return undef;
    }

    if (! -e $filename) {
	$self->{_errormsg} = "Filename '$filename' does not exist";
	return undef;
    }

    my $ref = eval { XMLin($filename) };

    if ($@) {
	$self->{_errormsg} = "Error parsing file:  $@";
	return undef;
    }

    if (! defined($ref)) {
	$self->{_errormsg} = "XML::Simple did not return a valid XML object";
	return undef;
    }

    if (! defined($ref->{'rdf:RDF'})) {
	$self->{_errormsg} = "No rdf:RDF element found in document.";
	return undef;
    }

    my $metadata = $ref->{'rdf:RDF'};

    if (!defined($metadata->{'ns:Work'})) {
	$self->{_errormsg} = "No ns:Work element found in the rdf:RDF element";
	return undef;
    }

    $self->{_title}   = $metadata->{'ns:Work'}->{'dc:title'} || '';
    $self->{_author}  = $metadata->{'ns:Work'}->{'dc:rights'}->{'ns:Agent'}->{'dc:title'} || '';
    $self->{_license} = $metadata->{'ns:Work'}->{'ns:license'}->{'rdf:resource'} || '';

    return 1;
}

=head2 title

Gets or sets the title.

    $svgmeta->title('My Title');
    print $svgmeta->title();

=cut

sub title {
    my $self = shift;
    my $new_title = shift;
    if ($new_title) {
	$self->{_title} = $new_title;
    }
    return $self->{_title};
}


=head2 author

Gets or sets the author.

    $svgmeta->author('Bris Geek');
    print $svgmeta->author();

=cut

sub author {
    my $self = shift;
    my $new_author = shift;
    if ($new_author) {
	$self->{_author} = $new_author;
    }
    return $self->{_author};
}


=head2 license

Gets or sets the license.

    $svgmeta->license('Public Domain');
    print $svgmeta->license();

=cut

sub license {
    my $self = shift;
    my $new_license = shift;
    if ($new_license) {
	$self->{_license} = $new_license;
    }
    return $self->{_license};
}


=head2 keywords

Gets or sets an array of keywords

=cut

sub keywords {
    my $self = shift;
    if (@_) {
	$self->addKeyword(@_);
    }
    return undef unless defined($self->{_keywords});

    return keys %{$self->{_keywords}};
}


=head2 addKeywords

Adds one or more a new keywords

    $svgmeta->addKeyword('Fruit');
    $svgmeta->addKeyword('Fruit','Vegetable','Animal','Mineral');

=cut

sub addKeyword {
    my $self = shift;
    foreach my $new_keyword (@_) {
	$self->{_keywords}->{$new_keyword} = 1;
    }
}


=head2 removeKeyword

Removes a given keyword 

Return value:  The keyword removed.

=cut

sub removeKeyword {
    my $self = shift;
    my $keyword = shift || return;

    return delete $self->{_keywords}->{$keyword};
}


=head2 hasKeyword 

Returns true if the metadata includes the given keyword

=cut

sub hasKeyword {
    my $self = shift;
    my $keyword = shift || return 0;

    return 0 unless defined($self->{_keywords});

    return (defined($self->{_keywords}->{$keyword}));
}

=head2 compare

Compares this metadata to another metadata for equality.

Two SVG file metadata objects are considered equivalent if they
have exactly the same author, title, and license.  Keywords can
vary, as can the SVG file itself.

=cut

sub compare {
    my $self = shift;
    my $meta = shift;

    return ( $meta->author() eq $self->author() &&
	     $meta->title() eq $self->title() &&
	     $meta->license() eq $self->license()
	     );
}


=head2 to_text

Creates a plain text representation of the metadata, suitable for
debuggery, emails, etc.

Return value is a string containing the title, author, license, and
keywords, each value on a separate line.

=cut

sub to_text {
    my $self = shift;

    my $text = "";
    $text .= "Title:    " . $self->title() . "\n";
    $text .= "Author:   " . $self->author() . "\n";
    $text .= "License:  " . $self->license() . "\n";
    $text .= "Keywords: ";
    $text .= join("\n          ", $self->keywords());
    $text .= "\n";

    return $text;
}

# TODO:  to_rdf


1;
__END__

=head1 AUTHOR

Bryce Harrington <bryce@bryceharrington.com>

=head1 SEE ALSO

L<perl>, L<XML::Simple>

=cut
