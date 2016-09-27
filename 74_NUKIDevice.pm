###############################################################################
# 
# Developed with Kate
#
#  (c) 2016 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
# $Id$
#
###############################################################################


package main;

use strict;
use warnings;
use JSON;
use Time::HiRes qw(gettimeofday);

my $version = "0.1.37";




sub NUKIDevice_Initialize($) {

    my ($hash) = @_;

    $hash->{SetFn}	    = "NUKIDevice_Set";
    $hash->{DefFn}	    = "NUKIDevice_Define";
    $hash->{UndefFn}	    = "NUKIDevice_Undef";
    $hash->{AttrFn}	    = "NUKIDevice_Attr";
    
    $hash->{AttrList} 	    = "IODev ".
                              "disable:1 ".
                               $readingFnAttributes;



    foreach my $d(sort keys %{$modules{NUKIDevice}{defptr}}) {
	my $hash = $modules{NUKIDevice}{defptr}{$d};
	$hash->{VERSION} 	= $version;
    }
}

sub NUKIDevice_Define($$) {

    my ( $hash, $def ) = @_;
    
    my @a = split( "[ \t]+", $def );
    splice( @a, 1, 1 );
    my $iodev;
    my $i = 0;
    
    foreach my $param ( @a ) {
        if( $param =~ m/IODev=([^\s]*)/ ) {
            $iodev = $1;
            splice( @a, $i, 3 );
            last;
        }
        
        $i++;
    }

    return "too few parameters: define <name> NUKIDevice <nukiId>" if( @a < 2 );

    my ($name,$nukiId)  = @a;

    $hash->{NUKIID} 	= $nukiId;
    $hash->{VERSION} 	= $version;
    $hash->{STATE}      = 'Initialized';
    $hash->{INTERVAL}   = 30;
    
    
    AssignIoPort($hash,$iodev) if( !$hash->{IODev} );
    
    if(defined($hash->{IODev}->{NAME})) {
    
        Log3 $name, 3, "$name: I/O device is " . $hash->{IODev}->{NAME};
    } else {
    
        Log3 $name, 1, "$name: no I/O device";
    }
    
    $iodev = $hash->{IODev}->{NAME};

    
    my $code = $hash->{NUKIID};
    $code = $iodev ."-". $code if( defined($iodev) );
    my $d = $modules{NUKIDevice}{defptr}{$code};
    return "NUKIDevice device $hash->{NUKIID} on NUKIBridge $iodev already defined as $d->{NAME}."
        if( defined($d)
            && $d->{IODev} == $hash->{IODev}
            && $d->{NAME} ne $name );

    $modules{NUKIDevice}{defptr}{$code} = $hash;
  
  
    Log3 $name, 3, "NUKIDevice ($name) - defined with Code: $code";

    $attr{$name}{room} = "NUKI" if( !defined( $attr{$name}{room} ) );
    
    
    RemoveInternalTimer($hash);
    
    if( $init_done ) {
        NUKIDevice_GetUpdateInternalTimer($hash);
    } else {
        InternalTimer(gettimeofday()+20, "NUKIDevice_GetUpdateInternalTimer", $hash, 0);
    }

    return undef;
}

sub NUKIDevice_Undef($$) {

    my ( $hash, $arg ) = @_;
    
    my $nukiId = $hash->{NUKIID};
    my $name = $hash->{NAME};
    
    
    RemoveInternalTimer($hash);

    my $code = $hash->{NUKIID};
    $code = $hash->{IODev}->{NAME} ."-". $code if( defined($hash->{IODev}->{NAME}) );
    Log3 $name, 3, "NUKIDevice ($name) - undefined with Code: $code";
    delete($modules{HUEDevice}{defptr}{$code});

    return undef;
}

sub NUKIDevice_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};

    if( $attrName eq "disable" ) {
	if( $cmd eq "set" ) {
	    if( $attrVal eq "0" ) {
		RemoveInternalTimer( $hash );
		InternalTimer( gettimeofday()+2, "NUKIDevice_GetUpdate", $hash, 0 ) if( ReadingsVal( $hash->{NAME}, "state", 0 ) eq "disabled" );
		readingsSingleUpdate ( $hash, "state", "initialized", 1 );
		Log3 $name, 3, "NUKIDevice ($name) - enabled";
	    } else {
		readingsSingleUpdate ( $hash, "state", "disabled", 1 );
		RemoveInternalTimer( $hash );
		Log3 $name, 3, "NUKIDevice ($name) - disabled";
	    }
	    
	} else {
	
	    RemoveInternalTimer( $hash );
	    InternalTimer( gettimeofday()+2, "NUKIDevice_GetUpdate", $hash, 0 ) if( ReadingsVal( $hash->{NAME}, "state", 0 ) eq "disabled" );
	    readingsSingleUpdate ( $hash, "state", "initialized", 1 );
	    Log3 $name, 3, "NUKIDevice ($name) - enabled";
        }
    }
    
    if( $attrName eq "interval" ) {
	if( $cmd eq "set" ) {
	    if( $attrVal < 10 ) {
		Log3 $name, 3, "NUKIDevice ($name) - interval too small, please use something > 10 (sec), default is 30 (sec)";
		return "interval too small, please use something > 10 (sec), default is 60 (sec)";
	    } else {
		$hash->{INTERVAL} = $attrVal;
		Log3 $name, 3, "NUKIDevice ($name) - set interval to $attrVal";
	    }
	    
	} else {
	
	    $hash->{INTERVAL} = 30;
	    Log3 $name, 3, "NUKIDevice ($name) - set interval to default";
        }
    }
    
    return undef;
}

