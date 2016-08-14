#!/usr/bin/perl -w
use strict;

# Copyright 2008, Andrew Ross andy@plausible.org
# Distributable under the terms of the GNU GPL, see COPYING for details

# The Android toolchain is ... rough.  Rather than try to manage the
# complexity directly, this script wraps the tools into an "agcc" that
# works a lot like a gcc command line does for a native platform or a
# properly integrated cross-compiler.  It accepts arbitrary arguments,
# but interprets the following specially:
#
# -E/-S/-c/-shared - Enable needed arguments (linker flags, include
#                    directories, runtime startup objects...) for the
#                    specified compilation mode when building under
#                    android.
#
# -O<any> - Turn on the optimizer flags used by the Dalvik build.  No
#           control is provided over low-level optimizer flags.
#
# -W<any> - Turn on the warning flags used by the Dalvik build.  No
#           control is provided over specific gcc warning flags.
#
# Notes:
# + The prebuilt arm-eabi-gcc from a built (!) android source
#   directory must be on your PATH.
# + All files are compiled with -fPIC to an ARMv5TE target.  No
#   support is provided for thumb.
# + No need to pass a "-Wl,-soname" argument when linking with
#   -shared, it uses the file name always (so don't pass a directory in
#   the output path for a shared library!)

# Dance around to find the actual android toolchain path (it's very
# deep, so links on $PATH are going to be common.
my $DROID="NDK PATH";
my $VERSION = "4.8";
my $ABASE = "$DROID/platforms/android-3";
my $ALIB = "$ABASE/arch-arm/usr/lib";
my $TOOLCHAIN = "$DROID/toolchains/arm-linux-androideabi-$VERSION/prebuilt/linux-x86_64";
my $GCC="$TOOLCHAIN/bin/arm-linux-androideabi-gcc";


my $ARCH="armeabi";

my @include_paths = (
    "-I$ABASE/arch-arm/usr/include",
    "-I$ABASE/common/include"
    );

my @preprocess_args = (
    "-D__ARM_ARCH_5__",
    "-D__ARM_ARCH_5T__",
    "-D__ARM_ARCH_5E__",
    "-D__ARM_ARCH_5TE__", # Already defined by toolchain
    "-DANDROID",
    "-DSK_RELEASE",
    "-DNDEBUG",
    "-UDEBUG");

my @warn_args = (
    "-Wall",
    "-Wno-unused", # why?
    "-Wno-multichar", # why?
    "-Wstrict-aliasing=2"); # Implicit in -Wall per texinfo

my @compile_args = (
    "-march=armv5te",
    "-mtune=xscale",
    "-msoft-float",
    "-mthumb-interwork",
    "-fpic",
    "-FPIE",
    "-pie" ,#add PIE FLAGS
    "-fno-exceptions",
    "-ffunction-sections",
    "-funwind-tables", # static exception-like tables
    "-fstack-protector", # check guard variable before return
    "-fmessage-length=0", # No line length limit to error messages
    "-fno-short-enums"
); # disable variable size enums

my @optimize_args = (
    "-O2",
    "-finline-functions",
    "-finline-limit=300",
    "-fno-inline-functions-called-once",
    "-fgcse-after-reload",
    "-frerun-cse-after-loop", # Implicit in -O2 per texinfo
    "-frename-registers",
    "-fomit-frame-pointer",
    "-fstrict-aliasing", # Implicit in -O2 per texinfo
    "-funswitch-loops"
);

my @link_args = (
    "-Bdynamic",
  #  "-Wl,-T,$TOOLCHAIN/arm-linux-androideabi/lib/ldscripts/armelf_linux_eabi.x",
    "-Wl,-dynamic-linker,/system/bin/linker",
    "-Wl,--gc-sections",
    "-Wl,-z,nocopyreloc",
    #"-Wl,--no-undefined",
    "-Wl,-rpath-link=$ALIB",
    "-L$ALIB",
    "-nostdlib",
    "$ALIB/crtend_android.o",
    "$ALIB/crtbegin_dynamic.o",
    "$TOOLCHAIN/lib/gcc/arm-linux-androideabi/$VERSION/libgcc.a",
    "-lc",
    "-lm",
    "-ldl"
 );

