package Text::Distill;

use 5.006001;
use strict;
use warnings;
use Digest::JHash;
use XML::LibXML;
use XML::LibXSLT;
use Encode::Detect;
use Text::Extract::Word;
use Archive::Zip;
use Carp;
use HTML::TreeBuilder;
use OLE::Storage_Lite;
use Text::Unidecode v1.27;
use Unicode::Normalize v1.25;
use Encode::Detect;
use Encode;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

our (@ISA, @EXPORT_OK);
BEGIN {
  require Exporter;
  @ISA = qw(Exporter);
  @EXPORT_OK = qw(
		Distill
		LikeSoundex
		TextToGems
		DetectBookFormat
		ExtractSingleZipFile
		CheckIfTXT
		CheckIfFB2
		CheckIfDocx
		CheckIfEPub
		CheckIfDoc
		CheckIfTXTZip
		CheckIfFB2Zip
		CheckIfDocxZip
		CheckIfEPubZip
		CheckIfDocZip
		ExtractTextFromEPUBFile
		ExtractTextFromDOCXFile
		ExtractTextFromDocFile
		ExtractTextFromTXTFile
		ExtractTextFromFB2File
		GetFB2GemsFromFile
	);  # symbols to export on request
}

my $XSL_FB2_2_String = q{
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0">
  <xsl:strip-space elements="*"/>
  <xsl:output method="text" encoding="UTF-8"/>
  <xsl:variable name="linebr"><xsl:text>&#010;</xsl:text></xsl:variable>
  <xsl:template match="/fb:FictionBook">
    <xsl:apply-templates select="fb:body"/>
  </xsl:template>
  <xsl:template match="fb:section|
                      fb:title|
                      fb:subtitle|
                      fb:p|
                      fb:epigraph|
                      fb:cite|
                      fb:text-author|
                      fb:date|
                      fb:poem|
                      fb:stanza|
                      fb:v|
                      fb:image[parent::fb:body]|
                      fb:code">
    <xsl:apply-templates/>
    <xsl:value-of select="$linebr"/>
  </xsl:template>
</xsl:stylesheet>};

my $XSL_Docx_2_Txt = q{
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0"
	xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
	<xsl:output method="text" />
	<xsl:template match="/">
		<xsl:apply-templates select="//w:body" />
	</xsl:template>
	<xsl:template match="w:body">
		<xsl:apply-templates />
	</xsl:template>
	<xsl:template match="w:p">
		<xsl:if test="w:pPr/w:spacing/@w:after=0"><xsl:text>&#13;&#10;</xsl:text></xsl:if>
		<xsl:apply-templates/><xsl:if test="position()!=last()"><xsl:text>&#13;&#10;</xsl:text></xsl:if>
	</xsl:template>
	<xsl:template match="w:r">
		<xsl:for-each select="w:t">
			<xsl:value-of select="." />
		</xsl:for-each>
	</xsl:template>
</xsl:stylesheet>
};

# Гласные и прочие буквы \w, которые нас, тем не менее, не волнуют
my $SoundexExpendable = qr/уеёыаоэяиюьъaehiouwy/i;

# Статистически подобранные "буквосочетания", бьющие тексты на на куски по ~20к
# отбиралось по языкам: ru	en	it	de	fr	es	pl	be	cs	sp	lv
# в теории этот набор должен более-менее ровно нарезать любой текст на куски по ~2к
my @SplitChars = qw(3856 6542 4562 6383 4136 2856 4585 5512
	2483 5426 2654 3286 5856 4245 4135 4515 4534 8312 5822 5316 1255 8316 5842);

my $MinPartSize = 150;

my @DetectionOrder = qw /epub.zip epub docx.zip docx doc.zip doc fb2.zip fb2 txt.zip txt/;