sub NUKIDevice_Set($$@) {
    
    my ($hash, $name, @aa) = @_;
    my ($cmd, @args) = @aa;

    my $lockAction;


    if( $cmd eq 'statusRequest' ) {
        return "usage: statusRequest" if( @args != 0 );

        NUKIDevice_GetUpdate($hash);
        return undef;
        
    } elsif( $cmd eq 'lock' ) {
        $lockAction = $cmd;
    
    } elsif( $cmd eq 'unlock' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'unlatch' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'locknGo' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'locknGoWithUnlatch' ) {
        $lockAction = $cmd;
        
    
    } else {
        my $list = "statusRequest:noArg unlock:noArg lock:noArg unlatch:noArg locknGo:noArg locknGoWithUnlatch:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }
    
    my $result = NUKIDevice_ReadFromNUKIBridge($hash,"lockAction",$lockAction,$hash->{NUKIID} );
    
    if( !defined($result) ) {
    
        $hash->{STATE} = "unknown";
        Log3 $name, 3, "NUKIDevice ($name) - unknown result to ReadFromNUKIBridge";
        return;
        
    } else {
    
        NUKIDevice_Parse($hash,$result);
        Log3 $name, 3, "NUKIDevice ($name) - Call NUKIDevice_Parse";
    }
}

sub NUKIDevice_GetUpdate($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    
    Log3 $name, 3, "NUKIBridge ($name) - Call NUKIBridge_GetUpdate";
    
    my $result = NUKIDevice_ReadFromNUKIBridge($hash, "lockState", undef, $hash->{NUKIID} );
    
    if( !defined($result) ) {
    
        $hash->{STATE} = "unknown";
        Log3 $name, 3, "NUKIDevice ($name) - unknown result to ReadFromNUKIBridge";
        return;
        
    } else {
    
        NUKIDevice_Parse($hash,$result);
        Log3 $name, 3, "NUKIDevice ($name) - Call NUKIDevice_Parse";
    }
}

sub NUKIDevice_GetUpdateInternalTimer($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    
    NUKIDevice_GetUpdate($hash);
    Log3 $name, 3, "NUKIDevice ($name) - Call NUKIDevice_GetUpdate";
    
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "NUKIDevice_GetUpdateInternalTimer", $hash, 0) if( $hash->{INTERVAL} );
    Log3 $name, 3, "NUKIDevice ($name) - Call InternalTimer";
}

sub NUKIDevice_ReadFromNUKIBridge($@) {

    my ($hash,@a) = @_;
    my $name = $hash->{NAME};
    
    no strict "refs";
    my $ret;
    unshift(@a,$name);
    
    $ret = IOWrite($hash,$hash,@a);
    use strict "refs";
    return $ret;
    return if(IsDummy($name) || IsIgnored($name));
    my $iohash = $hash->{IODev};
    
    if(!$iohash ||
        !$iohash->{TYPE} ||
        !$modules{$iohash->{TYPE}} ||
        !$modules{$iohash->{TYPE}}{ReadFn}) {
        Log3 $name, 5, "No I/O device or ReadFn found for $name";
        return;
    }

    no strict "refs";
    unshift(@a,$name);
    $ret = &{$modules{$iohash->{TYPE}}{ReadFn}}($iohash, @a);
    use strict "refs";
    return $ret;
}

sub NUKIDevice_Parse($$) {

    my($hash,$result) = @_;
    my $name = $hash->{NAME};


    my $decode_json = decode_json($result);
    
    if( ref($decode_json) ne "HASH" ) {
        Log3 $name, 2, "$name: got wrong status message for $name: $decode_json";
        return undef;
    }

    Log3 $name, 3, "parse status message for $name";
    
    
    ############################
    #### Status des Smartkey
    my $battery;
    if( $decode_json->{batteryCritical} eq "false" ) {
        $battery = "ok";
    } else {
        $battery = "low";
    }
    
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "state", $decode_json->{stateName} );
    readingsBulkUpdate( $hash, "battery", $battery );
    readingsBulkUpdate( $hash, "success", $decode_json->{success} );
    readingsEndUpdate( $hash, 1 );
    
    
    Log3 $name, 3, "readings set for $name";
}



1;




=pod
=begin html

<a name="Nuki"></a>
<h3>NUKIDevice</h3>
<ul>
  
</ul>

=end html
=begin html_DE

<a name="Nuki"></a>
<h3>NUKIDevice</h3>
<ul>
  
</ul>

=end html_DE
=cut