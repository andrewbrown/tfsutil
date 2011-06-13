@rem = '--*-Perl-*--
@rem
@rem Batch wrapper adapted from pl2bat output
@rem 
@echo off
if "%OS%" == "Windows_NT" goto WinNT
"perl.exe" -x -S "%0" %1 %2 %3 %4 %5 %6 %7 %8 %9
goto endofperl
:WinNT
"perl.exe" -x -S %0 %*
if NOT "%COMSPEC%" == "%SystemRoot%\system32\cmd.exe" goto endofperl
if %errorlevel% == 9009 echo You do not have Perl in your PATH.
if errorlevel 1 goto script_failed_so_exit_with_non_zero_val 2>nul
goto endofperl
@rem ';
#!perl
#line 17

# ----------------------------------------------------------------------
#
# This software is in the public domain, furnished "as is", without
# technical support, and with no warranty, express or implied, as to its
# usefulness for any purpose.
#
# tfpurge.pl
#
# Identifies large files in TFS version control and provides a list of
# tf.exe commands that can be used to destroy older revisions of those
# files to conserve space.
#
# Assumes tf.exe is in PATH; tested with TFS 2008 and 
# Strawberry Perl 5.12.3.
#
# EXAMPLE USAGE: 
# tfspurge.pl --server tfs.mydomain.local --root $/MyProject --threshold 16777216
#
# Note that --threshold and --keepcount are optional (defaults are 
# 16MB and 5, respectively); the other arguments are required.
#
# ----------------------------------------------------------------------
#
# AUTHOR: Andrew Brown ( abrown at roughfalls d0t com )
#
# Inspired by: 
# http://teamfoundation.blogspot.com/2009/03/tfs-administrator-chores-dealing-with.html
#
# ----------------------------------------------------------------------

#
# Potential improvements:
#
# * Right now, 'tf history' is run for each large file identified.  Running a
#   single history command in 'at mode' could yield much better performance.
#
# * Actually support running these commands.  Right now, it just prints them
#   to stdout for the users to review and ultimately run themselves.
#
# * Allow --threshold to be expressed in terms of KB, MB, GB.
#
# * Add nice command-line usage text.
#
# * Hangs if tf.exe is not found in PATH
#

use Cwd;
use File::Temp qw(tempfile tempdir);
use Getopt::Long;
use List::Util qw(min);
use POSIX;
use Scalar::Util qw(looks_like_number);
use Time::Piece;
use Time::Seconds;
use Win32::TieRegistry(Delimiter => '/');
use feature 'state';
use strict;

use constant DEBUG            => 0;   # Set DEBUG to 1 to enable debug tracing
use constant TF_SEPARATOR     => '/';

my $large_size_bytes = 16 * 1024 * 1024;   
my $preserve_date    = undef;
my $preserve_count   = 5;
my $tf_server;
my $tf_vcsroot;

GetOptions(
    "keepdate=s"      => \$preserve_date,
    "keepcount=i"     => \$preserve_count,
    "threshold=i"     => \$large_size_bytes,
    "root=s"          => \$tf_vcsroot,
    "server=s"        => \$tf_server
    );

die "--server argument is required." if !$tf_server;
die "--root argument is required."   if !$tf_vcsroot;

if ($preserve_date) {
    $preserve_date = win_parse_shortdate($preserve_date);
    die "keepdate must occur in the past." if time() < $preserve_date;
}

# Create a workspace and change to its folder as our working dir
my $tftmpws = tf_tmpws($tf_server, $tf_vcsroot);

# Get property information about all the TFS files.
my %tfprops = tf_server_properties(tf_server_filelist());

if (DEBUG) {
    debug_print("Filelist:");
    
    foreach (keys %tfprops) {
	my $serverfile = $_;
	debug_print($serverfile, 1);
	foreach (keys %{ $tfprops{$serverfile} } ) {
	    debug_print("$_ = $tfprops{$serverfile}{$_}", 2);
	}
    }
}

# Get the subset of files that are of large size, sorted from
# largest on down.
my @tflarge = sort { $tfprops{$b}{'Size'} <=> $tfprops{$a}{'Size'} } grep { $tfprops{$_}{'Size'} > $large_size_bytes } keys %tfprops;

