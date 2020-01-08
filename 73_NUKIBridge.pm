###############################################################################
# 
# Developed with Kate
#
#  (c) 2016-2020 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
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

my $version     = "0.7.3";
my $bridgeapi   = "1.9";



my %lockActionsSmartLock = (
    'unlock'                   => 1,
    'lock'                     => 2,
    'unlatch'                  => 3,
    'locknGo'                  => 4,
    'locknGoWithUnlatch'       => 5
);

my %lockActionsOpener = (
    'activateRto'              => 1,
    'deactivateRto'            => 2,
    'electricStrikeActuation'  => 3,
    'activateContinuousMode'   => 4,
    'deactivateContinuousMode' => 5
);


# Declare functions
sub NUKIBridge_Initialize ($);
sub NUKIBridge_Define ($$);
sub NUKIBridge_Undef ($$);
sub NUKIBridge_Read($@);
sub NUKIBridge_Attr(@);
sub NUKIBridge_addExtension($$$);
sub NUKIBridge_removeExtension($);
sub NUKIBridge_Set($@);
sub NUKIBridge_Get($@);
sub NUKIBridge_GetCheckBridgeAlive($);
sub NUKIBridge_firstRun($);
sub NUKIBridge_Call($$$$$$);
sub NUKIBridge_Distribution($$$);
sub NUKIBridge_ResponseProcessing($$$);
sub NUKIBridge_CGI();
sub NUKIBridge_Autocreate($$;$);
sub NUKIBridge_InfoProcessing($$);
sub NUKIBridge_getLogfile($);
sub NUKIBridge_getCallbackList($);
sub NUKIBridge_CallBlocking($$$);





sub NUKIBridge_Initialize($) {

    my ($hash) = @_;

    # Provider
    $hash->{WriteFn}    = "NUKIBridge_Call";
    $hash->{Clients}    = ':NUKIDevice:';
    $hash->{MatchList}  = { '1:NUKIDevice' => '^{"deviceType".*' };

    my $webhookFWinstance   = join( ",", devspec2array('TYPE=FHEMWEB:FILTER=TEMPORARY!=1') );
      
    # Consumer
    $hash->{SetFn}      = "NUKIBridge_Set";
    $hash->{GetFn}      = "NUKIBridge_Get";
    $hash->{DefFn}      = "NUKIBridge_Define";
    $hash->{UndefFn}    = "NUKIBridge_Undef";
    $hash->{AttrFn}     = "NUKIBridge_Attr";
    $hash->{AttrList}   = "disable:1 ".
                          "webhookFWinstance:$webhookFWinstance ".
                          "webhookHttpHostname ".
                          $readingFnAttributes;


    foreach my $d(sort keys %{$modules{NUKIBridge}{defptr}}) {
        my $hash = $modules{NUKIBridge}{defptr}{$d};
        $hash->{VERSION} 	= $version;
    }
}

sub NUKIBridge_Read($@) {

  my ($hash,$chash,$name,$path,$lockAction,$nukiId,$deviceType)= @_;
  NUKIBridge_Call($hash,$chash,$path,$lockAction,$nukiId,$deviceType );
  
}

sub NUKIBridge_Define($$) {

    my ( $hash, $def ) = @_;
    
    my @a = split( "[ \t][ \t]*", $def );
    

    return "too few parameters: define <name> NUKIBridge <HOST> <TOKEN>" if( @a != 4 );
    


    my $name            = $a[0];
    my $host            = $a[2];
    my $token           = $a[3];
    my $port            = 8080;

    $hash->{HOST}       = $host;
    $hash->{PORT}       = $port;
    $hash->{TOKEN}      = $token;
    $hash->{VERSION}    = $version;
    $hash->{BRIDGEAPI}  = $bridgeapi;
    $hash->{helper}{aliveCount} = 0;
    my $infix = "NUKIBridge";
    


    Log3 $name, 3, "NUKIBridge ($name) - defined with host $host on port $port, Token $token";

    $attr{$name}{room} = "NUKI" if( !defined( $attr{$name}{room} ) );
    
    if ( NUKIBridge_addExtension( $name, "NUKIBridge_CGI", $infix . "-" . $host ) ) {
        $hash->{fhem}{infix} = $infix;
    }

    $hash->{WEBHOOK_REGISTER} = "unregistered";
    
    readingsSingleUpdate($hash, 'state', 'Initialized', 1 );
    
    RemoveInternalTimer($hash);
    
    if( $init_done ) {
        NUKIBridge_firstRun($hash) if( ($hash->{HOST}) and ($hash->{TOKEN}) );
    } else {
        InternalTimer( gettimeofday()+15, 'NUKIBridge_firstRun', $hash, 0 ) if( ($hash->{HOST}) and ($hash->{TOKEN}) );
    }

    $modules{NUKIBridge}{defptr}{$hash->{HOST}} = $hash;
    
    return undef;
}

