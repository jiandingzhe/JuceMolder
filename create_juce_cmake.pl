#!/usr/bin/perl

use strict;
use feature qw/say/;
use FindBin;
use Cwd qw/abs_path/;
use File::Glob qw/bsd_glob/;
use File::Basename;
use File::Copy qw/copy/;
use File::Copy::Recursive;
use File::Spec::Functions qw/catfile catdir abs2rel/;
use File::Spec::Unix;
use File::Path;
use Getopt::Long;

my $d_in_modules;
my $d_out;

my $combine_script = catfile $FindBin::RealBin, 'combine_source.pl';

GetOptions(
    'modules=s' => \$d_in_modules,
    'out=s' => \$d_out,
    'help' => sub {
        say <<HELPDOC;
NAME

convert_juce.pl: converting JUCE to CMake-managed project

SYNOPSIS
  perl convert_juce.pl -modules juce-5.4.0/JUCE/modules -out JuceCmakeProject

COMMAND-LINE OPTIONS
-modules PATH   JUCE "modules" directory.
-out PATH       Root directory for output CMake project.
HELPDOC
        exit;
    }
);

die "input modules directory \"$d_in_modules\" not exist" if !-d $d_in_modules;
die "output directory is not specified" if !defined $d_out;

$d_out = abs_path($d_out);

# obtain all modules
opendir my $dh_in_modules, $d_in_modules or die "failed to open input modules dir $d_in_modules: $!";
my @modules = 
  grep { -d catdir($d_in_modules, $_) and -f catfile($d_in_modules, $_, "$_.h") }
  grep { $_ ne '.' and $_ ne '..' and $_ ne 'juce_audio_plugin_client' }
  readdir $dh_in_modules;
closedir $dh_in_modules;

# parse module properties
my $ver_str;
my %dep_modules; # module => [modules]
my %config_opts; # module => key => default value
my %priv_inc_dirs; # module => [dirs]
my %osx_fwks; # module => [frameworks]
my %ios_fwks; # module => [frameworks]
my %linux_pkgs; # module => [pkgconfig names]
my %linux_libs; # module => [libs]
my %mingw_libs; # module => [libs]
my %osx_libs; # module => [libs]
my %ios_libs; # module => [libs]
my %win_libs; # module => [libs]

foreach my $module (@modules)
{
    read_module_prop($module);
}

die "JUCE version is not obtained after parsing module header files" if !defined $ver_str;
my ($ver_major, $ver_minor, $ver_patch) = split /\./, $ver_str;

#
# create output project
#

mkpath $d_out if !-d $d_out;
my $f_cmake = catfile $d_out, 'CMakeLists.txt';
open my $fh_cmake, '>', $f_cmake or die "failed to create CMake file $f_cmake: $!";

print $fh_cmake <<HEREDOC;
cmake_minimum_required(VERSION 3.12)
include_guard(GLOBAL)
project(JUCE${ver_major})

HEREDOC

foreach my $module (@modules)
{
    say "write CMake for $module";
    my $d_out_module = catdir $d_out, $module;
    mkpath $d_out_module if !-d $d_out_module;
    my $d_in_module = catdir $d_in_modules, $module;

    # merge master source files
    my $master_hdr_in  = catfile $d_in_module, "$module.h";
    my $master_hdr_out = catfile $d_out_module, "$module.h";

    system($^X, $combine_script, $master_hdr_in, $master_hdr_out) == 0
      or die "combining master header failed for module $module";

    my $master_src_in;
    foreach my $ext (qw/cpp cxx c++/)
    {
        my $curr_test = catfile $d_in_module, "$module.$ext";
        if (-f $curr_test)
        {
            $master_src_in = $curr_test;
            last;
        }
    }

    my $master_src_out;
    if (defined $master_src_in)
    {
        $master_src_out = catfile $d_out_module, "$module.cpp";
        system($^X, $combine_script, $master_src_in, $master_src_out) == 0 or die "combining master source failed for module $module";
    }

    # copy objective-c++ source file
    my @common_src = (abs2rel($master_hdr_out, $d_out));
    my @apple_src;
    my @non_apple_src;
    my $master_mm_in = catfile $d_in_module, "$module.mm";
    if (-f $master_mm_in)
    {
        my $master_mm_out = catfile $d_out_module, "$module.mm";
        copy $master_mm_in, $master_mm_out or die "failed to copy master objc++ file for module $module: $!";
        push @apple_src, abs2rel($master_mm_out, $d_out);
        push @non_apple_src, abs2rel($master_src_out, $d_out) if defined $master_src_out;
    }
    else
    {
        push @common_src, abs2rel($master_src_out, $d_out) if defined $master_src_out;
    }

    # write CMake script
    write_module_cmake($fh_cmake, $module, \@common_src, \@apple_src, \@non_apple_src);
}

# generate config header
print $fh_cmake <<HEREDOC;
configure_file(AppConfig.h.in AppConfig.h)
HEREDOC