if (DEBUG) {
    debug_print("Large files:");
    foreach (@tflarge) {
	debug_print("File: $_ , Size = $tfprops{$_}{'Size'}\n", 1);
    }
}

# Create tf destroy commands to remove older revisions of the large
# files we identified.
foreach (@tflarge) { 
    my $stopat = tf_find_destroy_stoppoint($_, $preserve_count, $preserve_date);
    
    # Not enough history to destroy.
    if ($stopat == -1) {
	print "\@rem Skip $_ , not enough history to destroy.\n";
    }
    else {
	print "tf destroy $_ /keephistory /stopat:C$stopat\n";
    }
}

# ----------------------------------------------------------------------
#
# If a TFS workspace was created, removes it.
#
# ----------------------------------------------------------------------
END {
    if (length($tftmpws)) {
	`tf workspace /noprompt /delete /s:$tf_server $tftmpws`;
    }
}

# ----------------------------------------------------------------------
#
# Prints a debug message when DEBUG is set.
#
# ----------------------------------------------------------------------
#
# $  : Debug message
# ;$ : Indent level for message (optional).
#
# Returns:
# No specified return value.
#
# ----------------------------------------------------------------------
sub debug_print ($;$) {
    my $out = shift;
    my $indent = shift;
    
    chomp($out);
    if ($indent == undef) { $indent = 0; }
    
    my $caller_name = (caller(1))[3];
    if (0 == length($caller_name)) { $caller_name = '[entrypoint]' };
    
    # Use of 'caller' comes from Perl Cookbook, 10.4., 
    # 'Determining Current Function Name'
    print(("\t" x $indent) . "$caller_name: $out\n") if DEBUG;
}

# ----------------------------------------------------------------------
#
# Executes a command.  If the command yields a non-zero exit code, 
# terminates the script.
#
# ----------------------------------------------------------------------
# 
# $  : The command to execute.
#
# ----------------------------------------------------------------------
sub exec_cmd ($) {
    my $cmd = shift;
    
    my $out = `$cmd`;
    if (DEBUG) {
	if (length(trim($out)) > 0) {
	    debug_print("Output from command : " . $cmd);
	    debug_print($out);
	}
	else {
	    debug_print("Ran command : " . $cmd);
	}	  
    }
    
    $? && die "Error executing command. Exit code : $? ";
}

# ----------------------------------------------------------------------
#
# Find the indices of a set of substrings.  The substrings are
# considered in the order passed in.
#
# Example: get_consecutive_indices("Good day Sara Rue", ("day", "Rue"));
# Returns: 5, 14
#
# Example: get_consecutive_indices("Good day Sara Rue", ("Rue", "day"));
# Returns: 14, -1 ("day" does not follow "Rue", so it is not found)
#
# ----------------------------------------------------------------------
#
# $  : String to search for substrings
# @  : The set of substrings to find, in the order listed.
#
# Returns:
# An array of indices where the respective substrings were found in the
# complete string.  -1 is returned for each substring that was not
# found.
#
# ----------------------------------------------------------------------
sub get_consecutive_indices ($@) {
    my $str = shift;
    my @substrs = @_;
    
    my @indices;
    my $start = 0;
    
    debug_print("Finding indices of substrs in '$str'");
    
    for (@substrs) {
	debug_print("Looking for substr '$_'", 1);
	
	# Find the index of the next substring
	my $i = index(substr($str, $start), $_);
	
	# Save the index of the substring
	push(@indices, $start + $i);
	
	$start += length;
    }
    
    foreach (@indices) { debug_print "Header found at index: $_", 1 }
    
    return @indices;
}

# ----------------------------------------------------------------------
#
# Creates a TFS workspace.
#
# ----------------------------------------------------------------------
#
# $  : The TFS server name.
# $  : The name to use for the workspace
# $  : The server name of the root folder to map into the workspace.
#
# Returns:
# Unspecified.
#
# ----------------------------------------------------------------------
sub tf_createws ($$$) {
    my ($tf_server, $tf_wsname, $tf_vcroot) = @_;
    
    exec_cmd("tf.exe workspace /noprompt /new /comment:\"Workspace created by $0.\" /s:$tf_server $tf_wsname 2>&1");
    exec_cmd("tf.exe workfold /noprompt /map /s:$tf_server /workspace:$tf_wsname \"$tf_vcroot\" \"" . cwd() . "\" 2>&1");
}

