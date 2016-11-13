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

#################################
######### Wichtige Hinweise und Links #################

## Beispiel für Logausgabe
# https://forum.fhem.de/index.php/topic,55756.msg508412.html#msg508412

##
#


################################


package main;

use strict;
use warnings;
use JSON;

use HttpUtils;

my $version = "0.3.15";



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

    
    my $webhookFWinstance = join( ",", devspec2array('TYPE=FHEMWEB:FILTER=TEMPORARY!=1') );
      
    # Consumer
    $hash->{SetFn}      = "NUKIBridge_Set";
    $hash->{GetFn}      = "NUKIBridge_Get";
    $hash->{DefFn}	= "NUKIBridge_Define";
    $hash->{UndefFn}	= "NUKIBridge_Undef";
    $hash->{AttrFn}	= "NUKIBridge_Attr";
    $hash->{AttrList} 	= "interval ".
                          "disable:1 ".
                          "webhookFWinstance:$webhookFWinstance ".
                          $readingFnAttributes;


    foreach my $d(sort keys %{$modules{NUKIBridge}{defptr}}) {
	my $hash = $modules{NUKIBridge}{defptr}{$d};
	$hash->{VERSION} 	= $version;
    }
}

sub NUKIBridge_Read($@) {

  my ($hash,$chash,$name,$path,$lockAction,$nukiId)= @_;
  NUKIBridge_Call($hash,$chash,$path,$lockAction,$nukiId );
  
}

