#!/usr/bin/perl

use warnings;
use strict;

use constant GOOG_USER => '';
use constant GOOG_PASS => '';

use constant BATIK_PATH => '/home/halcyon/www/src/quota/batik';
use constant TMP_PATH => '/tmp';
use constant STYLE_FILE => '/home/halcyon/www/src/quota/quota.css';
use constant STYLE_FILE_URL => 'http://halcy.de/src/quota/quota.css';

use Date::Parse;
use Date::Format;
use LWP::Simple;
use LWP::Simple::Cookies(
	autosave => 1,
	file => ".lwp_cookies.dat"
);
use LWP::UserAgent;
use SVG::TT::Graph;
use SVG::TT::Graph::TimeSeries;
use SVG::SVG2zinc;
use CGI qw(param);

# Grab the trends for a thing off google trends.
sub fetch_trends( $ ) {
	my $term = shift();
	my %trends = ();

	# Log in
	my $login =
		'https://www.google.com/accounts/ServiceLoginBoxAuth?' .
		'Email=' . GOOG_USER .
		'&Passwd=' . GOOG_PASS;
	get( $login );
	
	my $trends_url =
		'http://www.google.com/trends/viz?q=' .
		$term .
		'&date=all&geo=all&graph=all_csv&sa=N';
	my $trends_csv = get( $trends_url );
	my @trends_lines = split( /\n/, $trends_csv );
	my $len = @trends_lines - 1;
	foreach my $line ( @trends_lines[5..$len] ) {
		if( $line =~ /^\s*$/ ) {
			last;
		}
		else {
			$line =~ /^([^,]*),([^,]*),>?([^,]*)%$/;
			my $date = str2time( $1 );
			if( $2 > 0 ) {
				$trends{$date} = [ $2, $3 ];
			}
		}
	}
	return( %trends );
}

# Grab stock quotes for a symbol in a date range from yahoo.
sub fetch_financial( $$$ ) {
	my $symbol = shift();
	my $date_start = shift();
	my $date_end = shift();
	my %quotes = ();
	
	# Prepare dates
	my @start = localtime( $date_start );
	my @end = localtime( $date_end );
	
	# Grab finance data from Yahoo
	my $quotes_url =
		'http://ichart.finance.yahoo.com/table.csv?s=' . $symbol .
		'&a=' . (strftime( '%L', @start) - 1) .
		'&b=' . strftime( '%e', @start ) .
		'&c=' . strftime( '%Y', @start ) .
		'&d=' . (strftime( '%L', @end) - 1) .
		'&e=' . strftime( '%e', @end ) .
		'&f=' . strftime( '%Y', @end ) .
		'&g=d&&ignore=.csv';
	my $quotes_csv = get( $quotes_url );
	my @quotes_lines = split( /\n/, $quotes_csv );
	my $len = @quotes_lines - 1;
	foreach my $line ( @quotes_lines[1..$len] ) {
		$line =~ /^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),.*$/x;
		my $date = str2time( $1 );
		$quotes{$date} = [ $2, $3, $4, $5 ];
	}
	return( %quotes );
}

# Get the biggest value from an array.
sub max( @ ) {
	my $cur_max = 0;
	foreach( @_ ) {
		if( $_ > $cur_max ) {
			$cur_max = $_;
		}
	}
	return( $cur_max );
}

# Set up parameters
my $mode = param( 'type' ) || 'svg';
my $width = param( 'w' ) || 900;
my $height = param( 'h' ) || 400;
my $httpstyle = param( 'style' ) || STYLE_FILE_URL;
my $from_date = param( 'from' ) || time() - 2 * 365 * 24 * 60 * 60;
my $to_date = param( 'to' ) || time();
my $phrase = param( 'phrase' ) || 'Google';
my $symbol = param( 'symbol' ) || 'GOOG';

# Grab a bunch of info, and refumble it.
my %trends = fetch_trends( $phrase );
my @trends_points = sort( keys( %trends ) );
my %finance = fetch_financial(
	$symbol,
	$from_date != 0 ? $from_date : @trends_points[0],
	$to_date
);
my @finance_points = sort( keys( %finance ) );
@trends_points = grep{ $_ >= $from_date && $_ <= $to_date } @trends_points;
@finance_points = grep{ $_ >= $from_date && $_ <= $to_date } @finance_points;
my $max_trends = max( map{ @{$trends{$_}}[0] } @trends_points );
my $max_stock = max( map{ @{$finance{$_}}[0] } @finance_points );
my @trends_to_plot = map{
	scalar( localtime( $_ ) ),
	(@{$trends{$_}}[0] / $max_trends) * $max_stock
} @trends_points;
my @finance_to_plot = map{
	scalar( localtime( $_ ) ),
	@{$finance{$_}}[0]
} @finance_points;

# Graph it.
my $graph = SVG::TT::Graph::TimeSeries->new( {
	'width' => $width,
	'height' => $height,
	'show_x_labels' => 0,
	'show_data_points' => 0,
	'show_data_values' => 0,
	'show_y_labels' => 1,
	'style_sheet' => lc( $mode ) eq 'png' ? STYLE_FILE : $httpstyle,
	'show_y_title' => 1,
	'y_title' => '',
	'show_x_title' => 1,
	'x_title' => '',
} );
$graph->add_data( {
	'data' => \@trends_to_plot,
	'title' => 'Search trend',
} );
$graph->add_data( {
	'data' => \@finance_to_plot,
	'title' => 'Stock',
} );

# Output the graph
if( lc( $mode ) eq 'png' ) {
	# Make a pretty PNG file from the graph
	my $file_name = time() . rand(10000000);
	open( my $OUT, '>', TMP_PATH . "/$file_name.svg" );
	$OUT->print( $graph->burn() );
	system(
		'java -jar ' . BATIK_PATH . '/batik-rasterizer.jar ' .
		TMP_PATH . "/$file_name.svg " .
		'1> /dev/null'
	);
	close( $OUT );

	# Pipe it out
	STDOUT->print( "Content-type:image/png\n\n" );
	open( my $IN, '<', TMP_PATH . "/$file_name.png" );
	binmode( $IN );
	binmode( STDOUT );
	my $data;
	read( $IN, $data, -s (TMP_PATH . "/$file_name.png") );
	STDOUT->print( $data );
	close $IN;

	# Clean up
	unlink( TMP_PATH . "/$file_name.svg" );
	unlink( TMP_PATH . "/$file_name.png" );
}
else {
	# Just give me SVG!
	STDOUT->print( "Content-Type: image/svg+xml\n\n" );
	STDOUT->print( $graph->burn() );
}