sub NUKIBridge_Undef($$) {

    my ( $hash, $arg ) = @_;
    
    my $host = $hash->{HOST};
    my $name = $hash->{NAME};
    
    if ( defined( $hash->{fhem}{infix} ) ) {
        NUKIBridge_removeExtension( $hash->{fhem}{infix} );
    }
    
    RemoveInternalTimer( $hash );
    
    delete $modules{NUKIBridge}{defptr}{$hash->{HOST}};
    
    return undef;
}

sub NUKIBridge_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
    
    my $orig = $attrVal;

    
    if( $attrName eq "disable" ) {
        if( $cmd eq "set" and $attrVal eq "1" ) {
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
            Log3 $name, 3, "NUKIBridge ($name) - disabled";
        }

        elsif( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "NUKIBridge ($name) - enabled";
        }
    }
    
    if( $attrName eq "disabledForIntervals" ) {
        if( $cmd eq "set" ) {
            Log3 $name, 3, "NUKIBridge ($name) - enable disabledForIntervals";
            readingsSingleUpdate ( $hash, "state", "Unknown", 1 );
        }

        elsif( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "NUKIBridge ($name) - delete disabledForIntervals";
        }
    }
    
    ######################
    #### webhook #########
    
    return "Invalid value for attribute $attrName: can only by FQDN or IPv4 or IPv6 address" if ( $attrVal && $attrName eq "webhookHttpHostname" && $attrVal !~ /^([A-Za-z_.0-9]+\.[A-Za-z_.0-9]+)|[0-9:]+$/ );

    return "Invalid value for attribute $attrName: FHEMWEB instance $attrVal not existing" if ( $attrVal && $attrName eq "webhookFWinstance" && ( !defined( $defs{$attrVal} ) || $defs{$attrVal}{TYPE} ne "FHEMWEB" ) );

    return "Invalid value for attribute $attrName: needs to be an integer value" if ( $attrVal && $attrName eq "webhookPort" && $attrVal !~ /^\d+$/ );
    
    
    
    
    if ( $attrName =~ /^webhook.*/ ) {
    
        my $webhookHttpHostname = ( $attrName eq "webhookHttpHostname" ? $attrVal : AttrVal( $name, "webhookHttpHostname", "" ) );
        my $webhookFWinstance = ( $attrName eq "webhookFWinstance" ? $attrVal : AttrVal( $name, "webhookFWinstance", "" ) );
        
        $hash->{WEBHOOK_URI} = "/" . AttrVal( $webhookFWinstance, "webname", "fhem" ) . "/NUKIBridge" . "-" . $hash->{HOST};
        $hash->{WEBHOOK_PORT} = ( $attrName eq "webhookPort" ? $attrVal : AttrVal( $name, "webhookPort", InternalVal( $webhookFWinstance, "PORT", "" )) );

        $hash->{WEBHOOK_URL}     = "";
        $hash->{WEBHOOK_COUNTER} = "0";
        
        if ( $webhookHttpHostname ne "" && $hash->{WEBHOOK_PORT} ne "" ) {
        
            $hash->{WEBHOOK_URL} = "http://" . $webhookHttpHostname . ":" . $hash->{WEBHOOK_PORT} . $hash->{WEBHOOK_URI};
            my $url = "http://$webhookHttpHostname" . ":" . $hash->{WEBHOOK_PORT} . $hash->{WEBHOOK_URI};

            Log3 $name, 3, "NUKIBridge ($name) - URL ist: $url";
            NUKIBridge_Call($hash,$hash,"callback/add",$url,undef,undef ) if( $init_done );
            $hash->{WEBHOOK_REGISTER} = "sent";
            
        } else {
            $hash->{WEBHOOK_REGISTER} = "incomplete_attributes";
        }
    }

    return undef;
}

sub NUKIBridge_addExtension($$$) {

    my ( $name, $func, $link ) = @_;
    my $url = "/$link";

    Log3 $name, 2, "NUKIBridge ($name) - Registering NUKIBridge for webhook URI $url ...";
    
    $data{FWEXT}{$url}{deviceName} = $name;
    $data{FWEXT}{$url}{FUNC}       = $func;
    $data{FWEXT}{$url}{LINK}       = $link;

    return 1;
}

