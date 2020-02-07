#!/usr/bin/perl

use strict;
use feature qw/say/;
use Cwd qw/abs_path/;
use File::Glob qw/bsd_glob/;
use File::Basename;
use File::Spec::Functions qw/catfile catdir abs2rel/;
use File::Path;
use Getopt::Long;

my $file_in;
my $file_out;
my @skip_paths;
my @extra_inc;

GetOptions(
    'in=s' => \$file_in,
    'out=s' => \$file_out,
    'skip=s{,}' => \@skip_paths,
    'extra-inc=s{,}' => \@extra_inc,
    'help' => \&show_help_and_exit
);

# validate and preprocess options
die "input file not specified" if !defined $file_in;
die "input file $file_in not exist" if !-f $file_in;
die "output file not specified" if !defined $file_out;

$file_in = abs_path($file_in);
s/\\/\//g foreach @skip_paths;
my $in_root = dirname $file_in;

# do process
open my $fh_out, '>', $file_out or die "failed to open $file_out; $!";

my $main_header;
if ($file_in =~ /(\.h|\.hpp)$/)
{
    print $fh_out <<HEREDOC;
#pragma once

HEREDOC
}
else
{
    $main_header = $file_in;
    $main_header =~ s/(\.cpp|\.cxx|\.c\+\+)$/.h/;
}

foreach (@extra_inc)
{
    print $fh_out <<HEREDOC;
#include "$_"
HEREDOC
}

proc_one_file($fh_out, $file_in, basename($file_in));

close $fh_out;

#
# subs
#
sub write_guard_macro
{
    my ($fh_out, $fname) = @_;
    my $macro_name = uc $fname;
    $macro_name =~ s/\W/_/g;
    say $fh_out "#ifndef $macro_name";
    say $fh_out "#define $macro_name";
    return $macro_name;
}

my $indent = 0;
my %processed_files;
sub proc_one_file
{
    my ($fh_out, $f_in, $f_in_display) = @_;
    $f_in = abs_path $f_in;
    $processed_files{$f_in} = undef;
    $indent += 2;

    my $fdir_in = dirname $f_in;    
    open my $fh_in, '<', $f_in or die "failed to open $f_in: $!";

    my $guard_macro;
    
    while (<$fh_in>)
    {
        s/\r\n/\n/;
        if (/^\s*#\s*pragma\s+once/)
        {
            die "duplicate praga once for file $f_in" if defined $guard_macro;
            $guard_macro = write_guard_macro($fh_out, $f_in_display);
        }
        elsif (/(^\s*#\s*include\s+(?:<|")(.+)(?:>|")\s*)(.*)/)
        {
            my $text_before_after_inc = $1;
            my $inc_file = $2;
            my $text_after_inc = $3;
            my $inc_file_full = catfile $fdir_in, $inc_file;
            $inc_file_full = abs_path $inc_file_full;
            my $inc_file_in_root = abs2rel $inc_file_full, $in_root;

            if (exists $processed_files{$inc_file_full})
            {
            }
            elsif (-f $inc_file_full and
                !(defined $main_header and abs_path($inc_file_full) eq abs_path($main_header)))
            {
                if (file_in_skip_list($inc_file_in_root))
                {
                    say $fh_out "#include \"$inc_file_in_root\"";
                    say ' ' x $indent, "convert skipped file $inc_file from\n",
                        ' ' x $indent, "  $inc_file_full to\n",
                        ' ' x $indent, "  $inc_file_in_root";
                }
                else
                {
                    say $fh_out "//-------- begin $inc_file --------";
                    say ((' 'x$indent) . "read included $inc_file by $f_in_display");
                    proc_one_file($fh_out, $inc_file_full, $inc_file);
                    say $fh_out "//-------- end $inc_file --------";
                }
                say $fh_out ' ' x length($text_before_after_inc), $text_after_inc;
            }
            else
            {
                print $fh_out $_;
            }
        }
        else
        {
            print $fh_out $_;
        }
    }

    say $fh_out "#endif /* include guard $guard_macro */"
      if defined $guard_macro;
    close $fh_in;
    $indent -= 2;
}

sub file_in_skip_list
{
    my $file = shift;
    foreach my $skip_pattern (@skip_paths)
    {
        return 1 if ($file =~ /$skip_pattern/)
    }
    return 0;
}

sub show_help_and_exit
{
    print <<HELPDOC;
Command-Line Options:
-in FILE    Input file.
-out FILE   Output file.
-skip PATTERN1 PATTERN2 ...
            File names matching any of these patterns will be ignored.
HELPDOC
    exit;
}