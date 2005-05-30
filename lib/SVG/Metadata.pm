=head1 NAME

SVG::Metadata - Perl module to capture metadata info about an SVG file

=head1 SYNOPSIS

 use SVG::Metadata;

 my $svgmeta = new SVG::Metadata;

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

The SVG spec itself does not provide any particular mechanisms for
handling metadata, but instead relies on embedded, namespaced RDF
sections, as per XML philosophy.  Unfortunately, many SVG tools don't
support the concept of RDF metadata; indeed many don't support the idea
of embedded XML "islands" at all.  Some will even ignore and drop the
rdf data entirely when encountered.

The motivation for this module is twofold.  First, it provides a
mechanism for accessing this metadata from the SVG files.  Second, it
provides a means of validating SVG files to detect if they have the
metadata.

The motivation for this script is primarily for the Open Clip Art
Library (http://www.openclipart.org), as a way of filtering out
submissions that lack metadata from being included in the official
distributions.  A secondary motivation is to serve as a testing tool for
SVG editors like Inkscape (http://www.inkscape.org).

=head1 FUNCTIONS

=cut

package SVG::Metadata;

use 5.006;
use strict;
use warnings;
use XML::Twig;
use HTML::Entities;

# use Data::Dumper;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = ();

our $VERSION = '0.25';


use fields qw(
              _title
              _description
              _subject
              _publisher
              _publisher_url
              _creator
              _creator_url
              _owner
              _owner_url
              _license
              _license_date
              _keywords
              _language
              _about_url
              _date
              _ERRORMSG
              _strict_validation
              _retained_xml
              _retained_declaration
              );
use vars qw( %FIELDS $AUTOLOAD );


=head2 new()

Creates a new SVG::Metadata object.  Optionally, can pass in arguments
'title', 'author', 'license', etc..

 my $svgmeta = new SVG::Metadata;
 my $svgmeta = new SVG::Metadata(title=>'My title', author=>'Me', license=>'Public Domain');

=cut

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = bless [\%FIELDS], $class;

    while (my ($field, $value) = each %args) {
        $self->{"_$field"} = $value
            if (exists $FIELDS{"_$field"});
    }
    $self->{_creator}         ||= $args{author} || '';
    $self->{_language}        ||= 'en';
    $self->{_ERRORMSG}          = '';
    $self->{_strict_validation} = 0;

    return $self;
}

# This automatically generates all the accessor functions for %FIELDS
sub AUTOLOAD {
    my $self = shift;
    my $attr = $AUTOLOAD;
    $attr =~ s/.*:://;
    return unless $attr =~ /[^A-Z]/; # skip DESTROY and all-cap methods
    die "Invalid attribute method: ->$attr()\n" unless exists $FIELDS{"_$attr"};
    $self->{"_$attr"} = shift if @_;
    return $self->{"_$attr"};
}

=head2 author()

Alias for creator()

=cut
sub author {
    my $self = shift;
    return $self->creator(@_);
}

=head2 keywords_to_rdf()

Generates an rdf:Bag based on the data structure of keywords.
This can then be used to populate the subject section of the metadata.
I.e.:

    $svgobj->subject($svg->keywords_to_rdf());

See:
  http://www.w3.org/TR/rdf-schema/#ch_bag
  http://www.w3.org/TR/rdf-syntax-grammar/#section-Syntax-list-element
  http://dublincore.org/documents/2002/05/15/dcq-rdf-xml/#sec2

=cut
sub keywords_to_rdf {
    my $self = shift;
    
    my $text = '';
    foreach my $keyword ($self->keywords()) {
        $keyword = $self->esc_ents($keyword);
        $text .= qq(            <rdf:li>$keyword</rdf:li>\n);
    }

    if ($text ne '') {
        return qq(          <rdf:Bag>\n$text          </rdf:Bag>);
    } else {
        return '';
    }
}


=head2 errormsg()

Returns the last encountered error message.  Most of the error messages
are encountered during file parsing.

    print $svgmeta->errormsg();

=cut

sub errormsg {
    my $self = shift;
    return $self->{_ERRORMSG} || '';
}


=head2 parse($filename)

Extracts RDF metadata out of an existing SVG file.

    $svgmeta->parse($filename) || die "Error: " . $svgmeta->errormsg();

This routine looks for a field in the rdf:RDF section of the document
named 'ns:Work' and then attempts to load the following keys from it:
'dc:title', 'dc:rights'->'ns:Agent', and 'ns:license'.  If any are
missing, it

The $filename parameter can be a filename, or a text string containing
the XML to parse, or an open 'IO::Handle', or a URL.

Returns undef if there was a problem parsing the file, and sets an
error message appropriately.  The conditions under which it will return
undef are as follows:

   * No 'filename' parameter given.
   * Filename does not exist.
   * Document is not parseable SVG.
   * No rdf:RDF element was found in the document.
   * The rdf:RDF element did not have a ns:Work sub-element

Options:
   retain_xml  - keep the SVG around so that to_svg will work later.
       This may be called as follows:
           parse($filename, retain_xml => 1)

=cut

sub parse {
    my ($self, $filename, %optn) = @_;
    my $retaindecl;

    if (! defined($filename)) {
        $self->{_ERRORMSG} = "No filename or text argument defined for parsing";
        return undef;
    }

    my $twig = XML::Twig->new( map_xmlns => {
                                'http://web.resource.org/cc/' => "cc",
                                'http://www.w3.org/1999/02/22-rdf-syntax-ns#' => "rdf",
                                'http://purl.org/dc/elements/1.1/' => "dc",
                                'http://www.w3.org/2000/svg' => "svg",
                                },
                               pretty_print => 'indented',
                               comments     => 'keep',
                               pi           => 'keep',
                               keep_original_prefix => 1,
                        );

    if ($filename =~ m/\n.*\n/ || (ref $filename eq 'IO::Handle')) {
        # Hmm, if it has newlines, it is likely to be a string instead of a filename
        eval { $twig->parse($filename);
               if ($optn{retain_xml}) {
                 ($retaindecl) = $filename =~ /(.*?)(<svg|<!-- Created|$)/is; # an inexact science
               }};
    } elsif ($filename =~ /^http/ or $filename =~ /^ftp/) {
        eval { $twig->parseurl($filename); };
        # TODO: retain declaration here too, if $optn{retain_xml} is set.
    } elsif (! -e $filename) {
        $self->{_ERRORMSG} = "Filename '$filename' does not exist";
        return undef;
    } else {
        eval { $twig->parsefile($filename);
               if ($optn{retain_xml}) {
                 open SVGIN, '<', $filename;
                 local $/ = '<svg'; my $raw = <SVGIN>; close SVGIN;
                 ($retaindecl) = $raw =~ /(.*?)(<svg|<!-- Created|$)/is; # an inexact science
               }};
    }

    if ($@) {
        $self->{_ERRORMSG} = "Error parsing file:  $@";
        return undef;
    }

    my $ref;
    eval {
        $ref = $twig->simplify(); # forcecontent => 1);
    };
    return undef if ($@);

    if (! defined($ref)) {
        $self->{_ERRORMSG} = "XML::Twig did not return a valid XML object";
        return undef;
    }

    my $rdf;
    my $metadata = $ref->{'metadata'} || $ref->{'#default:metadata'} || $ref->{'svg:metadata'};
    if (defined $metadata) {
      $rdf = $metadata->{'rdf:RDF'} || $metadata->{RDF} || $metadata->{rdf};
    } else {
      $rdf = $ref->{'rdf:RDF'} || $ref->{RDF} || $ref->{rdf};
    }
    if (not defined $rdf) {
      $self->{_ERRORMSG} = "No 'RDF' element found in " .
        ((defined $metadata) ? "metadata element" : "document");
      return undef;
    } elsif ($self->{_strict_validation} and not defined $metadata) {
      $self->{_ERRORMSG} = "'RDF' element not contained in a <metadata></metadata> block";
      return undef;
    }

    my $work = $rdf->{'cc:Work'};
    if (! defined($work)) {
        $self->{_ERRORMSG} = "No 'Work' element found in the 'RDF' element";
        return undef;
    }

    my $getagent = sub {
      my ($elt) = shift; return unless ref $elt;
      my $a = $elt->{Agent};   return $a if ref $a;
      $a = $elt->{'cc:Agent'}; return $a if ref $a;
      return $elt;
    };
    my $getthingandurl = sub {
      my ($thing, $elt, $thingdefault, $urldefault) = @_;
      $thingdefault ||= ''; $urldefault ||= '';
      $self->{'_'.$thing} = $thingdefault;
      $self->{'_'.$thing.'_url'} = $urldefault;
      if (ref $elt) {
        my $agent = $getagent->($elt);
        if (ref $agent) {
          $self->{'_'.$thing} = _get_content($agent->{'dc:title'}
                                             || $agent->{'title'}) || $thingdefault;
          $self->{'_'.$thing.'_url'} = $agent->{att}->{'rdf:about'} || $urldefault;
        }}
    };

    $getthingandurl->('publisher', $work->{'dc:publisher'},
                      # With defaults:
                      'Open Clip Art Library', 'http://www.openclipart.org/');
    $getthingandurl->('creator', $work->{'dc:creator'});
    $getthingandurl->('owner', $work->{'dc:rights'});

    $self->{_title}         = _get_content($work->{'dc:title'}) || '';
    $self->{_description}   = _get_content($work->{'dc:description'}) || '';
    $self->{_subject}       = _get_content($work->{'dc:subject'}) || '';
    $self->{_publisher}     = _get_content($work->{'dc:publisher'}->{'dc:Agent'}->{'dc:title'}) || '';
    $self->{_publisher_url} = 'http://www.openclipart.org'; # TODO
    $self->{_creator}       = _get_content($work->{'dc:creator'}->{'cc:Agent'}->{'dc:title'}) || '';
    $self->{_creator_url}   = ''; # TODO
    $self->{_owner}         = _get_content($work->{'dc:rights'}->{'cc:Agent'}->{'dc:title'}) || '';
    $self->{_owner_url}     = ''; # TODO
    $self->{_license}       = _get_content($work->{'cc:license'}->{'rdf:resource'}) || '';
    # TODO: Does the above work?  Or should it be the following?
    #  || $work-}{'cc:license'}->{att}->{'rdf:resource'} || '';
    $self->{_license_date}  = _get_content($work->{'cc:license'}->{'dc:date'}) || '';
    $self->{_language}      = _get_content($work->{'dc:language'}) || 'en';
    $self->{_about_url}     = $work->{att}->{'rdf:about'} || '';
    $self->{_date}          = _get_content($work->{'dc:date'}) || '';

    $self->{_creator}       ||= $self->{_owner};
    $self->{_creator_url}   ||= $self->{_owner_url};
    $self->{_owner}         ||= $self->{_creator};
    $self->{_owner_url}     ||= $self->{_creator_url};
    $self->{_publisher}     ||= $self->{_owner};
    $self->{_publisher_url} ||= $self->{_owner_url};
    if ($optn{retain_xml}) {
      $self->{_retained_xml} = \$twig; # Keep the actual SVG around.  (to_svg is worthless without this.)
      $self->{_retained_declaration} = $retaindecl || ''; # and the XML declaration (and possibly also the doctype)
    }

    if ($self->{_subject} &&
        ref $self->{_subject} eq 'HASH' &&
        defined $self->{_subject}->{'rdf:Bag'} &&
        ref $self->{_subject}->{'rdf:Bag'} eq 'HASH' &&
        defined $self->{_subject}->{'rdf:Bag'}->{'rdf:li'}) {
      # How can the above condition EVER be true, when
      # $self->{_subject} comes from _get_content?

        my $subjectwords = _get_content($self->{_subject}->{'rdf:Bag'}->{'rdf:li'});
        if (ref $subjectwords) { # Multiple keywords
            $self->{_keywords} = { map { $_=>1 } @$subjectwords };
            # We *frequently* get "uninitialized value" warnings here, that may represent a problem.
        } else { # Only one keyword
            $self->{_keywords} = { $subjectwords => 1 } ;
        }
        $self->{_subject} = undef;
    } else {
        $self->{_keywords} = { unsorted => 1 };
    }

    return 1;
}

# XML::Twig::simplify has a bug where it only accepts "forcecontent", but
# the option to do that function is actually recognized as "force_content".
# As a result, we have to test to see if we're at a HASH node or a scalar.
sub _get_content {
    my ($content)=@_;

    if (UNIVERSAL::isa($content,"HASH")
        && exists($content->{'content'})) {
        return $content->{'content'};
    } else {
        return $content;
    }
}

=head2 title()

Gets or sets the title.

    $svgmeta->title('My Title');
    print $svgmeta->title();

=head2 description()

Gets or sets the description

=head2 subject()

Gets or sets the subject.  Note that the parse() routine pulls the
keywords out of the subject and places them in the keywords collection,
so subject() will normally return undef.  If you assign to subject() it
will override the internal keywords() mechanism.

=head2 publisher()

Gets or sets the publisher name.  E.g., 'Open Clip Art Library'

=head2 publisher_url()

Gets or sets the web URL for the publisher.  E.g., 'http://www.openclipart.org'

=head2 creator()

Gets or sets the creator.

    $svgmeta->creator('Bris Geek');
    print $svgmeta->creator();

=head2 creator_url()

Gets or sets the URL for the creator.

=head2 author()

Alias for creator() - does the same thing

    $svgmeta->author('Bris Geek');
    print $svgmeta->author();

=head2 owner()

Gets or sets the owner.

    $svgmeta->owner('Bris Geek');
    print $svgmeta->owner();

=head2 owner_url()

Gets or sets the owner URL for the item

=head2 license()

Gets or sets the license.

    $svgmeta->license('Public Domain');
    print $svgmeta->license();

=head2 license_date()

Gets or sets the date that the item was licensed

=head2 language()

Gets or sets the language for the metadata.  This should be in the
two-letter lettercodes, such as 'en', etc.

=head2 strict_validation()

Gets or sets the strict validation option.

=cut


=head2 keywords()

Gets or sets an array of keywords.  Keywords are a categorization
mechanism, and can be used, for example, to sort the files topically.

=cut

sub keywords {
    my $self = shift;
    if (@_) {
        $self->addKeyword(@_);
    }
    return undef unless defined($self->{_keywords});

    return keys %{$self->{_keywords}};
}


=head2 addKeyword($kw1 [, $kw2 ...])

Adds one or more a new keywords.  Note that the keywords are stored
internally as a set, so only one copy of a given keyword will be stored.

    $svgmeta->addKeyword('Fruits and Vegetables');
    $svgmeta->addKeyword('Fruit','Vegetable','Animal','Mineral');

=cut

sub addKeyword {
    my $self = shift;
    foreach my $new_keyword (@_) {
        $self->{_keywords}->{$new_keyword} = 1;
    }
}


=head2 removeKeyword($kw)

Removes a given keyword

    $svgmeta->removeKeyword('Fruits and Vegetables');

Return value:  The keyword removed.

=cut

sub removeKeyword {
    my $self = shift;
    my $keyword = shift || return;

    return delete $self->{_keywords}->{$keyword};
}


=head2 hasKeyword($kw)

Returns true if the metadata includes the given keyword

=cut

sub hasKeyword {
    my $self = shift;
    my $keyword = shift || return 0;

    return 0 unless defined($self->{_keywords});

    return (defined($self->{_keywords}->{$keyword}));
}

=head2 compare($meta2)

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


=head2 to_text()

Creates a plain text representation of the metadata, suitable for
debuggery, emails, etc.  Example output:

 Title:    SVG Road Signs
 Author:   John Cliff
 License:  http://web.resource.org/cc/PublicDomain
 Keywords: unsorted

Return value is a string containing the title, author, license, and
keywords, each value on a separate line.  The text always ends with
a newline character.

=cut

sub to_text {
    my $self = shift;

    my $text = '';
    $text .= 'Title:    ' . ($self->title()||'') . "\n";
    $text .= 'Author:   ' . ($self->author()||'') . "\n";
    $text .= 'License:  ' . ($self->license()||'') . "\n";
    $text .= 'Keywords: ';
    $text .= join("\n          ", $self->keywords());
    $text .= "\n";

    return $text;
}

=head2 esc_ents($text)

Escapes '<', '>', and '&' and single and double quote
characters to avoid causing rdf to become invalid.

=cut

sub esc_ents {
    my $self = shift;
    my $text = shift;
    return $text unless $text;

    return encode_entities($text, qq(<>&"'));
}

=head2 to_rdf()

Generates an RDF snippet to describe the item.  This includes the
author, title, license, etc.  The text always ends with a newline
character.

=cut

sub to_rdf {
    my $self = shift;

    my $about_url     = $self->esc_ents($self->about_url())       || '';
    my $title         = $self->esc_ents($self->title())           || '';
    my $creator       = $self->esc_ents($self->creator())         || '';
    my $creator_url   = $self->esc_ents($self->creator_url())     || '';
    my $owner         = $self->esc_ents($self->owner())           || '';
    my $owner_url     = $self->esc_ents($self->owner_url())       || '';
    my $date          = $self->esc_ents($self->date())            || '';
    my $license       = $self->esc_ents($self->license())         || '';
    my $license_date  = $self->esc_ents($self->license_date())    || '';
    my $description   = $self->esc_ents($self->description())     || '';
    my $subject       = $self->keywords_to_rdf() || '';
    my $publisher     = $self->esc_ents($self->publisher())       || '';
    my $publisher_url = $self->esc_ents($self->publisher_url())   || '';
    my $language      = $self->esc_ents($self->language())        || 'en';

    my $license_rdf   = '';
    if ($license eq 'Public Domain'
        or $license eq 'http://web.resource.org/cc/PublicDomain') {
        $license = "http://web.resource.org/cc/PublicDomain";
        $license_rdf = qq(
      <License rdf:about="$license">
         <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
         <permits rdf:resource="http://web.resource.org/cc/Distribution" />
         <permits rdf:resource="http://web.resource.org/cc/DerivativeWorks" />
      </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-nc-nd/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-nc-nd/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <prohibits rdf:resource="http://web.resource.org/cc/CommercialUse" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <permits rdf:resource="http://web.resource.org/cc/DerivativeWorks" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-nc/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-nc/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <prohibits rdf:resource="http://web.resource.org/cc/CommercialUse" />
          <permits rdf:resource="http://web.resource.org/cc/DerivativeWorks" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-nd/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-nd/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-nc-nd/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-nc-nd/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <prohibits rdf:resource="http://web.resource.org/cc/CommercialUse" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-nc-sa/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-nc-sa/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <prohibits rdf:resource="http://web.resource.org/cc/CommercialUse" />
          <permits rdf:resource="http://web.resource.org/cc/DerivativeWorks" />
          <requires rdf:resource="http://web.resource.org/cc/ShareAlike" />
     </License>
);
    } elsif ($license eq 'http://creativecommons.org/licenses/by-sa/2.0/') {
        $license_rdf = qq(
     <License rdf:about="http://creativecommons.org/licenses/by-sa/2.0/">
          <permits rdf:resource="http://web.resource.org/cc/Reproduction" />
          <permits rdf:resource="http://web.resource.org/cc/Distribution" />
          <requires rdf:resource="http://web.resource.org/cc/Notice" />
          <requires rdf:resource="http://web.resource.org/cc/Attribution" />
          <permits rdf:resource="http://web.resource.org/cc/DerivativeWorks" />
          <requires rdf:resource="http://web.resource.org/cc/ShareAlike" />
     </License>
);
    }

    my $pub_data = ($publisher_url ? ' rdf:about="'.$publisher_url.'"' : '');
    my $creator_data = ($creator_url ? ' rdf:about="'.$creator_url.'"' : '');
    my $owner_data = ($owner_url ? ' rdf:about="'.$owner_url.'"' : '');
    return qq(
  <metadata>
    <rdf:RDF 
     xmlns="http://web.resource.org/cc/"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <Work rdf:about="$about_url">
        <dc:title>$title</dc:title>
        <dc:description>$description</dc:description>
        <dc:subject>
$subject
        </dc:subject>
        <dc:publisher>
           <Agent$pub_data>
             <dc:title>$publisher</dc:title>
           </Agent>
         </dc:publisher>
         <dc:creator>
           <Agent$creator_data>
             <dc:title>$creator</dc:title>
           </Agent>
        </dc:creator>
         <dc:rights>
           <Agent$owner_data>
             <dc:title>$owner</dc:title>
           </Agent>
        </dc:rights>
        <dc:date>$date</dc:date>
        <dc:format>image/svg+xml</dc:format>
        <dc:type rdf:resource="http://purl.org/dc/dcmitype/StillImage" />
        <license rdf:resource="$license" />
        <dc:language>$language</dc:language>
      </Work>
$license_rdf
    </rdf:RDF>
  </metadata>
);

}

=head2 to_svg()

Returns the SVG with the updated metadata embedded.  This can only be
done if parse() was called with the retain_xml option.  Note that the
code's layout can change a little, especially in terms of whitespace,
but the semantics SHOULD be the same, except for the updated metadata.

=cut

sub to_svg {
  my ($self) = shift;
  if (not $self->{_retained_xml}) {
    $self->{_ERRORMSG} = "Cannot do to_svg because the XML was not retained.  Pass a true value for the retain_xml option to parse to retain the XML, and check the return value of parse to make sure it succeeded.";
    return undef;
  }

  my $xml = ${$self->{_retained_xml}}->root();
  my $metadata = XML::Twig->new(
                                map_xmlns => {
                                              'http://web.resource.org/cc/' => "cc",
                                              'http://www.w3.org/1999/02/22-rdf-syntax-ns#' => "rdf",
                                              'http://purl.org/dc/elements/1.1/' => "dc",
                                             },
                                pretty_print => 'indented',
                               );
  $metadata->parse($self->to_rdf());
#  delete $xml->{'#default:metadata'} if ref $xml->{'#default:metadata'};
#  delete $xml->{'rdf:RDF'}           if ref $xml->{'rdf:RDF'};
  $xml->{'metadata'} = $metadata;
  return $self->{_retained_declaration} . $xml->root()->sprint();
}

1;
__END__

=head1 PREREQUISITES

C<XML::Twig>

=head1 AUTHOR

Bryce Harrington <bryce@bryceharrington.org>

=head1 COPYRIGHT
                                                                                
Copyright (C) 2004 Bryce Harrington.
All Rights Reserved.
 
This script is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.
 
=head1 SEE ALSO

L<perl>, L<XML::Twig>

=cut