sub NUKIBridge_removeExtension($) {
    
    my ($link) = @_;

    my $url  = "/$link";
    my $name = $data{FWEXT}{$url}{deviceName};
    
    Log3 $name, 2, "NUKIBridge ($name) - Unregistering NUKIBridge for webhook URL $url...";
    delete $data{FWEXT}{$url};
}

sub NUKIBridge_Set($@) {

    my ($hash, $name, $cmd, @args) = @_;
    my ($arg, @params) = @args;

    
    if($cmd eq 'autocreate') {
        return "usage: autocreate" if( @args != 0 );

        NUKIBridge_Call($hash,$hash,"list",undef,undef,undef) if( !IsDisabled($name) );

        return undef;

    } elsif($cmd eq 'info') {
        return "usage: statusRequest" if( @args != 0 );
    
        NUKIBridge_Call($hash,$hash,"info",undef,undef,undef) if( !IsDisabled($name) );
        
        return undef;
        
    } elsif($cmd eq 'fwUpdate') {
        return "usage: fwUpdate" if( @args != 0 );
    
        NUKIBridge_CallBlocking($hash,"fwupdate",undef) if( !IsDisabled($name) );
        
        return undef;
        
    } elsif($cmd eq 'reboot') {
        return "usage: reboot" if( @args != 0 );
    
        NUKIBridge_CallBlocking($hash,"reboot",undef) if( !IsDisabled($name) );
        
        return undef;
        
    } elsif($cmd eq 'clearLog') {
        return "usage: clearLog" if( @args != 0 );
        
        NUKIBridge_CallBlocking($hash,"clearlog",undef) if( !IsDisabled($name) );
        
    } elsif($cmd eq 'factoryReset') {
        return "usage: clearLog" if( @args != 0 );
        
        NUKIBridge_CallBlocking($hash,"factoryReset",undef) if( !IsDisabled($name) );
        
    } elsif($cmd eq 'callbackRemove') {
        return "usage: callbackRemove" if( @args != 1 );
        my $id = "id=" . join( " ", @args );
        
        my $resp = NUKIBridge_CallBlocking($hash,"callback/remove",$id) if( !IsDisabled($name) );
        if( ($resp->{success} eq "true" or $resp->{success} == 1) and !IsDisabled($name) ) {
            return "Success Callback $id removed";
        } else {
            return "remove Callback failed";
        }

    } else {
        my  $list = ""; 
        $list .= "info:noArg autocreate:noArg callbackRemove:0,1,2 ";
        $list .= "clearLog:noArg fwUpdate:noArg reboot:noArg factoryReset:noArg" if( ReadingsVal($name,'bridgeType','Software') eq 'Hardware' );
        return "Unknown argument $cmd, choose one of $list";
    }
}

sub NUKIBridge_Get($@) {

    my ($hash, $name, $cmd, @args) = @_;
    my ($arg, @params) = @args;
    
    if($cmd eq 'logFile') {
        return "usage: logFile" if( @args != 0 );

        NUKIBridge_getLogfile($hash) if( !IsDisabled($name) );
        
    } elsif($cmd eq 'callbackList') {
        return "usage: callbackList" if( @args != 0 );

        NUKIBridge_getCallbackList($hash) if( !IsDisabled($name) );
        
    } else {
        my $list = "";
        $list .= "callbackList:noArg ";
        $list .= "logFile:noArg" if( ReadingsVal($name,'bridgeType','Software') eq 'Hardware' );
        return "Unknown argument $cmd, choose one of $list";
    }
}

sub NUKIBridge_GetCheckBridgeAlive($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);
    Log3 $name, 4, "NUKIBridge ($name) - NUKIBridge_GetCheckBridgeAlive";
    
    if( !IsDisabled($name) ) {

        NUKIBridge_Call($hash,$hash,'info',undef,undef,undef);
    
        Log3 $name, 4, "NUKIBridge ($name) - run NUKIBridge_Call";
    }
    
    InternalTimer( gettimeofday()+15+int(rand(15)), 'NUKIBridge_GetCheckBridgeAlive', $hash, 1 );
    
    Log3 $name, 4, "NUKIBridge ($name) - Call InternalTimer for NUKIBridge_GetCheckBridgeAlive";
}

sub NUKIBridge_firstRun($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    
    RemoveInternalTimer($hash);
    NUKIBridge_Call($hash,$hash,'list',undef,undef,undef) if( !IsDisabled($name) );
    InternalTimer( gettimeofday()+15, 'NUKIBridge_GetCheckBridgeAlive', $hash, 1 );

    return undef;
}