my $Detectors = {
	'fb2.zip'  => \&CheckIfFB2Zip,
	'fb2'      => \&CheckIfFB2,
	'doc.zip'  => \&CheckIfDocZip,
	'doc'      => \&CheckIfDoc,
	'docx.zip' => \&CheckIfDocxZip,
	'docx'     => \&CheckIfDocx,
	'epub.zip' => \&CheckIfEPubZip,
	'epub'     => \&CheckIfEPub,
	'txt.zip'  => \&CheckIfTXTZip,
	'txt'      => \&CheckIfTXT
};

our $Extractors = {
	'fb2'  => \&ExtractTextFromFB2File,
	'txt'  => \&ExtractTextFromTXTFile,
	'doc'  => \&ExtractTextFromDocFile,
	'docx' => \&ExtractTextFromDOCXFile,
	'epub' => \&ExtractTextFromEPUBFile,
};

our $rxFormats = join '|', keys %$Detectors;


=head1 NAME

Text::Distill - Quick texts compare, plagiarism and common parts detection

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

  use Text::Distill qw(Distill);
	Distill($text);

	or

  use Text::Distill;
	Text::Distill::Distill(Text::Distill::ExtractTextFromFB2File($fb2_file_path));

=cut

# EXTRACT BLOCK

=head1 Service functions

=head2 ExtractTextFromFB2File($FilePath)

Function receives a path to the fb2-file and returns all significant text from the file as a string

=cut

sub ExtractTextFromFB2File {
	my $FN = shift;

  my $parser = XML::LibXML->new();
  my $xslt = XML::LibXSLT->new();
  my $source = $parser->parse_file($FN);
  my $style_doc = $parser->load_xml(string => $XSL_FB2_2_String);
  my $stylesheet = $xslt->parse_stylesheet($style_doc);
  my $results = $stylesheet->transform($source);
  my $Out = $stylesheet->output_string($results);

  return $Out;
}

=head2 ExtractTextFromTXTFile($FilePath)

Function receives a path to the text-file and returns all significant text from the file as a string

=cut

sub ExtractTextFromTXTFile {
	my $FN = shift;
	open(TEXTFILE, "<$FN");
	my $String = join('', <TEXTFILE>);
	close TEXTFILE;

	require Encode::Detect;
	return Encode::decode('Detect', $String);
}


=head2 ExtractTextFromDocFile($FilePath)

Function receives a path to the doc-file and returns all significant text from the file as a string

=cut

sub ExtractTextFromDocFile {
	my $FilePath = shift;

	my $File = Text::Extract::Word->new($FilePath);
	my $Text = $File->get_text();

	return $Text;
}

=head2 ExtractTextFromDOCXFile($FilePath)

Function receives a path to the docx-file and returns all significant text from the file as a string

=cut

sub ExtractTextFromDOCXFile {
	my $FN = shift;

	my $Result;
	my $arch = Archive::Zip->new();
	if ( $arch->read($FN) == AZ_OK ) {
		if (my $DocumentMember = $arch->memberNamed( 'word/document.xml' )) {
			my $XMLDocument = $DocumentMember->contents();

			my $xml  = XML::LibXML->new();
			my $xslt = XML::LibXSLT->new();

			my $Document;
			eval { $Document = $xml->parse_string($XMLDocument); };
			if ($@) {
				$! = 11;
				Carp::confess("[libxml2 error ". $@->code() ."] ". $@->message());
			}

			my $StyleDoc   = $xml->load_xml(string => $XSL_Docx_2_Txt);

			my $StyleSheet = $xslt->parse_stylesheet($StyleDoc);

			my $TransformResult = $StyleSheet->transform($Document);

			$Result = $StyleSheet->output_string($TransformResult);
		}
	} else {
		Carp::confess("[Archive::Zip error] $!");
	}

	return $Result;
}

=head2 ExtractTextFromEPUBFile($FilePath)

Function receives a path to the epub-file and returns all significant text from the file as a string

=cut

