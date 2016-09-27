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
use HttpUtils;

my $version = "0.1.35";



my %lockActions = (
    'unlock'                => 1,
    'lock'                  => 2,
    'unlatch'               => 3,
    'locknGo'               => 4,
    'locknGoWithUnlatch'    => 5
);


sub NUKIBridge_Initialize($) {

    my ($hash) = @_;
    
    # Provider
    $hash->{ReadFn}     = "NUKIBridge_Read";
    $hash->{WriteFn}    = "NUKIBridge_Read";
    $hash->{Clients}    = ":NUKIDevice:";

    # Consumer
    $hash->{SetFn}      = "NUKIBridge_Set";
    #$hash->{NotifyFn}   = "NUKIBridge_Notify";
    $hash->{DefFn}	= "NUKIBridge_Define";
    $hash->{UndefFn}	= "NUKIBridge_Undef";
    $hash->{AttrFn}	= "NUKIBridge_Attr";
    $hash->{AttrList} 	= "interval ".
                          "disable:1 ".
                          $readingFnAttributes;


    foreach my $d(sort keys %{$modules{NUKIBridge}{defptr}}) {
	my $hash = $modules{NUKIBridge}{defptr}{$d};
	$hash->{VERSION} 	= $version;
    }
}

sub NUKIBridge_Read($@) {

  my ($hash,$chash,$name,$path,$lockAction,$nukiId)= @_;

  return NUKIBridge_Call($hash,$chash,$path,$lockAction,$nukiId );
}

sub NUKIBridge_Define($$) {

    my ( $hash, $def ) = @_;
    
    my @a = split( "[ \t][ \t]*", $def );
    

    return "too few parameters: define <name> NUKIBridge <HOST> <TOKEN>" if( @a != 4 );
    


    my $name    	= $a[0];
    my $host    	= $a[2];
    my $token           = $a[3];
    my $port		= 8080;
    my $interval  	= 180;

    $hash->{HOST} 	= $host;
    $hash->{PORT} 	= $port;
    $hash->{TOKEN} 	= $token;
    $hash->{INTERVAL} 	= $interval;
    $hash->{VERSION} 	= $version;
    


    Log3 $name, 3, "NUKIBridge ($name) - defined with host $host on port $port, Token $token";

    $attr{$name}{room} = "NUKI" if( !defined( $attr{$name}{room} ) );
    readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
    
    RemoveInternalTimer($hash);
    
    if( $init_done ) {
        NUKIDevice_GetUpdate($hash);
    } else {
        InternalTimer( gettimeofday()+15, "NUKIBridge_GetUpdate", $hash, 0 ) if( ($hash->{HOST}) and ($hash->{TOKEN}) );
    }

    $modules{NUKIBridge}{defptr}{$hash->{HOST}} = $hash;
    
    return undef;
}

sub NUKIBridge_Undef($$) {

    my ( $hash, $arg ) = @_;
    
    my $host = $hash->{HOST};
    my $name = $hash->{NAME};
    
    RemoveInternalTimer( $hash );
    
    delete $modules{NUKIBridge}{defptr}{$hash->{HOST}};
    
    return undef;
}

sub NUKIBridge_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
    
    my $orig = $attrVal;

    if( $attrName eq "disable" ) {
	if( $cmd eq "set" ) {
	    if( $attrVal eq "0" ) {
		RemoveInternalTimer( $hash );
		InternalTimer( gettimeofday()+2, "NUKIBridge_GetUpdate", $hash, 0 );
		readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
		Log3 $name, 3, "NUKIBridge ($name) - enabled";
	    } else {
		RemoveInternalTimer( $hash );
		readingsSingleUpdate($hash, 'state', 'disabled', 1 );
		Log3 $name, 3, "NUKIBridge ($name) - disabled";
            }
            
        } else {
	    RemoveInternalTimer( $hash );
	    InternalTimer( gettimeofday()+2, "NUKIBridge_GetUpdate", $hash, 0 );
	    readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
	    Log3 $name, 3, "NUKIBridge ($name) - enabled";
        }
    }
    
    if( $attrName eq "interval" ) {
	if( $cmd eq "set" ) {
	    if( $attrVal < 10 ) {
		Log3 $name, 3, "NUKIBridge ($name) - interval too small, please use something > 10 (sec), default is 60 (sec)";
		return "interval too small, please use something > 10 (sec), default is 60 (sec)";
	    } else {
		$hash->{INTERVAL} = $attrVal;
		Log3 $name, 3, "NUKIBridge ($name) - set interval to $attrVal";
	    }
	}
	elsif( $cmd eq "del" ) {
	    $hash->{INTERVAL} = 60;
	    Log3 $name, 3, "NUKIBridge ($name) - set interval to default";
	
	} else {
	    if( $cmd eq "set" ) {
		$attr{$name}{$attrName} = $attrVal;
		Log3 $name, 3, "NUKIBridge ($name) - $attrName : $attrVal";
	    }
	}
    }
    
    return undef;
}

