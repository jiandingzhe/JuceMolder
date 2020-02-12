#!/usr/bin/perl

use strict;
use feature qw/say/;
use FindBin;
use Cwd qw/abs_path/;
use File::Glob qw/bsd_glob/;
use File::Basename;
use File::Copy qw/copy/;
use File::Copy::Recursive qw/dircopy/;
use File::Spec::Functions qw/catfile catdir abs2rel rel2abs/;
use File::Spec::Unix;
use File::Path;
use Getopt::Long;

my $d_in_modules;
my $d_out;

my $combine_script = catfile $FindBin::RealBin, 'combine_source.pl';
my @plugin_modules = qw[juce_audio_plugin_client];

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

$d_out = rel2abs($d_out);

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
my %config_docs; # key => help doc
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

my @all_src_in;
my @all_src_out;

foreach my $module (@modules)
{
    say "write CMake for $module";
    my $d_out_module = catdir $d_out, $module;
    mkpath $d_out_module if !-d $d_out_module;
    my $d_in_module = catdir $d_in_modules, $module;

    # merge master source files
    my $master_hdr_in  = catfile $d_in_module, "$module.h";
    my $master_hdr_out = catfile $d_out_module, "$module.h";
    push @all_src_in, $master_hdr_in;
    push @all_src_out, $master_hdr_out;

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
        push @all_src_in, $master_src_in;
        push @all_src_out, $master_src_out;
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

system($^X, $combine_script,
    '-in', @all_src_in,
    '-out', @all_src_out,
    '-inc-dir', $d_in_modules,
    '-extra-inc-files', 'AppConfig.h') == 0
  or die "combining master sources failed";

# generate config header
foreach my $config_key (sort keys %config_opts)
{
    my $doc_lines = $config_docs{$config_key};
    foreach (@$doc_lines)
    {
        s/\\/\\\\/g;
        s/"/\\"/g;
        s/{/\\{/g;
        s/}/\\}/g;
        s/\$/\\\$/g;
    }
    my $doc = join '\n', @$doc_lines;
    my $config_interface_key = $config_key;
    $config_interface_key =~ s/^JUCE_/JUCE${ver_major}_/ or die "failed to parse config key $config_key";
    print $fh_cmake <<HEREDOC;
set($config_interface_key "$config_opts{$config_key}" CACHE BOOL "$doc")
set($config_key \$\{$config_interface_key\})
HEREDOC
}

print $fh_cmake <<HEREDOC;
configure_file(AppConfig.h.in AppConfig.h)

HEREDOC

write_config_header_template();

# create library
s/\\/\//g foreach @common_src, @apple_src, @non_apple_src;
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
write_ruled_libs($fh_cmake, $juce_lib, 'MINGW', [sort keys %mingw_libs]);
write_ruled_libs($fh_cmake, $juce_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux"', [sort keys %linux_libs]);
write_ruled_libs($fh_cmake, $juce_lib, 'CMAKE_SYSTEM_NAME STREQUAL "Linux" AND JUCE_USE_CURL', [qw/curl/]);
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

# process plugin generator CMake code
my $d_plugin_code = catdir $d_out, 'plugin_code';
mkpath $d_plugin_code if !-d $d_plugin_code;

my $repl_vars = {
    ver_major => $ver_major,
    ver_minor => $ver_minor,
    ver_patch => $ver_patch
};
process_plugin_cmake($fh_cmake, $repl_vars);

copy catfile($FindBin::RealBin, 'plugin_gen', 'apple_app.plist.in'), catfile($d_plugin_code, 'apple_app.plist.in');
copy catfile($FindBin::RealBin, 'plugin_gen', 'apple_au.plist.in'), catfile($d_plugin_code, 'apple_au.plist.in');
copy catfile($FindBin::RealBin, 'plugin_gen', 'PluginConfig.h.in'), catfile($d_plugin_code, 'PluginConfig.h.in');

# process plugin code
foreach my $spec_module (@plugin_modules)
{
    my $spec_dir_in = catdir $d_in_modules, $spec_module;
    my $spec_dir_out = catdir $d_plugin_code, $spec_module;
    
    # amalgamate C++ files
    opendir my $dh, $spec_dir_in or die "failed to open directory $spec_dir_in: $!";
    my @all_names = sort grep {$_ ne '.' and $_ ne '..'} readdir $dh;
    my @fnames = grep {/(\.c|\.c++|\.cpp|\.cxx|\.h|\.hpp|\.m|\.mm|\.r)$/i} @all_names;
    close $dh;
    
    mkpath $spec_dir_out if !-d $spec_dir_out;
    my @plugin_inputs  = map {catfile $spec_dir_in, $_} @fnames;
    my @plugin_outputs = map {catfile $spec_dir_out, $_} @fnames;
    system($^X, $combine_script,
        '-in', @plugin_inputs,
        '-out', @plugin_outputs,
        '-skip', "${spec_module}.h", (map {"$_.h"} @modules),
        '-inc-dir', $d_in_modules,
        '-extra-inc-files', 'AppConfig.h', 'PluginConfig.h') == 0
      or die "combine script failed";
}

mkpath catdir($d_out, 'plugin_code', 'sdk_vst2');
mkpath catdir($d_out, 'plugin_code', 'sdk_vst3');
mkpath catdir($d_out, 'plugin_code', 'sdk_aax');
mkpath catdir($d_out, 'plugin_code', 'sdk_core_audio');

# create plugin test
my $d_plugin = catdir $d_out, 'test_plugin';
mkpath $d_plugin if !-d $d_plugin;
print $fh_cmake <<HEREDOC;
add_subdirectory(test_plugin)
HEREDOC

open my $fh_plugin_cmake, '>', catfile($d_plugin, 'CMakeLists.txt') or die "failed to open plugin cmake: $!";
process_template(catfile($FindBin::RealBin, 'plugin_gen', 'plugin_test.cmake'), $fh_plugin_cmake, $repl_vars);
close $fh_plugin_cmake;

foreach my $fname (qw/TestPluginUI.h TestPluginUI.cpp TestPluginProcessor.h TestPluginProcessor.cpp/)
{
    copy catfile($FindBin::RealBin, 'plugin_gen', $fname), catfile($d_plugin, $fname) or die "failed to copy $fname to test plugin dir";
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
    my @curr_config_help;

    my $block_comment = 0;

    # parse lines
    while (my $line = <$fh>)
    {
        # determine begin of comment
        my $block_comment_end = 0;
        my $cont_comment_text;
        if ($block_comment)
        {
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;
            if ($line =~ m{(.*)\s*\*+/$}) {
                #say "end block comment:\n    $line";
                $cont_comment_text = $1;
                $block_comment_end = 1;
            }
            else
            {
                #say "    block comment:\n         $line";
                $cont_comment_text = $line;
            }
        }
        else
        {
            my $line_trim = $line;
            $line_trim =~ s/^\s+//;
            $line_trim =~ s/\s+$//;
            if ($line_trim =~ m{^/\*+\s*(.*)})
            {
                #say "begin block comment:\n    $line_trim";
                $block_comment = 1;
                $cont_comment_text = $1;
            }
            elsif ($line_trim =~ m{^//\s*(.*)})
            {
                #say "single comment:\n    $line_trim";
                $cont_comment_text = $1;
            }
        }
        

        # process comment part
        if (defined $cont_comment_text)
        {
            if ($in_decl)
            {
                if ($cont_comment_text =~ /:/)
                {
                    my ($key, @items) = parse_decl_line($cont_comment_text);
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
                elsif ($cont_comment_text =~ /END_JUCE_MODULE_DECLARATION/)
                {
                    $in_decl = 0;
                }
            }
            else
            {
                if ($cont_comment_text =~ /BEGIN_JUCE_MODULE_DECLARATION/)
                {
                    $in_decl = 1;
                }
                elsif ($cont_comment_text =~ /Config:\s*(\w+)/)
                {
                    $curr_config = $1;
                }
                else
                {
                    if (defined $curr_config)
                    {
                        push @curr_config_help, $cont_comment_text if length($cont_comment_text) > 0;
                    }
                }

            }
        }
        # process non-comment part
        else
        {
            die "outside continuous-comment, but still in JUCE_MODULE_DECLARATION:\n$line" if $in_decl;
            
            if ($line =~ /^\s*#\s*ifndef\s+(\w+)/)
            {
                if (defined $curr_config)
                {
                    die "conflicting config name: <$curr_config> via comment title, <$1> via #ifndef for file $f_header"
                    if $curr_config ne $1;
                    $curr_config_macro_start = 1;
                }
            }
            elsif ($line =~ /^\s*#\s*define\s+(\w+)\s+(\w+)/)
            {
                if ($curr_config_macro_start)
                {
                    if ($curr_config eq $1)
                    {
                        $config_opts{$curr_config} = $2;
                        $config_docs{$curr_config} = [@curr_config_help];
                        $curr_config_macro_start = 0;
                        $curr_config = undef;
                        @curr_config_help = ();
                    }
                    else
                    {
                        warn "ignore conflicting config name: $curr_config via comment title, $1 via #define\n";
                    }
                }
            }
            
        }

        if ($block_comment_end)
        {
            $block_comment = 0;
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
    return if @$libs == 0;

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
    return if @$frameworks == 0;

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
    return if @$pkgs == 0;

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

sub process_plugin_cmake
{
    my ($fh_out, $replace_vars) = @_;

    print $fh_out <<HEREDOC;
#
# plugin generation utilities
#
HEREDOC
    my $file_in = catfile $FindBin::RealBin, 'plugin_gen', "JucePlugin.cmake";
    process_template($file_in, $fh_out, $replace_vars);
}

sub process_template
{
    my ($file_in, $fh_out, $vars) = @_;
    open my $fh_in, '<', $file_in or die "failed to open input template $file_in: $!";
    while (my $line = <$fh_in>)
    {
        while ($line =~ /\^\^(\w+?)\^\^/)
        {
            my $var_name = $1;
            die "var $var_name in line not defined:\n$line" if !exists $vars->{$var_name};
            my $value = $vars->{$var_name};
            $line =~ s/\^\^${var_name}\^\^/$value/ or die "failed to replace $var_name in line:\n$line";
        }
        print $fh_out $line;
    }
    close $fh_in;
}