sub ExtractTextFromEPUBFile {
	my $FN = shift;

	my $Result;
	my $arch = Archive::Zip->new();
	if ( $arch->read($FN) == AZ_OK ) {
		my $requiredMember = 'META-INF/container.xml';
		if (my $ContainerMember = $arch->memberNamed( $requiredMember )) {
			my $XMLContainer = $ContainerMember->contents();

			my $xml = XML::LibXML->new;
			my $xpc = XML::LibXML::XPathContext->new();
			$xpc->registerNs('opf', 'urn:oasis:names:tc:opendocument:xmlns:container');

			my $Container;
			eval { $Container = $xml->parse_string($XMLContainer); };
			if ($@) {
				$! = 11;
				Carp::confess("[libxml2 error ". $@->code() ."] ". $@->message());
			}

			my ($ContainerNode) = $xpc->findnodes('//opf:container/opf:rootfiles/opf:rootfile', $Container);
			my $ContentPath = $ContainerNode->getAttributeNode('full-path')->string_value;
			if (my $ContentMember = $arch->memberNamed( $ContentPath )) {
				my $XMLContent = $ContentMember->contents();

				$xpc->unregisterNs('opf');
				$xpc->registerNs('opf', 'http://www.idpf.org/2007/opf');

				my $Content;
				eval { $Content = $xml->parse_string($XMLContent); };
				if ($@) {
					$! = 11;
					Carp::confess("[libxml2 error ". $@->code() ."] ". $@->message());
				}
				my @ContentNodes = $xpc->findnodes('//opf:package/opf:manifest/opf:item[
						@media-type="application/xhtml+xml"
					and
						starts-with(@id, "content")
					]',
					$Content
				);
				my $HTMLTree = HTML::TreeBuilder->new();
				foreach my $ContentNode (@ContentNodes) {
					my $HTMLContentPath = $ContentNode->getAttributeNode('href')->string_value;

					if (my $HTMLContentMember = $arch->memberNamed( $HTMLContentPath )) {
						my $HTMLContent = $HTMLContentMember->contents();

						$HTMLTree->parse_content($HTMLContent);
					} else {
						Carp::confess("[Archive::Zip error] $HTMLContentPath not found in ePub ZIP container");
					}
				}
				$Result = $HTMLTree->as_text;
			} else {
				Carp::confess("[Archive::Zip error] $ContentPath not found in ePub ZIP container");
			}
		} else {
			Carp::confess("[Archive::Zip error] $requiredMember not found in ePub ZIP container");
		}
	} else {
		Carp::confess("[Archive::Zip error] $!");
	}

	return $Result;
}


sub ExtractSingleZipFile {
	my $FN = shift;
	my $Ext = shift;
	my $Zip = Archive::Zip->new();

	return unless ( $Zip->read( $FN ) == Archive::Zip::AZ_OK );

	my @Files = $Zip->members();
	return unless (scalar @Files == 1 && $Files[0]->{fileName} =~ /(\.$Ext)$/);

	my $OutFile = $XPortal::Settings::TMPPath . '/check_' . $$ . '_' . $Files[0]->{fileName};

	return  $Zip->extractMember( $Files[0], $OutFile ) == Archive::Zip::AZ_OK ? $OutFile : undef;
}

=head2 DetectBookFormat($FilePath, ($Format))

Function detected format of e-book and returns format of file (string). You
may suggest the format to start with too speed up the process a bit

$Format can be 'fb2.zip',	'fb2', 'doc.zip', 'doc', 'docx.zip',
'docx', 'epub.zip', 'epub', 'txt.zip', 'txt'

=cut

sub DetectBookFormat {
	my $File = shift;
	my $Format = shift =~/($rxFormats)/ ? $1 : undef;

	#$Format первым пойдет
	my @Formats = ($Format || (),  grep{ $_ ne $Format } @DetectionOrder);

	foreach( @Formats ) {
		return $_ if $Detectors->{$_}->($File);
	}
	return;
}

=head1 Distilling gems from text

