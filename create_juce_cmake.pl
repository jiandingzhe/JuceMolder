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
my @plugin_source_paths = qw[juce_audio_plugin_client juce_audio_processors/format_types];

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
my %config_opts; # key => default value
my %priv_inc_dirs; # {dirs}
my %osx_fwks; # {frameworks}
my %ios_fwks; # {frameworks}
my %linux_pkgs; # {pkgconfig names}
my %linux_libs; # {libs}
my %mingw_libs; # {libs}
my %osx_libs; # {libs}
my %ios_libs; # {libs}
my %win_libs; # {libs}

foreach my $module (@modules)
{
    read_module_prop($module);
}

die "JUCE version is not obtained after parsing module header files" if !defined $ver_str;
my ($ver_major, $ver_minor, $ver_patch) = split /\./, $ver_str;

# create output project
mkpath $d_out if !-d $d_out;
my $f_cmake = catfile $d_out, 'CMakeLists.txt';
open my $fh_cmake, '>', $f_cmake or die "failed to create CMake file $f_cmake: $!";

print $fh_cmake <<HEREDOC;
cmake_minimum_required(VERSION 3.12)
include_guard(GLOBAL)
project(JUCE${ver_major})

HEREDOC

# merge source files for each module
my @common_src;
my @apple_src;
my @non_apple_src;

foreach my $module (@modules)
{
    say "write CMake for $module";
    my $d_out_module = catdir $d_out, $module;
    mkpath $d_out_module if !-d $d_out_module;
    my $d_in_module = catdir $d_in_modules, $module;

    # merge master source files
    my $master_hdr_in  = catfile $d_in_module, "$module.h";
    my $master_hdr_out = catfile $d_out_module, "$module.h";

    system($^X, $combine_script,
        '-in', $master_hdr_in,
        '-out', $master_hdr_out,
        '-skip', @plugin_source_paths) == 0
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
        system($^X, $combine_script,
            '-in', $master_src_in,
            '-out', $master_src_out,
            '-skip', @plugin_source_paths) == 0
          or die "combining master source failed for module $module";
    }

    # copy objective-c++ source file
    push @common_src, abs2rel($master_hdr_out, $d_out);
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
}

# generate config header
foreach my $config_key (sort keys %config_opts)
{
    print $fh_cmake <<HEREDOC;
set($config_key "$config_opts{$config_key}" CACHE BOOL "")
HEREDOC
}

print $fh_cmake <<HEREDOC;
configure_file(AppConfig.h.in AppConfig.h)

HEREDOC

write_config_header_template();

# create library
my $juce_lib = "juce$ver_major";

my $avail_flags = join "\n    ", map {"JUCE_MODULE_AVAILABLE_$_"} @modules;
my $source_line_common = join "\n    ", @common_src;
my $source_line_apple = join "\n        ", @apple_src;
my $source_line_non_apple = join "\n        ", @non_apple_src;
print $fh_cmake <<HEREDOC;
set(juce_sources
    $source_line_common)

if(APPLE)
    list(APPEND juce_sources
        $source_line_apple)
else()
    list(APPEND juce_sources
        $source_line_non_apple)
endif()

add_library($juce_lib STATIC \$\{juce_sources\})

set_target_properties(${juce_lib} PROPERTIES
    FOLDER JUCE${ver_major}
    POSITION_INDEPENDENT_CODE 1)

target_compile_features(${juce_lib} PUBLIC cxx_std_14)

target_compile_definitions(${juce_lib} PUBLIC
    $avail_flags)

target_include_directories($juce_lib PUBLIC
    \$\{CMAKE_CURRENT_SOURCE_DIR\}
    \$\{CMAKE_CURRENT_BINARY_DIR\})

if(CMAKE_SYSTEM_PROCESSOR STREQUAL "armv7-a")
    target_compile_options($juce_lib PUBLIC -mfpu=neon)
endif()

HEREDOC

# dependent libs
write_ruled_frameworks($fh_cmake, $juce_lib, 'IOS', [sort keys %ios_fwks]);
write_ruled_frameworks($fh_cmake, $juce_lib, 'APPLE AND NOT IOS', [sort keys %osx_fwks]);
write_ruled_libs($fh_cmake, $juce_lib, 'IOS', [sort keys %ios_libs]);
write_ruled_libs($fh_cmake, $juce_lib, 'APPLE AND NOT IOS', [sort keys %osx_libs]);
write_ruled_libs($fh_cmake, $juce_lib, 'WIN32', [sort keys %win_libs]);
write_ruled_libs($fh_cmake, $juce_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux"', [sort keys %linux_libs]);
write_ruled_pkgs($fh_cmake, $juce_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux"', [sort keys %linux_pkgs]);
write_ruled_pkgs($fh_cmake, $juce_lib, 'JUCE_WEB_BROWSER AND CMAKE_SYSTEM_NAME STREQUAL "Linux"', [qw/gtk+-3.0 webkit2gtk-4.0/]);

if (%priv_inc_dirs > 0)
{
    my $inc_text = join "\n    ", sort keys %priv_inc_dirs;
    print $fh_cmake <<HEREDOC;
target_include_directories($juce_lib PRIVATE
    $inc_text)
HEREDOC
}

# finalize

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
                        $config_opts{$curr_config} = $2;
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
                elsif ($key eq 'searchpaths')   { $priv_inc_dirs{$_} = undef foreach @items }
                elsif ($key eq 'osxframeworks') { $osx_fwks{$_}      = undef foreach @items }
                elsif ($key eq 'iosframeworks') { $ios_fwks{$_}      = undef foreach @items }
                elsif ($key eq 'linuxpackages') { $linux_pkgs{$_}    = undef foreach @items }
                elsif ($key eq 'linuxlibs')     { $linux_libs{$_}    = undef foreach @items }
                elsif ($key eq 'mingwlibs')     { $mingw_libs{$_}    = undef foreach @items }
                elsif ($key eq 'osxlibs')       { $osx_libs{$_}      = undef foreach @items }
                elsif ($key eq 'ioslibs')       { $ios_libs{$_}      = undef foreach @items }
                elsif ($key eq 'windowslibs')   { $win_libs{$_}      = undef foreach @items }
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

    foreach my $config (sort keys %config_opts)
    {
        print $fh <<HEREDOC;
#cmakedefine01 $config
HEREDOC
    }
    say $fh '';
    
    close $fh;
}