# Also need: -Wl,-soname,libXXXX.so
my @shared_args = (
    "-nostdlib",
    "-Wl,-T,$TOOLCHAIN/arm-linux-androideabi/lib/ldscripts/armelf_linux_eabi.xsc",
    "-Wl,--gc-sections",
    "-Wl,-shared,-Bsymbolic",
    "-L$ALIB",
#    "-Wl,-soname,re.so",
    "-Wl,--no-whole-archive",
    "$TOOLCHAIN/lib/gcc/arm-linux-androideabi/$VERSION/libgcc.a",
   "-lc",
   "-lm",
   "-ldl",
    #"-Wl,--no-undefined",
    "-Wl,--whole-archive"); # .a, .o input files go *after* here

my @crystax_args = (
    "-I$DROID/sources/cxx-stl/gnu-libstdc++/include",
    "-I$DROID/sources/cxx-stl/gnu-libstdc++/libs/$ARCH/include",
    "-I$DROID/sources/crystax/include",

    "-L$DROID/sources/cxx-stl/gnu-libstdc++/libs/$ARCH",
    "-L$DROID/sources/crystax/libs/$ARCH",

    "-lstdc++",
    "-lcrystax");

# Now implement a quick parser for a gcc-like command line

my %MODES = ("-E"=>1, "-c"=>1, "-S"=>1, "-shared"=>1);

my $mode = "DEFAULT";
my $out;
my $warn = 0;
my $opt = 0;
my @args = ();
my $have_src = 0;
my $have_cxx = 0;
while(@ARGV) {
    my $a = shift;
    if(defined $MODES{$a}) {
	die "Can't specify $a and $mode" if $mode ne "DEFAULT";
	$mode = $a;
    } elsif($a eq "-o") {
	die "Missing -o argument" if !@ARGV;
	die "Duplicate -o argument" if defined $out;
	$out = shift;
    } elsif($a =~ /^-W.*/) {
	$warn = 1;
    } elsif($a =~ /^-O.*/) {
	$opt = 1;
    } else {
	if($a =~ /\.(c|cpp|cxx)$/i) { $have_src = 1; }
	if($a =~ /\.(cpp|cxx)$/i) { $have_cxx = 1; }
	push @args, $a;
    }
}

my $need_cpp = 0;
my $need_compile = 0;
my $need_link = 0;
my $need_shlink = 0;
my $need_crystax = 0;
if($mode eq "DEFAULT") { $need_cpp = $need_compile = $need_link = 1; }
if($mode eq "-E") { $need_cpp = 1; }
if($mode eq "-c") { $need_cpp = $need_compile = 1; }
if($mode eq "-S") { $need_cpp = $need_compile = 1; }
if($mode eq "-shared") { $need_shlink = 1; }
if($have_cxx) { $need_crystax = 1; }

if($have_src and $mode ne "-E") { $need_cpp = $need_compile = 1; }

# Assemble the command:
my @cmd = ("./arm-linux-androideabi-gcc");
@cmd = (@cmd, @args);
if($mode ne "DEFAULT") { @cmd = (@cmd, $mode); }
if($need_crystax) { @cmd = (@cmd, @crystax_args); }
if(defined $out) { @cmd = (@cmd, "-o", $out); }
if($need_cpp) { @cmd = (@cmd, @include_paths, @preprocess_args); }
if($need_compile){
    @cmd = (@cmd, @compile_args);
    if($warn) { @cmd = (@cmd, @warn_args); }
    if($opt) { @cmd = (@cmd, @optimize_args); }
}
if($need_link) { @cmd = (@cmd, @link_args); }
if($need_shlink) { @cmd = (@cmd, @shared_args); }

#print "\e[45;37;1m", join(" ", @cmd), "\e[0m\n"; # Spit i
exec(@cmd)