sub NUKIBridge_Call($$$$$$) {

    my ($hash,$chash,$path,$lockAction,$nukiId,$deviceType) = @_;
    
    my $name    =   $hash->{NAME};
    my $host    =   $hash->{HOST};
    my $port    =   $hash->{PORT};
    my $token   =   $hash->{TOKEN};
    
    
    my $uri = "http://" . $hash->{HOST} . ":" . $port;
    $uri .= "/" . $path if( defined $path);
    $uri .= "?token=" . $token if( defined($token) );
    $uri .= "&action=" . $lockActionsSmartLock{$lockAction} if( defined($lockAction) and $path ne "callback/add" and $chash->{DEVICETYPE} == 0 );
    $uri .= "&action=" . $lockActionsOpener{$lockAction}    if( defined($lockAction) and $path ne "callback/add" and $chash->{DEVICETYPE} == 2 );
    $uri .= "&url=" . $lockAction if( defined($lockAction) and $path eq "callback/add" );
    $uri .= "&nukiId=" . $nukiId if( defined($nukiId) );
    $uri .= "&deviceType=" . $deviceType if( defined($deviceType) );


    HttpUtils_NonblockingGet(
        {
            url            => $uri,
            timeout        => 30,
            hash           => $hash,
            chash          => $chash,
            endpoint       => $path,
            header         => "Accept: application/json",
            method         => "GET",
            callback       => \&NUKIBridge_Distribution,
        }
    );
    
    Log3 $name, 4, "NUKIBridge ($name) - Send HTTP POST with URL $uri";
}

sub NUKIBridge_Distribution($$$) {

    my ( $param, $err, $json ) = @_;
    my $hash            = $param->{hash};
    my $doTrigger       = $param->{doTrigger};
    my $name            = $hash->{NAME};
    my $host            = $hash->{HOST};
    
    
    Log3 $name, 5, "NUKIBridge ($name) - Response JSON: $json";
    Log3 $name, 5, "NUKIBridge ($name) - Response ERROR: $err";
    Log3 $name, 5, "NUKIBridge ($name) - Response CODE: $param->{code}" if( defined($param->{code}) and ($param->{code}) );
    
    readingsBeginUpdate($hash);
    
    if( defined( $err ) ) {
        if ( $err ne "" ) {
            if ($param->{endpoint} eq "info") {
                readingsBulkUpdate( $hash, "state", "not connected") if( $hash->{helper}{aliveCount} > 1 );
                Log3 $name, 5, "NUKIBridge ($name) - Bridge ist offline";
                $hash->{helper}{aliveCount} = $hash->{helper}{aliveCount} + 1;
            }
            
            readingsBulkUpdate( $hash, "lastError", $err ) if( ReadingsVal($name,"state","not connected") eq "not connected" );
            Log3 $name, 4, "NUKIBridge ($name) - error while requesting: $err";
            readingsEndUpdate( $hash, 1 );
            return $err;
        }
    }

    if( $json eq "" and exists( $param->{code} ) and $param->{code} ne 200 ) {
    
        if( $param->{code} eq 503 ) {
            NUKIDevice_Parse($param->{chash},$param->{code}) if( $hash != $param->{chash} );
            Log3 $name, 4, "NUKIBridge ($name) - smartlock is offline";
            readingsEndUpdate( $hash, 1 );
            return "received http code ".$param->{code}.": smartlock is offline";
        }
        
        readingsBulkUpdate( $hash, "lastError", "Internal error, " .$param->{code} );
        Log3 $name, 4, "NUKIBridge ($name) - received http code " .$param->{code}." without any data after requesting";

        readingsEndUpdate( $hash, 1 );
        return "received http code ".$param->{code}." without any data after requesting";
    }

    if( ( $json =~ /Error/i ) and exists( $param->{code} ) ) {    
        
        readingsBulkUpdate( $hash, "lastError", "invalid API token" ) if( $param->{code} eq 401 );
        readingsBulkUpdate( $hash, "lastError", "action is undefined" ) if( $param->{code} eq 400 and $hash == $param->{chash} );
        
        
        ###### Fehler bei Antwort auf Anfrage eines logischen Devices ######
#         NUKIDevice_Parse($param->{chash},$param->{code}) if( $param->{code} eq 404 );
#         NUKIDevice_Parse($param->{chash},$param->{code}) if( $param->{code} eq 400 and $hash != $param->{chash} );
        
        
        
        Log3 $name, 4, "NUKIBridge ($name) - invalid API token" if( $param->{code} eq 401 );
        Log3 $name, 4, "NUKIBridge ($name) - nukiId is not known" if( $param->{code} eq 404 );
        Log3 $name, 4, "NUKIBridge ($name) - action is undefined" if( $param->{code} eq 400 and $hash == $param->{chash} );

        
        readingsEndUpdate( $hash, 1 );
        return $param->{code};
    }
    
    if( $hash == $param->{chash} ) {
        
        NUKIBridge_ResponseProcessing($hash,$json,$param->{endpoint});
        
    } else {
    
#         NUKIDevice_Parse($param->{chash},$json);
    }
    
    readingsEndUpdate( $hash, 1 );
    return undef;
}

