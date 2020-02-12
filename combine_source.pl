#!/usr/bin/perl

use strict;
use feature qw/say/;
use File::Glob qw/bsd_glob/;
use File::Basename;
use File::Spec::Functions qw/catfile catdir abs2rel rel2abs/;
use File::Path;
use Getopt::Long;

my @files_in;
my @files_out;
my @skip_paths;
my @inc_dirs;
my @extra_inc_files;

GetOptions(
    'in=s{1,}' => \@files_in,
    'out=s{1,}' => \@files_out,
    'skip=s{,}' => \@skip_paths,
    'inc-dir=s{,}' => \@inc_dirs,
    'extra-inc-files=s{,}' => \@extra_inc_files,
    'help' => \&show_help_and_exit
);

# validate and preprocess options
die "input files not specified" if @files_in == 0;
die "output files not specified" if @files_out == 0;
die "inequal number of input and output files" if @files_in != @files_out;

say "skip:";
say "  $_" foreach @skip_paths;

foreach my $f_in (@files_in)
{
    die "input file $f_in not exist" if !-f $f_in;
    $f_in = rel2abs($f_in);
}

my %files_in = map {$_, undef} @files_in;

foreach my $f_out (@files_out)
{
    $f_out = rel2abs($f_out);
}

s/\\/\//g foreach @skip_paths;
s/\\/\//g foreach @inc_dirs;

# do process
foreach my $fi (0..$#files_in)
{
    my $f_in = $files_in[$fi];
    my $f_out = $files_out[$fi];

    open my $fh_out, '>', $f_out or die "failed to open $f_out; $!";
    if ($f_in =~ /(\.h|\.hpp)$/)
    {
        print $fh_out <<HEREDOC;
#pragma once
HEREDOC
    }

    foreach (@extra_inc_files)
    {
        print $fh_out <<HEREDOC;
#include "$_"
HEREDOC
    }

    my %processed_files;
    proc_one_file($fh_out, $f_in, basename($f_in), dirname($f_in), \%processed_files);

    close $fh_out;

}

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

sub proc_one_file
{
    my ($fh_out, $f_in, $f_in_display, $in_root, $processed_files) = @_;
    $f_in = rel2abs $f_in;
    $processed_files->{$f_in} = undef;
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
            my ($inc_file_dir, $inc_file_full) = find_inc_file($inc_file, @inc_dirs, $fdir_in);

            if (exists $processed_files->{$inc_file_full})
            {
            }
            elsif (-f $inc_file_full)
            {
                my $inc_file_in_root = abs2rel $inc_file_full, $in_root;
                if (file_in_skip_list($inc_file) or exists $files_in{$inc_file_full})
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
                    proc_one_file($fh_out, $inc_file_full, $inc_file, $in_root, $processed_files);
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

sub find_inc_file
{
    my ($fname, @dirs) = @_;
    foreach my $curr_dir (@dirs)
    {
        my $f_full = catfile $curr_dir, $fname;
        if (-f $f_full)
        {
            $f_full = rel2abs($f_full);
            return $curr_dir, $f_full;
        }
    }
    return undef, undef;
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