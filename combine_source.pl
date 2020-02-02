#!/usr/bin/perl

use strict;
use feature qw/say/;
use Cwd qw/abs_path/;
use File::Glob qw/bsd_glob/;
use File::Basename;
use File::Spec::Functions;
use File::Path;

my $file_in = shift;
my $file_out = shift;

die "input file $file_in not exist" if !-f $file_in;
$file_in = abs_path($file_in);

open my $fh_out, '>', $file_out or die "failed to open $file_out; $!";

my $main_header;
if ($file_in =~ /(\.h|\.hpp)$/)
{
    print $fh_out <<HEREDOC;
#pragma once
#include "AppConfig.h"

HEREDOC
}
else
{
    $main_header = $file_in;
    $main_header =~ s/(\.cpp|\.cxx|\.c\+\+)$/.h/;
}

proc_one_file($fh_out, $file_in, basename($file_in));

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
        elsif (/^\s*#\s*include\s+(?:<|")(.+)(?:>|")/)
        {
            my $inc_file = $1;
            my $inc_file_full = catfile $fdir_in, $inc_file; 
            if (-f $inc_file_full and !(defined $main_header and abs_path($inc_file_full) eq abs_path($main_header)))
            {
                if (!exists $processed_files{$inc_file_full})
                {
                    say $fh_out "//-------- begin $inc_file --------";
                    say ((' 'x$indent) . "read included $inc_file by $f_in_display");
                    proc_one_file($fh_out, $inc_file_full, $inc_file);
                    say $fh_out "//-------- end $inc_file --------";
                }
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

close $fh_out;