sub NUKIBridge_ResponseProcessing($$$) {

    my ($hash,$json,$path) = @_;
    my $name = $hash->{NAME};
    my $decode_json;
    
    
    if( !$json ) {
        Log3 $name, 3, "NUKIBridge ($name) - empty answer received";
        return undef;
    } elsif( $json =~ m'HTTP/1.1 200 OK' ) {
        Log3 $name, 4, "NUKIBridge ($name) - empty answer received";
        return undef;
    } elsif( $json !~ m/^[\[{].*[}\]]$/ ) {
        Log3 $name, 3, "NUKIBridge ($name) - invalid json detected: $json";
        return "NUKIBridge ($name) - invalid json detected: $json";
    }

    $decode_json = eval{decode_json($json)};
    if($@){
        Log3 $name, 3, "NUKIBridge ($name) - JSON error while request: $@";
        return;
    }
    
    if( ref($decode_json) eq "ARRAY" and scalar(@{$decode_json}) > 0 and $path eq "list" ) {

#         NUKIBridge_Autocreate($hash,$decode_json);
        
        
        my @buffer = split( '\[', $json );

        my ( $json, $tail ) = NUKIBridge_ParseJSON( $hash, $buffer[1] );

        while ($json) {

            Log3 $name, 5,
                "NUKIBridge ($name) - Decoding JSON message. Length: "
              . length($json)
              . " Content: "
              . $json;
            Log3 $name, 5,
                "NUKIBridge ($name) - Vor Sub: Laenge JSON: "
              . length($json)
              . " Content: "
              . $json
              . " Tail: "
              . $tail;


            Dispatch( $hash, $json, undef )
              unless ( not defined($tail) and not($tail) );

            ( $json, $tail ) = NUKIBridge_ParseJSON( $hash, $tail );

            Log3 $name, 5,
                "NUKIBridge ($name) - Nach Sub: Laenge JSON: "
              . length($json)
              . " Content: "
              . $json
              . " Tail: "
              . $tail;
        }

#         NUKIBridge_Call($hash,$hash,"info",undef,undef,undef)
#           if( !IsDisabled($name) );
    }
    
    elsif( $path eq "info" ) {
        readingsBeginUpdate( $hash );
        readingsBulkUpdate( $hash, "state", "connected" );
        Log3 $name, 5, "NUKIBridge ($name) - Bridge ist online";
            
        readingsEndUpdate( $hash, 1 );
        $hash->{helper}{aliveCount} = 0;
        
        NUKIBridge_InfoProcessing($hash,$decode_json);
    
    } else {
        Log3 $name, 5, "NUKIBridge ($name) - Rückgabe Path nicht korrekt: 
$json";
        return;
    }
    
    return undef;
}