write_config_header_template();

# write dependencies
write_modules_dep($fh_cmake);

# create master library
{
    my $juce_lib_name = "juce$ver_major";
    my $module_libs = join ' ', map {module_lib_name($_)} @modules;
    print $fh_cmake <<HEREDOC;
#
# master library to use all JUCE modules at once
#
add_library($juce_lib_name INTERFACE)
target_link_libraries($juce_lib_name INTERFACE $module_libs)
set_target_properties($juce_lib_name PROPERTIES FOLDER JUCE${ver_major})

HEREDOC
}
close $fh_cmake;

#
# subs
#
sub read_module_prop
{
    my $module = shift;
    say "read module properties for $module";

    my $f_header = catfile $d_in_modules, $module, "$module.h";
    open my $fh, '<', $f_header or die "failed to open module master header file $f_header: $!";
    
    # parser states
    my $in_decl = 0;
    my $curr_config;
    my $curr_config_macro_start;

    # parse lines
    while (<$fh>)
    {
        if (!$in_decl)
        {
            if (/BEGIN_JUCE_MODULE_DECLARATION/)
            {
                $in_decl = 1;
            }
            elsif (/Config:\s*(\w+)/)
            {
                $curr_config = $1;
            }
            elsif (/^\s*#\s*ifndef\s+(\w+)/)
            {
                if (defined $curr_config)
                {
                    die "conflicting config name: <$curr_config> via comment title, <$1> via #ifndef for file $f_header"
                      if $curr_config ne $1;
                    $curr_config_macro_start = 1;
                }
            }
            elsif (/^\s*#\s*define\s+(\w+)\s+(\w+)/)
            {
                if ($curr_config_macro_start)
                {
                    if ($curr_config eq $1)
                    {
                        $config_opts{$module}{$curr_config} = $2;
                        $curr_config_macro_start = 0;
                        $curr_config = undef;
                    }
                    else
                    {
                        warn "ignore conflicting config name: $curr_config via comment title, $1 via #define\n";
                    }
                }
            }
        }
        else
        {
            if (/:/)
            {
                my ($key, @items) = parse_decl_line($_);
                $key = lc $key;
                next if @items == 0;
                
                if ($key eq 'version' and $module eq 'juce_core')
                {
                    $ver_str = $items[0];
                }
                elsif ($key eq 'id')
                {
                    die "conflict module name: $module from path, $items[0] from decl\n$_"
                      if $module ne $items[0];
                }
                elsif ($key eq 'dependencies')  { $dep_modules{$module}   = [@items] }
                elsif ($key eq 'searchpaths')   { $priv_inc_dirs{$module} = [@items] }
                elsif ($key eq 'osxframeworks') { $osx_fwks{$module}      = [@items] }
                elsif ($key eq 'iosframeworks') { $ios_fwks{$module}      = [@items] }
                elsif ($key eq 'linuxpackages') { $linux_pkgs{$module}    = [@items] }
                elsif ($key eq 'linuxlibs')     { $linux_libs{$module}    = [@items] }
                elsif ($key eq 'mingwlibs')     { $mingw_libs{$module}    = [@items] }
                elsif ($key eq 'osxlibs')       { $osx_libs{$module}      = [@items] }
                elsif ($key eq 'ioslibs')       { $ios_libs{$module}      = [@items] }
                elsif ($key eq 'windowslibs')   { $win_libs{$module}      = [@items] }
            }
            elsif (/END_JUCE_MODULE_DECLARATION/)
            {
                $in_decl = 0;
            }
        }
    }
    close $fh;
}

sub parse_decl_line
{
    my $text = shift;
    $text =~ /(\w+)\s*:\s*(.*)\s*$/ or die "failed to parse module declaration text:\n$text";
    my $name = $1;
    my $values_str = $2;
    my @items = split /\s+/, $values_str;
    return $name, @items;
}

sub write_module_cmake
{
    my ($fh, $module, $sources_common, $sources_apple, $sources_non_apple) = @_;

    s{\\}{/}g foreach @$sources_common, @$sources_apple, @$sources_non_apple;

    # create library
    my $module_lib = module_lib_name($module);
    my $source_line_apple = join ' ', @$sources_common, @$sources_apple;
    my $source_line_non_apple = join ' ', @$sources_common, @$sources_non_apple;
    print $fh <<HEREDOC;
#
# module $module
#
if(APPLE)
    add_library(${module_lib} STATIC $source_line_apple)
else()
    add_library(${module_lib} STATIC $source_line_non_apple)
endif()
set_target_properties(${module_lib} PROPERTIES FOLDER JUCE${ver_major})
target_include_directories($module_lib PUBLIC \$\{CMAKE_CURRENT_SOURCE_DIR\} \$\{CMAKE_CURRENT_BINARY_DIR\})

HEREDOC
    # options
    write_module_options($fh, $module);

    # depend library
    write_ruled_libs($fh, $module_lib, 'MSVC',  $win_libs{$module})
      if exists $win_libs{$module};
    write_ruled_libs($fh, $module_lib, 'MINGW', $mingw_libs{$module})
      if exists $mingw_libs{$module};
    write_ruled_libs($fh, $module_lib, 'IOS',   $ios_libs{$module})
      if exists $ios_libs{$module};
    write_ruled_libs($fh, $module_lib, 'APPLE AND NOT IOS', $osx_libs{$module})
      if exists $osx_libs{$module};
    write_ruled_libs($fh, $module_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux"', $linux_libs{$module})
      if exists $linux_libs{$module};
    write_ruled_pkgs($fh, $module_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux"', $linux_pkgs{$module})
      if exists $linux_pkgs{$module};
    write_ruled_frameworks($fh, $module_lib, 'IOS', $ios_fwks{$module})
      if exists $ios_fwks{$module};
    write_ruled_frameworks($fh, $module_lib, 'APPLE AND NOT IOS', $osx_fwks{$module})
      if exists $osx_fwks{$module};
    
    # include directories
    if (exists $priv_inc_dirs{$module})
    {
        my $inc_str = join ' ', @{$priv_inc_dirs{$module}};
        print $fh <<HEREDOC;
target_include_directories($module_lib PRIVATE $inc_str)
HEREDOC
    }

    say $fh '';
}

sub module_lib_name
{
    my $module = shift;
    my $module_sub_name = $module;
    $module_sub_name =~ s/^juce_//i;
    $module_sub_name =~ s/^juze_//i;
    my $module_lib = "juce${ver_major}_$module_sub_name";
    return $module_lib;
}

sub write_module_options
{
    my ($fh, $module) = @_;
    return if !exists $config_opts{$module};

    foreach my $opt (sort keys %{$config_opts{$module}})
    {
        my $default = $config_opts{$module}{$opt};
        print $fh <<HEREDOC;
set($opt $default CACHE BOOL "")
HEREDOC
    }
    say $fh '';
}

sub write_ruled_libs
{
    my ($fh_out, $lib_name, $rule, $libs) = @_;
    my $libs_line = join ' ', @$libs;
    print $fh_out <<HEREDOC;
if($rule)
    target_link_libraries($lib_name $libs_line)
endif()
HEREDOC
}

sub write_ruled_frameworks
{
    my ($fh_out, $lib_name, $rule, $frameworks) = @_;

    print $fh_out <<HEREDOC;
if($rule)
HEREDOC
    my @flib_vars;
    foreach my $fwk (@$frameworks)
    {
        my $flib_var = "FRAMELIB_$fwk";
        print $fh_out <<HEREDOC;
    find_package($flib_var $fwk)
HEREDOC
        push @flib_vars, $flib_var;
    }

    my $flib_str = join ' ', @flib_vars;
    print $fh_out <<HEREDOC;
    target_link_libraries($lib_name $flib_str)
endif()
HEREDOC
}

sub write_ruled_pkgs
{
    my ($fh_out, $lib_name, $rule, $pkgs) = @_;
    print $fh_out <<HEREDOC;
if($rule)
    find_package(PkgConfig REQUIRED)
HEREDOC

    foreach my $pkg (@$pkgs)
    {
        my $var_name = uc $pkg;
        $var_name =~ s/\W+/_/g;
        print $fh_out <<HEREDOC;
    pkg_check_modules($var_name REQUIRED $pkg)
    target_link_libraries($lib_name \$\{${var_name}_LIBRARIES\})
    target_include_directories($lib_name PRIVATE \$\{${var_name}_INCLUDE_DIRS\})
HEREDOC
    }

    print $fh_out <<HEREDOC;
endif()
HEREDOC
}

sub write_modules_dep
{
    my $fh = shift;

    print $fh <<HEREDOC;
#
# module dependencies
#
HEREDOC

    say "dependencies";

    foreach my $module (@modules)
    {
        say "  $module";
        my $module_lib = module_lib_name($module);
        next if !exists $dep_modules{$module};
        my $dep_str = join ' ', map {module_lib_name($_)} @{$dep_modules{$module}};
        say "    $dep_str";
        print $fh <<HEREDOC;
target_link_libraries($module_lib $dep_str)
HEREDOC
    }

    say $fh '';
}

sub write_config_header_template
{
    my $f_hdr = catfile $d_out, 'AppConfig.h.in';
    open my $fh, '>', $f_hdr or die "failed to open config header template $f_hdr: $!";
    
    print $fh <<HEREDOC;
#pragma once

#ifndef JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED
#define JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED
#endif

HEREDOC

    foreach my $module (sort keys %config_opts)
    {
        print $fh <<HEREDOC;
// $module
HEREDOC
        foreach my $config (sort keys %{$config_opts{$module}})
        {
            print $fh <<HEREDOC;
#cmakedefine01 $config
HEREDOC
        }
        say $fh '';
    }
    
    close $fh;
}