# ----------------------------------------------------------------------
#
# Determines the first changeset of a file in TFS version control that
# should NOT be destroyed to maintain minimal changeset history.
# 
# The changeset number returned may be used with tf destroy's /stopat.
#
# ----------------------------------------------------------------------
#
# $  : The server name of a file in TFS version control 
#      (e.g., $/MyTeamProject/myfile.txt)
# $  : The minimum number of changesets to keep.
# ;$ : The minimum timestamp of changesets to keep.
#
# Returns : 
# The first changeset revision of the file that should NOT be destroyed
# to maintain the minimal history specified; or -1 if no changesets
# should be destroyed; or INT_MAX if the entire history is to be
# destroyed.
#
# The minimum date specification overrides the minimum count 
# specification.  But the latest revision will always be kept unless
# explicitly called with a keep count of 0.
#
# ----------------------------------------------------------------------
sub tf_find_destroy_stoppoint ($$;$) {
    my $tf_serverfile = shift;
    my $min_changeset_keep_count = shift;
    my $min_keep_date = shift;
    
    my @tf_history = `tf.exe history /noprompt \"$tf_serverfile\"`;
    my @header_indices = get_consecutive_indices(shift @tf_history, ("Changeset", "Change", "User", "Date", "Comment"));
    
    foreach (@header_indices) { debug_print "Header at index: $_", 1 }
    
    my %changesets;
    my $datepruned = 0; # Keep track of whether we are discarding history based on date.
    
    for my $history_line (@tf_history) {
	my $cs   = trim(substr($history_line, $header_indices[0], $header_indices[1] - $header_indices[0]));
	my $date = trim(substr($history_line, $header_indices[3], $header_indices[4] - $header_indices[3]));
	
	$date = win_parse_shortdate($date);
	
	next if !looks_like_number($cs) || (-1 == $date);
	
	# Changeset is older than our minimum keep date, so we will not keep.
	if ($min_keep_date && ($date < $min_keep_date)) {
	    $datepruned = 1;
	}
	# We may keep it, depending on how many changesets we see in total.
	else
	{
	    $changesets{$cs} = $date;
	}
    }
    
    # Reverse sort by changeset.
    my @changesets_descending = reverse sort keys %changesets;
    
    # We assume increasing changeset implies increasing dates, but
    # sanity check.  I should really just sort on date, then changeset,
    # but multiple key sort in Perl (which I haven't coded in for
    # several years) is feeling like a pain).  
    #
    # Note that since tf history only shows dates, not times, equal
    # dates are likely.
    #
    for (my $i = 0; $i < $#changesets_descending; $i++) {
	if ($i > 0) {
	    ($changesets{$i-1} > $changesets{$i}) && die 'Changeset order does not match date order';
	}
	
	debug_print "Changeset '$_' for '$tf_serverfile' dated '" . localtime($changesets{$_}) . "'.";
    }

    # We expect that *some* history exists for every file.
    die "History not found for $tf_serverfile." if $#changesets_descending <= 0;
    
    if ($datepruned) {
	$min_changeset_keep_count = min($min_changeset_keep_count, min($#changesets_descending, 1));
    }

    # The entire history is to be destroyed.
    if ($min_changeset_keep_count == 0) { 
	return INT_MAX; 
    }
    # We have to keep more changesets than exist, so destroy nothing.
    elsif ($#changesets_descending < $min_changeset_keep_count) { 
	return -1; 
    }
    # Return the oldest changeset that should be kept.
    else {
	return $changesets_descending[$min_changeset_keep_count - 1];
    }
}

# ----------------------------------------------------------------------
#
# Gets the server names of files in TFS version control that are found
# in or under the current workspace folder.
#
# ----------------------------------------------------------------------
#
# Returns:
# An array of server names for files in TFS version control.
#
# ----------------------------------------------------------------------
sub tf_server_filelist {
    
    my @tf_dir = `tf.exe dir /recursive`;

    my $tf_cd;
    my @tf_server_files;
    
    #
    # Pick up the full paths to the server files from `tf.exe dir /recursive` output
    #
    foreach (@tf_dir) {
	
	chomp;
	
	if ( /^(\$.*)\:$/ ) {
	    $tf_cd = $1;
	    debug_print("Processing TFS path '$1'\n");
	} 
	elsif ( /^\$.*[^\:]$/ ) {
	    # Listing of a subfolder (but no ':' at end, 
	    # so not the beginning of its file listing), no action.
	    next;
	}
	elsif ( /^\s*$/ ) {
	    # Empty line between one subfolder listing and
	    # the next, no action.
	    next;
	}
	elsif ( /\d+ item\(s\)/ ) {
	    # Summary at the end of the listing, no action.
	    next;
	}
	else {
	    /^(.*)$/;    
	    push @tf_server_files, join(TF_SEPARATOR, ($tf_cd, $1));
	}
    }
    
    return @tf_server_files;
}

# ----------------------------------------------------------------------
#
# Gather raw TFS server property info for all files passed in.
#
# ----------------------------------------------------------------------
#
# +@ : An array of server names of files in TFS version control.
#
# Returns:
# A hash where each key is the server name of a version controlled file,
# and the value is another hash of server properties for that file.
#
# ----------------------------------------------------------------------
sub tf_server_properties (+@) {
    my @tf_server_files = @_;
    
    my $FH_atmode_in;
    my $atmode_in;
    ($FH_atmode_in, $atmode_in) = tempfile();
    
    #
    # Build up the set of commands we want to send to tf.exe.  'properties'
    # for all server files passed in.
    #
    foreach (@tf_server_files)
    {
	print $FH_atmode_in "properties \"$_\"\n";
    }
    
    # tf '@ mode' is _much_ faster.  I stumbed upon this in this MSDN thread:
    #
    # http://social.msdn.microsoft.com/Forums/eu/tfsversioncontrol/thread/ee22f4e2-758a-44c7-89d9-705baf4d1eae
    # 
    # ...see Michal Malecki's responses on that thread.
    #
    my @tf_properties_rawoutput = `tf.exe @ <"$atmode_in"`;
    
    my %tf_properties;
    my $current_file = undef;
    my $in_serverinfo_block = 0;
    
    foreach (@tf_properties_rawoutput) {
	
	debug_print("Reading line: $_");
	
	# We don't care about local info; we care about server info, 
	# which is 'truth'.
	/^Local information:/ && do {
	    $in_serverinfo_block = 0;
	    $current_file = undef;
	    debug_print("In 'Local information' block", 1); 
	    next;
	};
	
	# We're in the server info, start paying attention!
	/^Server information:/ && do {
	    $in_serverinfo_block = 1;
	    debug_print("In 'Server information' block", 1); 
	    next;
	};
	
	# Process the server info
	($in_serverinfo_block && /^\s*([^:]+):\s*(.*)$/) && do {
	    
	    my $prop = trim($1);
	    my $val   = trim($2);
	    
	    # Don't mistake tf.exe's 'prompt' seen between commands in '@ mode'
	    # for a property/value pair.
	    # 
	    # Such lines can look like this, and should be skipped.  We use the
	    # presence of ' properties ' as an indication to skip, e.g., lines
	    # like this in the output will be skipped:
	    #  
	    #    C:\mydir> properties $/MyProject/test.txt
	    #
	    $val =~ / properties / && next;
	    
	    if ('Server path' eq $prop) {
		$current_file = $val;
		debug_print("Set \$current_file = $current_file", 1); 
	    }
	    elsif ($in_serverinfo_block) {
		debug_print("File: $current_file, '$prop'=$val\n", 1); 
		$tf_properties{$current_file}{$prop} = $val;           
	    }
	};
    }
    
    return %tf_properties;
}

# ----------------------------------------------------------------------
#
# Creates a temporary folder and TFS workspace, and maps the folder to
# workspace.
#
# ----------------------------------------------------------------------
#
# $  : The TFS server name.
# $  : The server name of the folder to map into a new workspace.
#
# Returns: 
# The name of the workspace that was created.
#
# Postconditions :
# The working directory is changed to the temporary directory that the
# new workspace was mapped to.
#
# ----------------------------------------------------------------------
sub tf_tmpws ($$) {
    my ($tf_server, $tf_vcroot) = @_;

    my $tempdir = tempdir();
    chdir($tempdir);
    
    # Use the name of the script as the basis for the workspace name.
    my $tempws_template = $0;
    $tempws_template =~ s/(^[^:]+\:)(.*)$/$2/; # Remove the drive letter and colon, if present.
    $tempws_template =~ s/[^A-Z|a-z|0-9]//g;   # Strip out any non-alphanumeric chars that would foul up TFS.

    my $suffix = 0;
    my $tempws_name = $tempws_template;
    while (tf_wsexists($tf_server, $tempws_name)) {
	$tempws_name = $tempws_template . ($suffix++);
    }

    tf_createws($tf_server, $tempws_name, $tf_vcroot);

    return $tempws_name;
}

# ----------------------------------------------------------------------
#
# Checks whether the specified workspace exists for the current user.
#
# ----------------------------------------------------------------------
#
# $  : The TFS server name.
# $  : The workspace name.
#
# Returns:
# true if the workspace exists; false otherwise.
#
# ----------------------------------------------------------------------
sub tf_wsexists ($$) {
    my ($tf_server, $tf_ws) = @_;

    # If the workspace doesn't exist, output is along the lines of:
    # The workspace WORKSPACE;UserName does not exist.  ...
    #
    # Otherwise, the output will describe proper command-line usage.
    my $tfout = `tf.exe workspace /noprompt /server:$tf_server $tf_ws 2>&1`;

    return !($tfout =~ /does not exist/i);
}

# ----------------------------------------------------------------------
#
# Perl trim function to remove whitespace from the start and end of a
# string.  Taken from: http://www.somacon.com/p114.php
#
# ----------------------------------------------------------------------
#
# $  : The string to trim.
#
# Returns:
# The string with all leading and trailing whitespace removed.
#
# ----------------------------------------------------------------------
sub trim ($) {
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

# ----------------------------------------------------------------------
# 
# Parses a short date string based on the current Windows settings.
#
# ----------------------------------------------------------------------
#
# $  : A short date string that conforms to the current culture settings
#      in Windows.
#
# Returns:
# The parsed time value, expressed in seconds since epoch.
#
# ----------------------------------------------------------------------
sub win_parse_shortdate ($) {
    my $shortdate_val = shift;

    # Get the OS setting for short date format; we do this only once, the
    # first time this routine is called.  We assume it does not change 
    # during the lifetime of this script execution.
    state $shortdate_format;
    if (undef == $shortdate_format) {
	$shortdate_format = $Registry->{"CUser/Control Panel/International/sShortDate"};
    }
    
    my $part_matched = 0;
    
    # strptime format specifiers based on : http://pubs.opengroup.org/onlinepubs/009695399/functions/strptime.html
    if (!$part_matched && $shortdate_format =~ s/([^%]?)yyyy/$1\%Y/) { $part_matched = 1 } # %Y - the year, including the century (for example, 1988).
    if (!$part_matched && $shortdate_format =~ s/([^%])?yy/$1\%y/)   { $part_matched = 1 } # %y - the year within century 
    $part_matched = 0;
    
    if (!$part_matched && $shortdate_format =~ s/([^%]?)MMM/$1\%b/) { $part_matched = 1 }  # %b - the locale's abbreviated month name
    if (!$part_matched && $shortdate_format =~ s/([^%]?)MM/$1\%m/)  { $part_matched = 1 }  # %m - The month number [01,12]; leading zeros are permitted but not required.
    if (!$part_matched && $shortdate_format =~ s/([^%]?)M/$1\%m/)   { $part_matched = 1 }  # "" - ""
    $part_matched = 0;
    
    if (!$part_matched && $shortdate_format =~ s/([^%]?)dd/$1\%d/)  { $part_matched = 1 }  # %Y - the year, including the century (for example, 1988).
    if (!$part_matched && $shortdate_format =~ s/([^%]?)d/$1\%d/)   { $part_matched = 1 }  # %y - the year within century 
    $part_matched = 0;
    
    my $date;
    eval { $date = Time::Piece->strptime($shortdate_val, $shortdate_format); };
    if ($@) {
	debug_print "Date '$shortdate_val' could not be parsed using format '$shortdate_format' : '$@'";
	return -1;
    }
    
    debug_print "Parsed date is $date\n";
    return $date->epoch;
}

__END__
:endofperl