sub NUKIBridge_CGI() {
    
    my ($request) = @_;
    
    my $hash;
    my $name;
    my $nukiId;
    
    # data received
    # Testaufruf:
    # curl --data '{"nukiId": 123456, "state": 1,"stateName": "locked", "batteryCritical": false}' http://10.6.6.20:8083/fhem/NUKIDevice-123456
    # wget --post-data '{"nukiId": 123456, "state": 1,"stateName": "locked", "batteryCritical": false}' http://10.6.6.20:8083/fhem/NUKIDevice-123456
    
    
    my $header = join("\n", @FW_httpheader);

    my ($first,$json) = split("&",$request,2);
    
    if( !$json ) {
        Log3 $name, 3, "NUKIBridge ($name) - empty message received";
        return undef;
    } elsif( $json =~ m'HTTP/1.1 200 OK' ) {
        Log3 $name, 4, "NUKIBridge ($name) - empty answer received";
        return undef;
    } elsif( $json !~ m/^[\[{].*[}\]]$/ ) {
        Log3 $name, 3, "NUKIBridge ($name) - invalid json detected: $json";
        return "NUKIBridge ($name) - invalid json detected: $json";
    }
    
    Log3 $name, 5, "NUKIBridge ($name) - Webhook received with JSON: $json";
 
    my $decode_json = eval{decode_json($json)};
    if($@){
        Log3 $name, 3, "NUKIBridge ($name) - JSON error while request: $@";
        return;
    }
    
    
    if( ref($decode_json) eq "HASH" ) {
        $hash->{WEBHOOK_COUNTER}++;
        $hash->{WEBHOOK_LAST} = TimeNow();
        
        if ( defined( $modules{NUKIDevice}{defptr} ) ) {
            while ( my ( $key, $value ) = each %{ $modules{NUKIDevice}{defptr} } 
) {
            
                $hash = $modules{NUKIDevice}{defptr}{$key};
                $name = $hash->{NAME};
                $nukiId = InternalVal( $name, "NUKIID", undef );
                next if ( !$nukiId or $nukiId ne $decode_json->{nukiId} );


                Log3 $name, 4, "NUKIBridge ($name) - Received webhook for 
matching NukiId at device $name";
            
                NUKIDevice_Parse($hash,$json);
            }
        }
        
        return ( undef, undef );
    }
    
    # no data received
    else {
    
        Log3 undef, 4, "NUKIBridge - received malformed request\n$request";
    }

    return ( "text/plain; charset=utf-8", "Call failure: " . $request );
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
    my $nukiType;
    my $nukiName;
    
    readingsBeginUpdate($hash);
    
    foreach $nukiSmartlock (@{$decode_json}) {
        
        $nukiId     = $nukiSmartlock->{nukiId};
        $nukiType   = $nukiSmartlock->{deviceType};
        $nukiName   = $nukiSmartlock->{name};
        
        
        my $code = $name ."-".$nukiId;
        if( defined($modules{NUKIDevice}{defptr}{$code}) ) {
            Log3 $name, 3, "NUKIDevice ($name) - NukiId '$nukiId' already 
defined as '$modules{NUKIDevice}{defptr}{$code}->{NAME}'";
            next;
        }
        
        my $devname = "NUKIDevice" . $nukiId;
        my $define= "$devname NUKIDevice $nukiId IODev=$name $nukiType";
        
        Log3 $name, 3, "NUKIDevice ($name) - create new device '$devname' for 
address '$nukiId'";

        my $cmdret= CommandDefine(undef,$define);
        if($cmdret) {
            Log3 $name, 3, "NUKIDevice ($name) - Autocreate: An error occurred 
while creating device for nukiId '$nukiId': $cmdret";
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
    
    my $nukiId;
    my $scanResults;
    my %response_hash;
    my $dname;
    my $dhash;
    
    my %bridgeType = (
        '1' =>  'Hardware',
        '2' =>  'Software'
    );
    
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash,"appVersion",$decode_json->{versions}->{appVersion});
    readingsBulkUpdate($hash,"firmwareVersion",$decode_json->{versions}->{firmwareVersion});
    readingsBulkUpdate($hash,"wifiFirmwareVersion",$decode_json->{versions}->{wifiFirmwareVersion});
    readingsBulkUpdate($hash,"bridgeType",$bridgeType{$decode_json->{bridgeType}});
    readingsBulkUpdate($hash,"hardwareId",$decode_json->{ids}{hardwareId});
    readingsBulkUpdate($hash,"serverId",$decode_json->{ids}{serverId});
    readingsBulkUpdate($hash,"uptime",$decode_json->{uptime});
    readingsBulkUpdate($hash,"currentTime",$decode_json->{currentTime});
    readingsBulkUpdate($hash,"serverConnected",$decode_json->{serverConnected});
    readingsEndUpdate($hash,1);
    
    
    foreach $scanResults (@{$decode_json->{scanResults}}) {
        if( ref($scanResults) eq "HASH" ) {
            if ( defined( $modules{NUKIDevice}{defptr} ) ) {
                while ( my ( $key, $value ) = each %{ $modules{NUKIDevice}{defptr} } ) {

                    $dhash = $modules{NUKIDevice}{defptr}{$key};
                    $dname = $dhash->{NAME};
                    $nukiId = InternalVal( $dname, "NUKIID", undef );
                    next if ( !$nukiId or $nukiId ne $scanResults->{nukiId} );

                    Log3 $name, 4, "NUKIDevice ($dname) - Received scanResults for matching NukiID $nukiId at device $dname";
            
                    %response_hash = ('name'=>$scanResults->{name}, 'rssi'=>$scanResults->{rssi},'paired'=>$scanResults->{paired});

                    NUKIDevice_Parse($dhash,encode_json \%response_hash);
                }
            }
        }
    }
}

sub NUKIBridge_getLogfile($) {

    my ($hash)  = @_;
    my $name    = $hash->{NAME};

    
    my $decode_json = NUKIBridge_CallBlocking($hash,"log",undef);
    
    Log3 $name, 4, "NUKIBridge ($name) - Log data are collected and processed";
    
    
    if( ref($decode_json) eq "ARRAY" and scalar(@{$decode_json}) > 0 ) {
        Log3 $name, 4, "NUKIBridge ($name) - created Table with log file";
    
        my $ret = '<html><table width=100%><tr><td>';
        $ret .= '<table class="block wide">';
        
        foreach my $logs (@{$decode_json}) {
            $ret .= '<tr class="odd">';
            
            if($logs->{timestamp}) {
                $ret .= "<td><b>timestamp:</b> </td>";
                $ret .= "<td>$logs->{timestamp}</td>";
                $ret .= '<td> </td>';
            }
            
            if($logs->{type}) {
                $ret .= "<td><b>type:</b> </td>";
                $ret .= "<td>$logs->{type}</td>";
                $ret .= '<td> </td>';
            }
            
            foreach my $d (reverse sort keys %{$logs}) {
                next if( $d eq "type" );
                next if( $d eq "timestamp" );
               
                $ret .= "<td><b>$d:</b> </td>";
                $ret .= "<td>$logs->{$d}</td>";
                $ret .= '<td> </td>';
            }
            
            $ret .= '</tr>';
        }
    
        $ret .= '</table></td></tr>';
        $ret .= '</table></html>';
     
        return $ret;
    }
}

sub NUKIBridge_getCallbackList($) {

    my ($hash)  = @_;
    my $name    = $hash->{NAME};

    
    my $decode_json = NUKIBridge_CallBlocking($hash,"callback/list",undef);
    return
      unless ( ref($decode_json) eq 'HASH' );
    
    Log3 $name, 4, "NUKIBridge ($name) - Callback data is collected and 
processed";
    
    if( ref($decode_json->{callbacks}) eq "ARRAY" and 
scalar(@{$decode_json->{callbacks}}) > 0 ) {
        Log3 $name, 4, "NUKIBridge ($name) - created Table with log file";
    
        my $ret = '<html><table width=100%><tr><td>';

        $ret .= '<table class="block wide">';

            $ret .= '<tr class="odd">';
            $ret .= "<td><b>Callback-ID</b></td>";
            $ret .= "<td> </td>";
            $ret .= "<td><b>Callback-URL</b></td>";
            $ret .= '</tr>';
    
        foreach my $cb (@{$decode_json->{callbacks}}) {
        
            $ret .= "<td>$cb->{id}</td>";
            $ret .= "<td> </td>";
            $ret .= "<td>$cb->{url}</td>";
            $ret .= '</tr>';
        }
    
        $ret .= '</table></td></tr>';
        $ret .= '</table></html>';
     
        return $ret;
    }
    
    return "No callback data available or error during processing";
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
    $url .= "&" . $obj if( defined($obj) );
    
    
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
    } elsif( $data !~ m/^[\[{].*[}\]]$/ and $path ne "log" ) {
        Log3 $name, 3, "NUKIDevice ($name) - invalid json detected for $url: $data";
        return "NUKIDevice ($name) - invalid json detected for $url: $data";
    }


    my $decode_json = eval{decode_json($data)};
    if($@){
        Log3 $name, 3, "NUKIBridge ($name) - JSON error while request: $@";
        return;
    }
    
    return undef if( !$decode_json );
    
    Log3 $name, 5, "NUKIBridge ($name) - Data: $data";
    Log3 $name, 4, "NUKIBridge ($name) - Blocking HTTP Query finished";
    return ($decode_json);
}