sub NUKIBridge_Define($$) {

    my ( $hash, $def ) = @_;
    
    my @a = split( "[ \t][ \t]*", $def );
    

    return "too few parameters: define <name> NUKIBridge <HOST> <TOKEN>" if( @a != 4 );
    


    my $name    	= $a[0];
    my $host    	= $a[2];
    my $token           = $a[3];
    my $port		= 8080;
    my $interval  	= 60;

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
        NUKIBridge_firstRun($hash) if( ($hash->{HOST}) and ($hash->{TOKEN}) );
    } else {
        InternalTimer( gettimeofday()+15, "NUKIBridge_firstRun", $hash, 0 ) if( ($hash->{HOST}) and ($hash->{TOKEN}) );
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
		InternalTimer( gettimeofday()+2, "NUKIBridge_GetCheckBridgeAlive", $hash, 0 );
		readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
		Log3 $name, 3, "NUKIBridge ($name) - enabled";
	    } else {
		RemoveInternalTimer( $hash );
		readingsSingleUpdate($hash, 'state', 'disabled', 1 );
		Log3 $name, 3, "NUKIBridge ($name) - disabled";
            }
            
        } else {
	    RemoveInternalTimer( $hash );
	    InternalTimer( gettimeofday()+2, "NUKIBridge_GetCheckBridgeAlive", $hash, 0 );
	    readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
	    Log3 $name, 3, "NUKIBridge ($name) - enabled";
        }
    }
    
    if( $attrName eq "interval" ) {
	if( $cmd eq "set" ) {
	    if( $attrVal < 30 ) {
		Log3 $name, 3, "NUKIBridge ($name) - interval too small, please use something > 30 (sec), default is 60 (sec)";
		return "interval too small, please use something > 30 (sec), default is 60 (sec)";
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
    
    # webhook*
    if ( $attrName =~ /^webhook.*/ ) {
        my $webhookHttpHostname = (
              $attrName eq "webhookHttpHostname"
            ? $attrVal
            : AttrVal( $name, "webhookHttpHostname", "" )
        );
        my $webhookFWinstance = (
              $attrName eq "webhookFWinstance"
            ? $attrVal
            : AttrVal( $name, "webhookFWinstance", "" )
        );
        $hash->{WEBHOOK_URI} = "/"
          . AttrVal( $webhookFWinstance, "webname", "fhem" )
          . "/THINKINGCLEANER";
        $hash->{WEBHOOK_PORT} = (
              $attrName eq "webhookPort"
            ? $attrVal
            : AttrVal(
                $name, "webhookPort",
                InternalVal( $webhookFWinstance, "PORT", "" )
            )
        );

        $hash->{WEBHOOK_URL}     = "";
        $hash->{WEBHOOK_COUNTER} = "0";
        if ( $webhookHttpHostname ne "" && $hash->{WEBHOOK_PORT} ne "" ) {
            $hash->{WEBHOOK_URL} =
                "http://"
              . $webhookHttpHostname . ":"
              . $hash->{WEBHOOK_PORT}
              . $hash->{WEBHOOK_URI};

            my $cmd =
                "&h_url=$webhookHttpHostname&h_path="
              . $hash->{WEBHOOK_URI}
              . "&h_port="
              . $hash->{WEBHOOK_PORT};

            NUKIBridge_CallBlocking( $hash, "register_webhook.json", $cmd );
            $hash->{WEBHOOK_REGISTER} = "sent";
        }
        else {
            $hash->{WEBHOOK_REGISTER} = "incomplete_attributes";
        }
    }
    
    return undef;
}

sub NUKIBridge_Set($@) {

    my ($hash, $name, $cmd, @args) = @_;
    my ($arg, @params) = @args;

    
    if($cmd eq 'autocreate') {
        return "usage: autocreate" if( @args != 0 );

        NUKIBridge_firstRun($hash);

        return undef;

    } elsif($cmd eq 'statusRequest') {
        return "usage: statusRequest" if( @args != 0 );
    
        NUKIBridge_Call($hash,$hash,"info",undef,undef) if( !IsDisabled($name) );
        
        return undef;
        
    } elsif($cmd eq 'fwUpdate') {
        return "usage: fwUpdate" if( @args != 0 );
    
        NUKIBridge_CallBlocking($hash,"fwupdate",undef);
        
        return undef;
        
    } elsif($cmd eq 'reboot') {
        return "usage: reboot" if( @args != 0 );
    
        NUKIBridge_CallBlocking($hash,"reboot",undef);
        
        return undef;
        
    } elsif($cmd eq 'clearLog') {
        return "usage: clearLog" if( @args != 0 );
        
        NUKIBridge_CallBlocking($hash,"clearlog",undef);

    } else {
        my $list = "statusRequest:noArg autocreate:noArg clearLog:noArg fwUpdate:noArg reboot:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }

}

sub NUKIBridge_Get($@) {

    my ($hash, $name, $cmd, @args) = @_;
    my ($arg, @params) = @args;
    
    if($cmd eq 'logFile') {
        return "usage: logFile" if( @args != 0 );

        NUKIBridge_getLogfile($hash);
        
    } else {
        my $list = "logFile:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }

}

sub NUKIBridge_firstRun($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);
    
    NUKIBridge_Call($hash,$hash,"list",undef,undef) if( !IsDisabled($name) );
    InternalTimer( gettimeofday()+3, "NUKIBridge_GetCheckBridgeAlive", $hash, 0 );
    
    Log3 $name, 4, "NUKIBridge ($name) - Call NUKIBridge_Get" if( !IsDisabled($name) );

    return 1;
}

sub NUKIBridge_GetCheckBridgeAlive($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);
    
    if( !IsDisabled($name) ) {

        NUKIBridge_Call($hash,$hash,"info",undef,undef);
    
        InternalTimer( gettimeofday()+$hash->{INTERVAL}, "NUKIBridge_GetCheckBridgeAlive", $hash, 1 );
        Log3 $name, 4, "NUKIBridge ($name) - Call InternalTimer for NUKIBridge_GetCheckBridgeAlive";
    }
    
    return 1;
}

sub NUKIBridge_Call($$$$$) {

    my ($hash,$chash,$path,$lockAction,$nukiId,) = @_;
    
    my $name    =   $hash->{NAME};
    my $host    =   $hash->{HOST};
    my $port    =   $hash->{PORT};
    my $token   =   $hash->{TOKEN};
    
    
    
    my $uri = "http://" . $hash->{HOST} . ":" . $port;
    $uri .= "/" . $path if( defined $path);
    $uri .= "?token=" . $token if( defined($token) );
    $uri .= "&action=" . $lockActions{$lockAction} if( defined($lockAction) );
    $uri .= "&nukiId=" . $nukiId if( defined($nukiId) );


    HttpUtils_NonblockingGet(
	{
	    url        => $uri,
	    timeout    => 15,
	    hash       => $hash,
	    chash      => $chash,
	    endpoint   => $path,
	    header     => "Accept: application/json",
	    method     => "GET",
	    callback   => \&NUKIBridge_Distribution,
	}
    );
    
    Log3 $name, 4, "NUKIBridge ($name) - Send HTTP POST with URL $uri";
}

sub NUKIBridge_Distribution($$$) {

    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $doTrigger = $param->{doTrigger};
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    

    
    Log3 $name, 3, "NUKIBridge ($name) - Param Alive: $param->{alive}";
    Log3 $name, 3, "NUKIBridge ($name) - Param Code: $param->{code}";
    Log3 $name, 3, "NUKIBridge ($name) - Error: $err";
    Log3 $name, 3, "NUKIBridge ($name) - PATH: $param->{path}";
    Log3 $name, 3, "NUKIBridge ($name) - httpheader: $param->{httpheader}";
    
    
    
    
    readingsBeginUpdate($hash);
    
    if( defined( $err ) ) {

	if ( $err ne "" ) {
	
            readingsBulkUpdate( $hash, "lastError", $err );
            Log3 $name, 4, "NUKIBridge ($name) - error while requesting: $err";
            readingsEndUpdate( $hash, 1 );
            return $err;
	}
    }

    if( $json eq "" and exists( $param->{code} ) && $param->{code} ne 200 ) {
    
        readingsBulkUpdate( $hash, "lastError", "Internal error, " .$param->{code} );
	Log3 $name, 4, "NUKIBridge ($name) - received http code " .$param->{code}." without any data after requesting";

	readingsEndUpdate( $hash, 1 );
	return "received http code ".$param->{code}." without any data after requesting";
    }

    if( ( $json =~ /Error/i ) and exists( $param->{code} ) ) {    
        
        readingsBulkUpdate( $hash, "lastError", "invalid API token" ) if( $param->{code} eq 401 );
        readingsBulkUpdate( $hash, "lastError", "action is undefined" ) if( $param->{code} eq 400 and $hash == $param->{chash} );
        
        
        ###### Fehler bei Antwort auf Anfrage eines logischen Devices ######
        NUKIDevice_Parse($param->{chash},$param->{code},undef) if( $param->{code} eq 404 );
        NUKIDevice_Parse($param->{chash},$param->{code},undef) if( $param->{code} eq 400 and $hash != $param->{chash} );       
        
        
	Log3 $name, 4, "NUKIBridge ($name) - invalid API token" if( $param->{code} eq 401 );
	Log3 $name, 4, "NUKIBridge ($name) - nukiId is not known" if( $param->{code} eq 404 );
	Log3 $name, 4, "NUKIBridge ($name) - action is undefined" if( $param->{code} eq 400 and $hash == $param->{chash} );
	
	
	######### Zum testen da ich kein Nuki Smartlock habe ############
	#if ( $param->{code} eq 404 ) {
        #    if( defined($param->{chash}->{helper}{lockAction}) ) {
        #        Log3 $name, 3, "NUKIBridge ($name) - Test JSON String for lockAction";
        #        $json = '{"success": true, "batteryCritical": false}';
        #    } else {
        #        Log3 $name, 3, "NUKIBridge ($name) - Test JSON String for lockState";
        #        $json = '{"state": 1, "stateName": "locked", "batteryCritical": false, "success": "true"}';
        #    }
        #    NUKIDevice_Parse($param->{chash},$json);
        #}
        
        
        readingsEndUpdate( $hash, 1 );
	return $param->{code};
    }
    
    if( $hash == $param->{chash} ) {
    
        #$json = '[{"nukiId": 1,"name": "Home","lastKnownState": {"state": 1,"stateName": "locked","batteryCritical": false,"timestamp": "2016-10-03T06:49:00+00:00"}},{"nukiId": 2,"name": "Grandma","lastKnownState": {"state": 3,"stateName": "unlocked","batteryCritical": false,"timestamp": "2016-10-03T06:49:00+00:00"}}]' if( $param->{endpoint} eq "list" ); # zum testen da ich kein Nuki Smartlock habe
        
        NUKIBridge_ResponseProcessing($hash,$json,$param->{endpoint});
        
    } else {
    
        NUKIDevice_Parse($param->{chash},$json,$param->{endpoint});
    }
    
    readingsEndUpdate( $hash, 1 );
    return undef;
}

sub NUKIBridge_ResponseProcessing($$$) {

    my ($hash,$json,$path) = @_;
    my $name = $hash->{NAME};
    my $decode_json;
    
    
    $decode_json = decode_json($json);
    
    if( ref($decode_json) eq "ARRAY" and scalar(@{$decode_json}) > 0 and $path eq "list" ) {

        NUKIBridge_Autocreate($hash,$decode_json);
    }
    
    elsif( $path eq "info" ) {
        NUKIBridge_InfoProcessing($hash,$decode_json);
    
    } else {
        Log3 $name, 5, "NUKIDevice ($name) - Rückgabe Path nicht korrekt: $json";
        return;
    }
    
    return undef;
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
            Log3 $name, 5, "NUKIDevice ($name) - NukiId '$nukiId' already defined as '$modules{NUKIDevice}{defptr}{$code}->{NAME}'";
            next;
        }
        
        my $devname = "NUKIDevice" . $nukiId;
        my $define= "$devname NUKIDevice $nukiId IODev=$name";
        Log3 $name, 5, "NUKIDevice ($name) - create new device '$devname' for address '$nukiId'";

        my $cmdret= CommandDefine(undef,$define);
        if($cmdret) {
            Log3 $name, 1, "NUKIDevice ($name) - Autocreate: An error occurred while creating device for nukiId '$nukiId': $cmdret";
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
        Log3 $name, 2, "NUKIDevice ($name) - autocreated $autocreated devices";
        CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "created $autocreated devices";
}

sub NUKIBridge_InfoProcessing($$) {

    my ($hash,$decode_json)     = @_;
    my $name                    = $hash->{NAME};
    
    my %bridgeType = (
        '1' =>  'Hardware',
        '2' =>  'Software'
    );
    
    
    readingsBeginUpdate($hash);
    
    if( ref($decode_json->{versions}) eq "ARRAY" and scalar(@{$decode_json->{versions}}) > 0 ) {
        foreach my $versions (@{$decode_json->{versions}}) {
            readingsBulkUpdate($hash,"appVersion",$versions->{appVersion});
            readingsBulkUpdate($hash,"firmwareVersion",$versions->{firmwareVersion});
            readingsBulkUpdate($hash,"wifiFirmwareVersion",$versions->{wifiFirmwareVersion});
        }
    }
    
    readingsBulkUpdate($hash,"bridgeType",$bridgeType{$decode_json->{bridgeType}});
    readingsBulkUpdate($hash,"hardwareId",$decode_json->{ids}{hardwareId});
    readingsBulkUpdate($hash,"serverId",$decode_json->{ids}{serverId});
    readingsBulkUpdate($hash,"uptime",$decode_json->{uptime});
    readingsBulkUpdate($hash,"currentTime",$decode_json->{currentTime});
    readingsBulkUpdate($hash,"serverConnected",$decode_json->{serverConnected});
    readingsEndUpdate($hash,1);
}

sub NUKIBridge_getLogfile($) {

    my ($hash)  = @_;
    my $name    = $hash->{NAME};

    
    my $decode_json = NUKIBridge_CallBlocking($hash,"log",undef);
    
    Log3 $name, 3, "NUKIBridge ($name) - Kurz vor der Bedingung nach decode_json ARRAY";

    
    if( ref($decode_json) eq "ARRAY" and scalar(@{$decode_json}) > 0 ) {
        Log3 $name, 3, "NUKIBridge ($name) - Innerhalb der ARRAY Bedingung";
    
        my $ret = '<html><table width=100%><tr><td>';

        $ret .= '<table class="block wide">';

            $ret .= '<tr class="odd">';
            $ret .= "<td><b>Timestamp</b></td>";
            $ret .= "<td><b>Type</b></td>";
            $ret .= '</tr>';
    
        foreach my $logs (@{$decode_json}) {
        
            $ret .= "<td>$logs->{timestamp}</td>";
            $ret .= "<td>$logs->{type}</td>";
            $ret .= '</tr>';
        }
    
        $ret .= '</table></td></tr>';
        $ret .= '</table></html>';
     
        return $ret;
    }
}

sub NUKIBridge_CallBlocking($$$) {

    my ($hash,$path,$obj)  = @_;
    my $name    = $hash->{NAME};
    my $host    = $hash->{HOST};
    my $port    = $hash->{PORT};
    my $token   = $hash->{TOKEN};
    
    my $url = "http://" . $hash->{HOST} . ":" . $port;
    $url .= "/" . $path if( defined $path);
    $url .= "?token=" . $token if( defined($token) );
    
    
    my($err,$data)  = HttpUtils_BlockingGet({
      url           => $url,
      timeout       => 3,
      method        => "GET",
      header        => "Content-Type: application/json",
    });

    if( !$data ) {
      Log3 $name, 3, "NUKIDevice ($name) - empty answer received for $url";
      return undef;
    } elsif( $data =~ m'HTTP/1.1 200 OK' ) {
      Log3 $name, 4, "NUKIDevice ($name) - empty answer received for $url";
      return undef;
    } elsif( $data !~ m/^[\[{].*[\]}]$/ ) {
      Log3 $name, 3, "NUKIDevice ($name) - invalid json detected for $url: $data";
      return undef;
    }

    
    my $decode_json = decode_json($data);

    return undef if( !$decode_json );
    
    Log3 $name, 3, "NUKIBridge ($name) - Blocking HTTP Abfrage beendet";
    return ($decode_json);
}

sub NUKIBridge_CGI() {
    my ($request) = @_;

    # data received
    if ( defined( $FW_httpheader{UUID} ) ) {
        if ( defined( $modules{NUKIDevice}{defptr} ) ) {
            while ( my ( $key, $value ) =
                each %{ $modules{NUKIDevice}{defptr} } )
            {

                my $uuid = ReadingsVal( $key, "uuid", undef );
                next if ( !$uuid || $uuid ne $FW_httpheader{UUID} );

                $defs{$key}{WEBHOOK_COUNTER}++;
                $defs{$key}{WEBHOOK_LAST} = TimeNow();

                Log3 $key, 4,
"THINKINGCLEANER $key: Received webhook for matching UUID at device $key";

                my $delay = undef;

# we need some delay as to the Robo seems to send webhooks but it's status does
# not really reflect the change we'd expect to get here already so give 'em some
# more time to think about it...
                $delay = "2"
                  if ( defined( $defs{$key}{LAST_COMMAND} )
                    && time() - time_str2num( $defs{$key}{LAST_COMMAND} ) < 3 );

                #THINKINGCLEANER_GetStatus( $defs{$key}, $delay );
                last;
            }
        }

        return ( undef, undef );
    }

    # no data received
    else {
        Log3 undef, 5, "THINKINGCLEANER: received malformed request\n$request";
    }

    return ( "text/plain; charset=utf-8", "Call failure: " . $request );
}











1;




=pod
=item device
=item summary    Modul to control the Nuki Smartlock's over the Nuki Bridge.
=item summary_DE Modul zur Steuerung des Nuki Smartlock über die Nuki Bridge.

=begin html

<a name="NUKIBridge"></a>
<h3>NUKIBridge</h3>
<ul>
  <u><b>NUKIBridge - controls the Nuki Smartlock over the Nuki Bridge</b></u>
  <br>
  The Nuki Bridge module connects FHEM to the Nuki Bridge and then reads all the smartlocks available on the bridge. Furthermore, the detected Smartlocks are automatically created as independent devices.
  <br><br>
  <a name="NUKIBridgedefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name&gt; NUKIBridge &lt;HOST&gt; &lt;API-TOKEN&gt;</code>
    <br><br>
    Example:
    <ul><br>
      <code>define NBridge1 NUKIBridge 192.168.0.23 F34HK6</code><br>
    </ul>
    <br>
    This statement creates a NUKIBridge device with the name NBridge1 and the IP 192.168.0.23 as well as the token F34HK6.<br>
    After the bridge device is created, all available Smartlocks are automatically placed in FHEM.
  </ul>
  <br><br>
  <a name="NUKIBridgereadings"></a>
  <b>Readings</b>
  <ul>
    <li>0_nukiId - ID of the first found Nuki Smartlock</li>
    <li>0_name - Name of the first found Nuki Smartlock</li>
    <li>smartlockCount - number of all found Smartlocks</li>
    <li>bridgeAPI - API Version of bridge</li>
    <br>
    The preceding number is continuous, starts with 0 und returns the properties of <b>one</b> Smartlock.
   </ul>
  <br><br>
  <a name="NUKIBridgeset"></a>
  <b>Set</b>
  <ul>
    <li>autocreate - Prompts to re-read all Smartlocks from the bridge and if not already present in FHEM, create the autimatic.</li>
    <li>statusRequest - starts a checkAlive of the bridge, it is determined whether the bridge is still online</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeattribut"></a>
  <b>Attributes</b>
  <ul>
    <li>disable - disables the Nuki Bridge</li>
    <li>interval - changes the interval for the CheckAlive</li>
    <br>
  </ul>
</ul>

=end html
=begin html_DE

<a name="NUKIBridge"></a>
<h3>NUKIBridge</h3>
<ul>
  <u><b>NUKIBridge - Steuert das Nuki Smartlock über die Nuki Bridge</b></u>
  <br>
  Das Nuki Bridge Modul verbindet FHEM mit der Nuki Bridge und liest dann alle auf der Bridge verfügbaren Smartlocks ein. Desweiteren werden automatisch die erkannten Smartlocks als eigenst&auml;ndige Devices an gelegt.
  <br><br>
  <a name="NUKIBridgedefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name&gt; NUKIBridge &lt;HOST&gt; &lt;API-TOKEN&gt;</code>
    <br><br>
    Beispiel:
    <ul><br>
      <code>define NBridge1 NUKIBridge 192.168.0.23 F34HK6</code><br>
    </ul>
    <br>
    Diese Anweisung erstellt ein NUKIBridge Device mit Namen NBridge1 und der IP 192.168.0.23 sowie dem Token F34HK6.<br>
    Nach dem anlegen des Bridge Devices werden alle zur verf&uuml;gung stehende Smartlock automatisch in FHEM an gelegt.
  </ul>
  <br><br>
  <a name="NUKIBridgereadings"></a>
  <b>Readings</b>
  <ul>
    <li>0_nukiId - ID des ersten gefundenen Nuki Smartlocks</li>
    <li>0_name - Name des ersten gefunden Nuki Smartlocks</li>
    <li>smartlockCount - Anzahl aller gefundenen Smartlock</li>
    <li>bridgeAPI - API Version der Bridge</li>
    <br>
    Die vorangestellte Zahl ist forlaufend und gibt beginnend bei 0 die Eigenschaften <b>Eines</b> Smartlocks wieder.
  </ul>
  <br><br>
  <a name="NUKIBridgeset"></a>
  <b>Set</b>
  <ul>
    <li>autocreate - Veranlasst ein erneutes Einlesen aller Smartlocks von der Bridge und falls noch nicht in FHEM vorhanden das autimatische anlegen.</li>
    <li>statusRequest - startet einen checkAlive der Bridge, es wird festgestellt ob die Bridge noch online ist</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeattribut"></a>
  <b>Attribute</b>
  <ul>
    <li>disable - deaktiviert die Nuki Bridge</li>
    <li>interval - verändert den Interval für den CheckAlive</li>
    <br>
  </ul>
</ul>

=end html_DE
=cut