sub NUKIBridge_Set($@) {

    my ($hash, $name, $cmd, @args) = @_;
    my ($arg, @params) = @args;

    
    if($cmd eq 'statusRequest') {
        return "usage: statusRequest" if( @args != 0 );

        $hash->{LOCAL} = 1;
        NUKIBridge_Get($hash);
        delete $hash->{LOCAL};
        return undef;

    } elsif($cmd eq 'other') {
        
    } elsif($cmd eq 'other2') {

    } else {
        my $list = "statusRequest:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }

}

sub NUKIBridge_Get($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    NUKIBridge_Call($hash,$hash,"list",undef,undef) if( !IsDisabled($name) );

    Log3 $name, 3, "NUKIBridge ($name) - Call NUKIBridge_Get" if( !IsDisabled($name) );

    return 1;
}

sub NUKIBridge_GetUpdate($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    
    if( !IsDisabled($name) ) {
    
        #RemoveInternalTimer($hash);
        NUKIBridge_Call($hash,$hash,"list",undef,undef);
        #InternalTimer( gettimeofday()+$hash->{INTERVAL}, "NUKIBridge_GetUpdate", $hash, 1 );
        Log3 $name, 3, "NUKIBridge ($name) - Call NUKIBridge_GetUpdate";
    }
    return 1;
}

sub NUKIBridge_Call($$$$$;$) {

    my ($hash,$chash,$path,$lockAction,$nukiId,$method) = @_;
    
    my $name    =   $hash->{NAME};
    my $host    =   $hash->{HOST};
    my $port    =   $hash->{PORT};
    my $token   =   $hash->{TOKEN};
    
    my $uri = "http://" . $hash->{HOST} . ":" . $port;
    $uri .= "/" . $path if( defined $path);
    $uri .= "?token=" . $token if( defined($token) );
    $uri .= "&action=" . $lockActions{$lockAction} if( defined($lockAction) );
    $uri .= "&nukiId=" . $nukiId if( $path ne "list" and defined($nukiId) );
    
    $method = 'GET' if( !$method );


    HttpUtils_NonblockingGet(
	{
	    url		=> $uri,
	    timeout	=> 10,
	    hash	=> $hash,
	    chash       => $chash,
	    method	=> $method,
	    header      => "Content-Type: application/json",
	    doTrigger	=> 1,
	    noshutdown  => 1,
	    callback	=> \&NUKIBridge_dispatch,
	}
    );
    
    Log3 $name, 3, "NUKIBridge ($name) - Send HTTP POST with URL $uri";

    #readingsSingleUpdate( $hash, "state", $state, 1 );

    return undef;
}

sub NUKIBridge_dispatch($$$) {

    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $doTrigger = $param->{doTrigger};
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    
    
    if( defined( $err ) ) {
	if( $err ne "" ) {
	
	Log3 $name, 3, "NUKIBridge ($name) - error while requesting: $err";
	
	return;
	}
    }

    if( $json eq "" and exists( $param->{code} ) && $param->{code} ne 200 ) {
    
	Log3 $name, 3, "NUKIBridge ($name) - statusRequestERROR: received http code ".$param->{code}." without any data after requesting";

	return;
    }

    if( ( $json =~ /Error/i ) and exists( $param->{code} ) ) {    
    
	Log3 $name, 3, "NUKIBridge ($name) - invalid API token" if( $param->{code} eq 401 );
	Log3 $name, 3, "NUKIBridge ($name) - nukiId is not known" if( $param->{code} eq 404 );
	Log3 $name, 3, "NUKIBridge ($name) - action is undefined" if( $param->{code} eq 400 );
	
	
	######### Zum testen da ich kein Nuki Smartkey habe ############
	#if ( $param->{code} eq 404 ) {
        #    Log3 $name, 3, "NUKIBridge ($name) - Test JSON String";
        #    $json = '{"state": 1, "stateName": "locked", "batteryCritical": false, "success": "true"}';
        #    NUKIDevice_Parse($param->{chash},$json);
        #}

        
	return;
    }
    
    
    if( $hash == $param->{chash} ) {
    
        #$json = '[{"nukiId": 1, "name": "Home"}, {"nukiId": 2, "name": "Grandma"}]';        # zum testen da ich kein Nuki Smartkey habe
        
        NUKIBridge_ResponseProcessing($hash,$json);
        
    } else {
    
        NUKIDevice_Parse($param->{chash},$json);
    }
}

sub NUKIBridge_ResponseProcessing($$) {

    my ( $hash, $json ) = @_;
    my $name = $hash->{NAME};
    my $decode_json;
    
    
    $decode_json = decode_json($json);
    
    if( ref($decode_json) eq "ARRAY" and scalar(@{$decode_json}) > 0 ) {
    
        NUKIBridge_Autocreate($hash,$decode_json);
    
    } else {
        return $json;
    }

}

sub NUKIBridge_Autocreate($$;$) {

    my ($hash,$decode_json,$force)= @_;
    my $name = $hash->{NAME};

    if( !$force ) {
        foreach my $d (keys %defs) {
            next if($defs{$d}{TYPE} ne "autocreate");
            return undef if(AttrVal($defs{$d}{NAME},"disable",undef));
        }
    }

    my $autocreated = 0;
    my $nukiSmartlock;
    my $nukiId;
    my $nukiName;
    
    readingsBeginUpdate($hash);
    
    foreach $nukiSmartlock (@{$decode_json}) {
        
        $nukiId     = $nukiSmartlock->{nukiId};
        $nukiName   = $nukiSmartlock->{name};
        
        
        my $code = $name ."-".$nukiId;
        if( defined($modules{NUKIDevice}{defptr}{$code}) ) {
            Log3 $name, 3, "$name: NukiId '$nukiId' already defined as '$modules{NUKIDevice}{defptr}{$code}->{NAME}'";
            next;
        }
        
        my $devname = "NUKIDevice" . $nukiId;
        my $define= "$devname NUKIDevice $nukiId IODev=$name";
        Log3 $name, 3, "$name: create new device '$devname' for address '$nukiId'";

        my $cmdret= CommandDefine(undef,$define);
        if($cmdret) {
            Log3 $name, 1, "($name) Autocreate: An error occurred while creating device for nukiId '$nukiId': $cmdret";
        } else {
            $cmdret= CommandAttr(undef,"$devname alias $nukiName");
            $cmdret= CommandAttr(undef,"$devname room NUKI");
            $cmdret= CommandAttr(undef,"$devname IODev $name");
        }

        $defs{$devname}{helper}{fromAutocreate} = 1 ;
        
        readingsBulkUpdate( $hash, "${autocreated}_nukiId", $nukiId );
        readingsBulkUpdate( $hash, "${autocreated}_name", $nukiName );
        
        $autocreated++;
        
        readingsBulkUpdate( $hash, "smartlockCount", $autocreated );
    }
    
    readingsEndUpdate( $hash, 1 );
    
    
    if( $autocreated ) {
        Log3 $name, 2, "$name: autocreated $autocreated devices";
        CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "created $autocreated devices";
}

1;




=pod
=begin html

<a name="Nuki"></a>
<h3>NUKI</h3>
<ul>
  
</ul>

=end html
=begin html_DE

<a name="Nuki"></a>
<h3>NUKI</h3>
<ul>
  
</ul>

=end html_DE
=cut