sub NUKIBridge_ParseJSON($$) {

    my ( $hash, $buffer ) = @_;

    my $name  = $hash->{NAME};
    my $open  = 0;
    my $close = 0;
    my $msg   = '';
    my $tail  = '';

    if ($buffer) {
        foreach my $c ( split //, $buffer ) {
            if ( $open == $close and $open > 0 ) {
                $tail .= $c;
                Log3 $name, 5,
                  "NUKIBridge ($name) - $open == $close and $open > 0";

            }
            elsif ( ( $open == $close ) and ( $c ne '{' ) ) {

                Log3 $name, 5,
"NUKIBridge ($name) - Garbage character before message: "
                  . $c;

            }
            else {

                if ( $c eq '{' ) {

                    $open++;

                }
                elsif ( $c eq '}' ) {

                    $close++;
                }

                $msg .= $c;
            }
        }

        if ( $open != $close ) {

            $tail = $msg;
            $msg  = '';
        }
    }

    Log3 $name, 5,
      "NUKIBridge ($name) - return msg: $msg and tail: $tail";
    return ( $msg, $tail );
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
    <li>bridgeType - Hardware bridge / Software bridge</li>
    <li>currentTime - Current timestamp</li>
    <li>firmwareVersion - Version of the bridge firmware</li>
    <li>hardwareId - Hardware ID</li>
    <li>lastError - Last connected error</li>
    <li>serverConnected - Flag indicating whether or not the bridge is connected to the Nuki server</li>
    <li>serverId - Server ID</li>
    <li>uptime - Uptime of the bridge in seconds</li>
    <li>wifiFirmwareVersion- Version of the WiFi modules firmware</li>
    <br>
    The preceding number is continuous, starts with 0 und returns the properties of <b>one</b> Smartlock.
   </ul>
  <br><br>
  <a name="NUKIBridgeset"></a>
  <b>Set</b>
  <ul>
    <li>autocreate - Prompts to re-read all Smartlocks from the bridge and if not already present in FHEM, create the autimatic.</li>
    <li>callbackRemove -  Removes a previously added callback</li>
    <li>clearLog - Clears the log of the Bridge (only hardwarebridge)</li>
    <li>factoryReset - Performs a factory reset (only hardwarebridge)</li>
    <li>fwUpdate -  Immediately checks for a new firmware update and installs it (only hardwarebridge)</li>
    <li>info -  Returns all Smart Locks in range and some device information of the bridge itself</li>
    <li>reboot - reboots the bridge (only hardwarebridge)</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeget"></a>
  <b>Get</b>
  <ul>
    <li>callbackList - List of register url callbacks. The Bridge register up to 3  url callbacks.</li>
    <li>logFile - Retrieves the log of the Bridge</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeattribut"></a>
  <b>Attributes</b>
  <ul>
    <li>disable - disables the Nuki Bridge</li>
    <li>webhookFWinstance - Webinstanz of the Callback</li>
    <li>webhookHttpHostname - IP or FQDN of the FHEM Server Callback</li>
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
    <li>bridgeType - Hardware oder Software/App Bridge</li>
    <li>currentTime - aktuelle Zeit auf der Bridge zum zeitpunkt des Info holens</li>
    <li>firmwareVersion - aktuell auf der Bridge verwendete Firmwareversion</li>
    <li>hardwareId - ID der Hardware Bridge</li>
    <li>lastError - gibt die letzte HTTP Errormeldung wieder</li>
    <li>serverConnected - true/false gibt an ob die Hardwarebridge Verbindung zur Nuki-Cloude hat.</li>
    <li>serverId - gibt die ID des Cloudeservers wieder</li>
    <li>uptime - Uptime der Bridge in Sekunden</li>
    <li>wifiFirmwareVersion- Firmwareversion des Wifi Modules der Bridge</li>
    <br>
    Die vorangestellte Zahl ist forlaufend und gibt beginnend bei 0 die Eigenschaften <b>Eines</b> Smartlocks wieder.
  </ul>
  <br><br>
  <a name="NUKIBridgeset"></a>
  <b>Set</b>
  <ul>
    <li>autocreate - Veranlasst ein erneutes Einlesen aller Smartlocks von der Bridge und falls noch nicht in FHEM vorhanden das autimatische anlegen.</li>
    <li>callbackRemove - Löschen einer Callback Instanz auf der Bridge. Die Instanz ID kann mittels get callbackList ermittelt werden</li>
    <li>clearLog - löscht das Logfile auf der Bridge</li>
    <li>fwUpdate - schaut nach einer neueren Firmware und installiert diese sofern vorhanden</li>
    <li>info - holt aktuellen Informationen über die Bridge</li>
    <li>reboot - veranlässt ein reboot der Bridge</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeget"></a>
  <b>Get</b>
  <ul>
    <li>callbackList - Gibt die Liste der eingetragenen Callback URL's wieder. Die Bridge nimmt maximal 3 auf.</li>
    <li>logFile - Zeigt das Logfile der Bridge an</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIBridgeattribut"></a>
  <b>Attribute</b>
  <ul>
    <li>disable - deaktiviert die Nuki Bridge</li>
    <li>webhookFWinstance - zu verwendene Webinstanz für den Callbackaufruf</li>
    <li>webhookHttpHostname - IP oder FQDN vom FHEM Server für den Callbackaufruf</li>
    <br>
  </ul>
</ul>

=end html_DE
=cut