=head2 TextToGems($UTF8TextString)

What you really need to know is that TextToGem's from exactly the same texts are
eqlal, texts with small changes have similar "gems" as well. And
if two texts have 3+ common gems - they share some text parts, for sure. This is somewhat
close to "Edit distance", but fast on calc and indexable. So you can effectively
search for citings or plagiarism. Choosen split-method makes average detection
segment about 2k of text (1-2 paper pages), so this package will not normally detect
a single equal paragraph. If you need more precise match extended @SplitChars with some
sequences from SeqNumStats.xlsx on GitHub, I guiess you can get down to parts of
about 300 chars without significant losses (don't forget to lower $MinPartSize as well).

Function transforming the text (valid UTF8 expected) into an
array of 32-bit hash-summs (Jenkins's Hash). Text is at first flattened the hard
way (something like soundex), than splitted into fragments by statistically
choosen sequences. First and the last fragments are rejected, short fragments are
rejected as well, from remaining strings we calc hashes and
returns reference to them in the array.

Should return one 32-bit jHash from 2kb of source text (may vary from text to
text thou).

=cut

our $SplitRegexp = join ('|',@SplitChars);

$SplitRegexp = qr/$SplitRegexp/o;

# Кластеризация согласных - глухие к глухим, звонкие к звонким
#my %SoundexClusters = (
#	'1' => 'бпфвbfpv',
#	'2' => 'сцзкгхcgjkqsxz',
#	'3' => 'тдdt',
#	'4' => 'лйl',
#	'5' => 'мнmn',
#	'6' => 'рr',
#	'7' => 'жшщч'
#);
#my $SoundexTranslatorFrom;
#my $SoundexTranslatorTo;
#for (keys %SoundexClusters){
#	$SoundexTranslatorFrom .= $SoundexClusters{$_};
#	$SoundexTranslatorTo .= $_ x length($SoundexClusters{$_});
#}

sub TextToGems{
	my $SrcText = Distill(shift) || return;

	my @DistilledParts = split /$SplitRegexp/, $SrcText;

	# Началу и концу верить всё равно нельзя
	shift @DistilledParts;
	pop @DistilledParts;
	my @Hashes;
	my %SeingHashes;
	for (@DistilledParts){
		# Если отрывок текста короткий - мы его проигнорируем
		next if length($_)< $MinPartSize;

		# Используется Хеш-функция Дженкинса, хорошо распределенный хэш на 32 бита
		my $Hash = Digest::JHash::jhash($_);

		# Если один хэш дважды - нам второго не нужно
		push @Hashes, $Hash unless $SeingHashes{$Hash}++;
	}
	return \@Hashes;
}

# Безжалостная мужланская функция, но в нашем случае чем топорней - тем лучше
sub LikeSoundex {
	my $S = shift;

	# Гласные долой, в них вечно очепятки
	$S =~ s/[$SoundexExpendable]+//gi;

	# Заменяем согласные на их кластер
	#	eval "\$String =~ tr/$SoundexTranslatorFrom/$SoundexTranslatorTo/";
	$S =~ tr/рrлйlбпфвbfpvтдdtжшщчсцзкгхcgjkqsxzмнmn/664441111111133337777222222222222225555/;

	return $S;
}

=pod

=head2 Distill($UTF8TextString)

Transforming the text (valid UTF8 expected) into a sequence of 1-8 numbers
(string as well). Internally used by TextToGems, but you may use it's output
with standart "edit distance" algorithm. As this string is shorter you math will
go much faster.

At the end works somewhat close to 'soundex' with addition of some basic rules
for cyrillic chars, pre- and post-cleanup and utf normalization. Drops strange
sequences, drops short words as well (how are you going to make you plagiarism
without copying the long words, huh?)

=cut

sub Distill {
	my $String = shift;

	#Нормализация юникода
	$String = Unicode::Normalize::NFKC($String);

	#Переводим в lowercase
	$String = lc($String);

  #Конструкции вида слово.слово разбиваем пробелом
  $String =~ s/(\w[.,;:&?!*#%+\^\\\/])(\w)/$1 $2/g;

	# Понятные нам знаки причешем до упрощенного вида
	$String =~ tr/ЁёÉÓÁéóáĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĲĳĴĵĶķĸĹĺĻļĽľĿŀŁłŃńŅņŇňŉŊŋŌōŎŏŐőŒœŔŕŖŗŘřŚŜśŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſƒǺǻǼǽǾǿђѓєѕіїјљњћќўџҐґẀẁẂẃẄẅỲỳ/ЕеЕОАеоаAaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiiiJjKkкLlLlLlLlLlNnNnNnnNnOoOoOoCCRrRrRrSSssSsŠšTtTtTtUuUuUuUuUuUuWwYyYZzZzZzffAaAaOohгеsiijлнhкyuГгWWWWWWYy/;

	# в словах вида папа-ёж глотаем тире (и любой другой мусор)
	$String =~ s/(\w)([^\w\s]|_)+(\w)/$1$3/;

	# Короткие слова долой
	# Короткие русские слова долой (у нас в русском и 6 знаков короткое)
	$String =~ s/(\s|^)(\S{1,5}|[а-я]{6})\b/$1/g;

	# странные конструкции вида -=[мусорсрач]=- долой, ими легко засорить
	# текст - глаз заигнорит, а робот будет думать что текст о другом. Не будем
	# облегчать атакующим жизнь
	$String =~ s/(^|\s)[^\w\s]+\s?\w+\s*[^\w\s]+($|\s)/$1$2/g;

	$String =~ s/([^\w\s]|_)+//g;

	return '' if $String !~ /\w/;

	$String = LikeSoundex($String);

	# Все буквы, которых мы не знаем - перегоняем в транслит, говорят оно даж китайщину жрёт
	if ($String =~ /[^\d\s]/){
		$String = lc Text::Unidecode::unidecode($String);

		# Уборка - II, уже для транслитерированной строки
		$String = LikeSoundex($String);
	}

	# Убираем повторы
	$String =~ s/(\w)\1+/$1/gi;

	# слишком длинные слова подрежем (оставив меточку 8, что поработали ножницами)
	$String =~ s/(\s|^)(\S{4})\S+\b/${2}8/g;

	# Всё, мы закончили, теперь пробелы убираем, да и до кучи что там еще было
	$String =~ s/\D//g;

	return $String;
}

# CHECK BLOCK

=head1 Internal Functions:

Receives a path to the file and checks whether this of

CheckIfDocZip() - MS Word .doc in zip-archive

CheckIfEPubZip() - Electronic Publication .epub in zip-archive

CheckIfDocxZip - MS Word 2007 .docx  in zip-archive

CheckIfFB2Zip() - FictionBook2  (FB2)  in zip-archive

CheckIfTXT2Zip() - text-file in zip-archive

CheckIfEPub() - Electronic Publication .epub

CheckIfDocx() - MS Word 2007 .docx

CheckIfDoc() - MS Word .doc

CheckIfFB2() - FictionBook2 (FB2)

CheckIfTXT() - text-file

=cut

sub CheckIfDocZip {
	my $FN = shift;
	my $IntFile = ExtractSingleZipFile( $FN, 'doc' ) || return;
	my $Result = CheckIfDoc( $IntFile );
	unlink $IntFile;
	return $Result;
}

sub CheckIfEPubZip {
	my $FN = shift;
	my $IntFile = ExtractSingleZipFile( $FN, 'epub' ) || return;
	my $Result = CheckIfEPub( $IntFile );
	unlink $IntFile;
	return $Result;
}

sub CheckIfDocxZip {
	my $FN = shift;
	my $IntFile = ExtractSingleZipFile( $FN, 'docx' ) || return;
	my $Result = CheckIfDocx( $IntFile );
	unlink $IntFile;
	return $Result;
}

sub CheckIfFB2Zip {
	my $FN = shift;
	my $IntFile = ExtractSingleZipFile( $FN, 'fb2' ) || return;
	my $Result = CheckIfFB2( $IntFile );
	unlink $IntFile;
	return $Result;
}

sub CheckIfTXTZip {
	my $FN = shift;
	my $IntFile = ExtractSingleZipFile( $FN, 'txt' ) || return;
	my $Result = CheckIfTXT( $IntFile );
	unlink $IntFile;
	return $Result;
}

sub CheckIfEPub {
	my $FN = shift;

	my $arch = Archive::Zip->new();

	if ( $arch->read($FN) == AZ_OK ) {
		if (my $ContainerMember = $arch->memberNamed( 'META-INF/container.xml' )) {
			my $XMLContainer = $ContainerMember->contents();

			my $xml = XML::LibXML->new;
			my $xpc = XML::LibXML::XPathContext->new();
			$xpc->registerNs('opf', 'urn:oasis:names:tc:opendocument:xmlns:container');

			my $Container;
			eval { $Container = $xml->parse_string($XMLContainer); };
			return if ($@ || !$Container);

			my ($ContainerNode) = $xpc->findnodes('//opf:container/opf:rootfiles/opf:rootfile', $Container);
			my $ContentPath = $ContainerNode->getAttributeNode('full-path')->string_value;

			if (my $ContentMember = $arch->memberNamed( $ContentPath )) {
				my $XMLContent = $ContentMember->contents();

				$xpc->unregisterNs('opf');
				$xpc->registerNs('opf', 'http://www.idpf.org/2007/opf');

				my $Content;
				eval { $Content = $xml->parse_string($XMLContent); };
				return if ($@ || !$Content);

				my @ContentNodes = $xpc->findnodes('//opf:package/opf:manifest/opf:item[
						@media-type="application/xhtml+xml"
					and
						starts-with(@id, "content")
					and
						"content" = translate(@id, "0123456789", "")
					]',
					$Content
				);

				my $existedContentMembers = 0;
				foreach my $ContentNode (@ContentNodes) {
					my $HTMLContentPath = $ContentNode->getAttributeNode('href')->string_value;
					$existedContentMembers++ if $arch->memberNamed( $HTMLContentPath );
				}

				return 1 if (@ContentNodes == $existedContentMembers);
			}
		}
	}
	return;
}

sub CheckIfDocx {
	my $FN = shift;

	my $arch = Archive::Zip->new();

	return unless ( $arch->read($FN) == AZ_OK );
	return 1 if $arch->memberNamed( 'word/document.xml' );
}

sub CheckIfDoc {
	my $FilePath = shift;

	my $ofs = OLE::Storage_Lite->new($FilePath);
	my $name = Encode::encode("UCS-2LE", "WordDocument");
	return $ofs->getPpsSearch([$name], 1, 1);
}

sub CheckIfFB2 {
	my $FN = shift;
	my $parser = XML::LibXML->new;
	my $XML = eval{ $parser->parse_file($FN) };
	return if( $@ || !$XML );
	return 1;
}

sub CheckIfTXT {
	my $FN = shift;
	my $String = ExtractTextFromTXTFile($FN);
	return $String =! /[\x00-\x08\x0B\x0C\x0E-\x1F]/g; #всякие непечатные Control characters говорят, что у нас тут бинарник
}


=head1 AUTHOR

Litres.ru, C<< <gu at litres.ru> >>
Get the latest code from L<https://github.com/Litres/TextDistill>

=head1 BUGS

Please report any bugs or feature requests to L<https://github.com/Litres/TextDistill/issues>.



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Text::Distill


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Text-Distill>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Text-Distill>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Text-Distill>

=item * Search CPAN

L<http://search.cpan.org/dist/Text-Distill/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2016 Litres.ru.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of Text::Distill