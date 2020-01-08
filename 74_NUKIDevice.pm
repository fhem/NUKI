###############################################################################
# 
# Developed with Kate
#
#  (c) 2016-2017 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
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


my $version = "0.7.9";




# Declare functions
sub NUKIDevice_Initialize($);
sub NUKIDevice_Define($$);
sub NUKIDevice_Undef($$);
sub NUKIDevice_Attr(@);
sub NUKIDevice_Set($$@);
sub NUKIDevice_GetUpdate($);
sub NUKIDevice_ReadFromNUKIBridge($@);
sub NUKIDevice_Parse($$);
sub NUKIDevice_WriteReadings($$);


my %deviceTypes = (
    0 => 'smartlock',
    2 => 'opener'
);

my %deviceTypeIds = reverse(%deviceTypes);





sub NUKIDevice_Initialize($) {

    my ($hash) = @_;
    
    $hash->{Match} = '^{.*}$';

    $hash->{SetFn}          = "NUKIDevice_Set";
    $hash->{DefFn}          = "NUKIDevice_Define";
    $hash->{UndefFn}        = "NUKIDevice_Undef";
    $hash->{AttrFn}         = "NUKIDevice_Attr";
    $hash->{ParseFn}        = 'NUKIDevice_Parse';
    
    $hash->{AttrList}       = "IODev ".
                              "model:opener,smartlock ".
                              "disable:1 ".
                              $readingFnAttributes;



    foreach my $d(sort keys %{$modules{NUKIDevice}{defptr}}) {
        my $hash = $modules{NUKIDevice}{defptr}{$d};
        $hash->{VERSION} 	= $version;
    }
}

sub NUKIDevice_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( '[ \t][ \t]*', $def );

    return "too few parameters: define <name> NUKIDevice <nukiId> <deviceType>" if( @a < 2 );


    my $name            = $a[0];
    my $nukiId          = $a[2];
    my $deviceType      = (defined $a[3]) ? $a[3] : 0;

    $hash->{NUKIID}     = $nukiId;
    $hash->{DEVICETYPE} = (defined $deviceType) ? $deviceType : 0;
    $hash->{VERSION}    = $version;
    $hash->{STATE}      = 'Initialized';


    my $iodev = AttrVal( $name, 'IODev', 'none' );

    AssignIoPort( $hash, $iodev ) if ( !$hash->{IODev} );

    if ( defined( $hash->{IODev}->{NAME} ) ) {
        Log3 $name, 3, "NUKIDevice ($name) - I/O device is "
          . $hash->{IODev}->{NAME};
    }
    else {
        Log3 $name, 1, "NUKIDevice ($name) - no I/O device";
    }

    $iodev = $hash->{IODev}->{NAME};

    my $d = $modules{NUKIDevice}{defptr}{$nukiId};

    return
"NUKIDevice device $name on GardenaSmartBridge $iodev already defined."
      if (  defined($d)
        and $d->{IODev} == $hash->{IODev}
        and $d->{NAME} ne $name );
  
  
    Log3 $name, 3, "NUKIDevice ($name) - defined with NukiId: $nukiId";
    Log3 $name, 1, "NUKIDevice ($name) - reading battery a deprecated and will be remove in future";

    CommandAttr(undef,$name . ' room NUKI')
      if ( AttrVal($name,'room','none') eq 'none');
    CommandAttr(undef,$name . ' model ' . $deviceTypes{$deviceType})
      if ( AttrVal($name,'model','none') eq 'none');
    
    if( $init_done ) {
        InternalTimer( gettimeofday()+int(rand(10)), "NUKIDevice_GetUpdate", $hash, 0 );
    } else {
        InternalTimer( gettimeofday()+15+int(rand(5)), "NUKIDevice_GetUpdate", $hash, 0 );
    }
    
    $modules{NUKIDevice}{defptr}{$nukiId} = $hash;

    return undef;
}

sub NUKIDevice_Undef($$) {

    my ( $hash, $arg ) = @_;
    
    my $nukiId = $hash->{NUKIID};
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);

    Log3 $name, 3, "NUKIDevice ($name) - undefined with NukiId: $nukiId";
    delete($modules{NUKIDevice}{defptr}{$nukiId});

    return undef;
}

sub NUKIDevice_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
    my $token = $hash->{IODev}->{TOKEN};

    if( $attrName eq "disable" ) {
        if( $cmd eq "set" and $attrVal eq "1" ) {
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - disabled";
        }

        elsif( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - enabled";
        }
    }
    
    if( $attrName eq "disabledForIntervals" ) {
        if( $cmd eq "set" ) {
            Log3 $name, 3, "NUKIDevice ($name) - enable disabledForIntervals";
            readingsSingleUpdate ( $hash, "state", "Unknown", 1 );
        }

        elsif( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - delete disabledForIntervals";
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
        
    } elsif( $cmd eq 'lock' or $cmd eq 'deactivateRto' ) {
        $lockAction = $cmd;

    } elsif( $cmd eq 'unlock' or $cmd eq 'activateRto' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'unlatch' or $cmd eq 'electricStrikeActuation' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'locknGo' or $cmd eq 'activateContinuousMode' ) {
        $lockAction = $cmd;
        
    } elsif( $cmd eq 'locknGoWithUnlatch' or $cmd eq 'deactivateContinuousMode' ) {
        $lockAction = $cmd;
    
    } elsif( $cmd eq 'unpair' ) {
        
#         NUKIDevice_ReadFromNUKIBridge($hash,"$cmd",undef,$hash->{NUKIID},$hash->{DEVICETYPE} ) if( !IsDisabled($name) );
        IOWrite($hash,"$cmd",undef,$hash->{NUKIID},$hash->{DEVICETYPE}) if( !IsDisabled($name) );
        return undef;
    
    } else {
        my $list = '';
        
        if ( $hash->{DEVICETYPE} == 0 ) {
            $list= "statusRequest:noArg unlock:noArg lock:noArg unlatch:noArg locknGo:noArg locknGoWithUnlatch:noArg unpair:noArg";
        } elsif ( $hash->{DEVICETYPE} == 2 ) {
            $list= "statusRequest:noArg activateRto:noArg deactivateRto:noArg electricStrikeActuation:noArg activateContinuousMode:noArg deactivateContinuousMode:noArg unpair:noArg";
        }
        
        return "Unknown argument $cmd, choose one of $list";
    }
    
    $hash->{helper}{lockAction} = $lockAction;
    IOWrite($hash,"lockAction",$lockAction,$hash->{NUKIID},$hash->{DEVICETYPE});
#     NUKIDevice_ReadFromNUKIBridge($hash,"lockAction",$lockAction,$hash->{NUKIID},$hash->{DEVICETYPE} ) if( !IsDisabled($name) );
    
    return undef;
}

sub NUKIDevice_GetUpdate($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);
    
#     NUKIDevice_ReadFromNUKIBridge($hash, "lockState", undef, $hash->{NUKIID}, $hash->{DEVICETYPE} ) if( !IsDisabled($name) );
    IOWrite($hash, "lockState", undef, $hash->{NUKIID}, $hash->{DEVICETYPE} ) if( !IsDisabled($name) );
    Log3 $name, 5, "NUKIDevice ($name) - NUKIDevice_GetUpdate Call IOWrite" if( !IsDisabled($name) );

    return undef;
}

sub NUKIDevice_ReadFromNUKIBridge($@) {

    my ($hash,@a) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 4, "NUKIDevice ($name) - NUKIDevice_ReadFromNUKIBridge check Bridge connected";
    return "IODev $hash->{IODev} is not connected" if( ReadingsVal($hash->{IODev}->{NAME},"state","not connected") eq "not connected" );
    
    
    no strict "refs";
    my $ret;
    unshift(@a,$name);
    
    Log3 $name, 4, "NUKIDevice ($name) - NUKIDevice_ReadFromNUKIBridge Bridge is connected call IOWrite";
    
    $ret = IOWrite($hash,$hash,@a);
    use strict "refs";
    return $ret;
    return if(IsDummy($name) || IsIgnored($name));
    my $iohash = $hash->{IODev};
    
    if(!$iohash ||
        !$iohash->{TYPE} ||
        !$modules{$iohash->{TYPE}} ||
        !$modules{$iohash->{TYPE}}{ReadFn}) {
        Log3 $name, 3, "NUKIDevice ($name) - No I/O device or ReadFn found for $name";
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

    Log3 $name, 5, "NUKIDevice ($name) - Parse with result: $result";
    #########################################
    ####### Errorhandling #############
    
    if( !$result ) {
        Log3 $name, 3, "NUKIDevice ($name) - empty answer received";
        return undef;
    } elsif( $result =~ m'HTTP/1.1 200 OK' ) {
        Log3 $name, 4, "NUKIDevice ($name) - empty answer received";
        return undef;
    } elsif( $result !~ m/^[\[{].*[}\]]$/ ) {
        Log3 $name, 3, "NUKIDevice ($name) - invalid json detected: $result";
        return "NUKIDevice ($name) - invalid json detected: $result";
    }
    
    if( $result =~ /\d{3}/ ) {
        if( $result eq 400 ) {
            readingsSingleUpdate( $hash, "state", "action is undefined", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - action is undefined";
            return;
        }
    
        if( $result eq 404 ) {
            readingsSingleUpdate( $hash, "state", "nukiId is not known", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - nukiId is not known";
            return;
        }
        
        if( $result eq 503 ) {
            readingsSingleUpdate( $hash, "state", "smartlock is offline", 1 );
            Log3 $name, 3, "NUKIDevice ($name) - smartlock is offline";
            return;
        }
    }
    
    
    #########################################
    #### verarbeiten des JSON Strings #######
    my $decode_json = eval{decode_json($result)};
    if($@){
        Log3 $name, 3, "NUKIDevice ($name) - JSON error while request: $@";
        return;
    }
    
    
    if( ref($decode_json) ne "HASH" ) {
        Log3 $name, 2, "NUKIDevice ($name) - got wrong status message for $name: $decode_json";
        return undef;
    }
    
    elsif ( defined( $decode_json->{nukiId} ) ) {

        my $nukiId = $decode_json->{nukiId};

        if ( my $hash = $modules{NUKIDevice}{defptr}{$nukiId} ) {
            my $name = $hash->{NAME};

            NUKIDevice_WriteReadings( $hash, $decode_json );
            Log3 $name, 4,
              "NUKIDevice ($name) - find logical device: $hash->{NAME}";

            return $hash->{NAME};

        }
        else {

            Log3 $name, 3,
                "NUKIDevice ($name) - autocreate new device "
              . makeDeviceName( $decode_json->{name} )
              . " with nukiId $decode_json->{nukiId}, model $decode_json->{deviceType}";
            return
                "UNDEFINED "
              . makeDeviceName( $decode_json->{name} )
              . " NUKIDevice $decode_json->{nukiId} $decode_json->{deviceType}";
        }
    }

    Log3 $name, 5, "NUKIDevice ($name) - parse status message for $name";
    
    NUKIDevice_WriteReadings($hash,$decode_json);
}

sub NUKIDevice_WriteReadings($$) {

    my ($hash,$decode_json)     = @_;
    my $name                    = $hash->{NAME};
    
    
    
    ############################
    #### Status des Smartlock
    
    my $battery;
    if( defined($decode_json->{batteryCritical}) ) {
        if( $decode_json->{batteryCritical} eq "false" or $decode_json->{batteryCritical} == 0 ) {
            $battery = "ok";
        } elsif ( $decode_json->{batteryCritical} eq "true" or $decode_json->{batteryCritical} == 1 ) {
            $battery = "low";
        }
    }


    readingsBeginUpdate($hash);
    
    if( defined($hash->{helper}{lockAction}) ) {
    
        my ($state,$lockState);
        
        
        if( defined($decode_json->{success}) and ($decode_json->{success} eq "true" or $decode_json->{success} eq "1") ) {
        
            $state = $hash->{helper}{lockAction};
            $lockState = $hash->{helper}{lockAction};
#             NUKIDevice_ReadFromNUKIBridge($hash, "lockState", undef, $hash->{NUKIID} ) if( ReadingsVal($hash->{IODev}->{NAME},'bridgeType','Software') eq 'Software' );
            IOWrite($hash, "lockState", undef, $hash->{NUKIID} ) if( ReadingsVal($hash->{IODev}->{NAME},'bridgeType','Software') eq 'Software' );
            
        } elsif ( defined($decode_json->{success}) and ($decode_json->{success} eq "false" or $decode_json->{success} eq "0") ) {
        
            $state = "error";
#             NUKIDevice_ReadFromNUKIBridge($hash, "lockState", undef, $hash->{NUKIID} );
            IOWrite($hash, "lockState", undef, $hash->{NUKIID}, $hash->{DEVICETYPE} );
        }

        readingsBulkUpdate( $hash, "state", $state );
        readingsBulkUpdate( $hash, "lockState", $lockState );
        readingsBulkUpdate( $hash, "success", $decode_json->{success} );
        
        
        delete $hash->{helper}{lockAction};
        Log3 $name, 5, "NUKIDevice ($name) - lockAction readings set for $name";
    
    } else {
        
        readingsBulkUpdate( $hash, "batteryCritical", $decode_json->{batteryCritical} );
        readingsBulkUpdate( $hash, "lockState", $decode_json->{stateName} );
        readingsBulkUpdate( $hash, "state", $decode_json->{stateName} );
        readingsBulkUpdate( $hash, "battery", $battery );
        readingsBulkUpdate( $hash, "batteryState", $battery );
        readingsBulkUpdate( $hash, "success", $decode_json->{success} );
        
        readingsBulkUpdate( $hash, "name", $decode_json->{name} );
        readingsBulkUpdate( $hash, "rssi", $decode_json->{rssi} );
        readingsBulkUpdate( $hash, "paired", $decode_json->{paired} );
    
        Log3 $name, 5, "NUKIDevice ($name) - readings set for $name";
    }
    
    readingsEndUpdate( $hash, 1 );
    
    
    return undef;
}







1;




=pod
=item device
=item summary    Modul to control the Nuki Smartlock's
=item summary_DE Modul zur Steuerung des Nuki Smartlocks.

=begin html

<a name="NUKIDevice"></a>
<h3>NUKIDevice</h3>
<ul>
  <u><b>NUKIDevice - Controls the Nuki Smartlock</b></u>
  <br>
  The Nuki module connects FHEM over the Nuki Bridge with a Nuki Smartlock or Nuki Opener. After that, it´s possible to lock and unlock the Smartlock.<br>
  Normally the Nuki devices are automatically created by the bridge module.
  <br><br>
  <a name="NUKIDevicedefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name&gt; NUKIDevice &lt;Nuki-Id&gt; &lt;IODev-Device&gt; &lt;Device-Type&gt;</code>
    <br><br>
    Device-Type is 0 for the Smartlock and 2 for the Opener.
    <br><br>
    Example:
    <ul><br>
      <code>define Frontdoor NUKIDevice 1 NBridge1 0</code><br>
    </ul>
    <br>
    This statement creates a NUKIDevice with the name Frontdoor, the NukiId 1 and the IODev device NBridge1.<br>
    After the device has been created, the current state of the Smartlock is automatically read from the bridge.
  </ul>
  <br><br>
  <a name="NUKIDevicereadings"></a>
  <b>Readings</b>
  <ul>
    <li>state - Status of the Smartlock or error message if any error.</li>
    <li>lockState - current lock status uncalibrated, locked, unlocked, unlocked (lock ‘n’ go), unlatched, locking, unlocking, unlatching, motor blocked, undefined.</li>
    <li>name - name of the device</li>
    <li>paired - paired information false/true</li>
    <li>rssi - value of rssi</li>
    <li>succes - true, false   Returns the status of the last closing command. Ok or not Ok.</li>
    <li>batteryCritical - Is the battery in a critical state? True, false</li>
    <li>batteryState - battery status, ok / low</li>
  </ul>
  <br><br>
  <a name="NUKIDeviceset"></a>
  <b>Set</b>
  <ul>
    <li>statusRequest - retrieves the current state of the smartlock from the bridge.</li>
    <li>lock - lock</li>
    <li>unlock - unlock</li>
    <li>unlatch - unlock / open Door</li>
    <li>unpair -  Removes the pairing with a given Smart Lock</li>
    <li>locknGo - lock when gone</li>
    <li>locknGoWithUnlatch - lock after the door has been opened</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIDeviceattribut"></a>
  <b>Attributes</b>
  <ul>
    <li>disable - disables the Nuki device</li>
    <br>
  </ul>
</ul>

=end html
=begin html_DE

<a name="NUKIDevice"></a>
<h3>NUKIDevice</h3>
<ul>
  <u><b>NUKIDevice - Steuert das Nuki Smartlock</b></u>
  <br>
  Das Nuki Modul verbindet FHEM über die Nuki Bridge  mit einem Nuki Smartlock oder Nuki Opener. Es ist dann m&ouml;glich das Schloss zu ver- und entriegeln.<br>
  In der Regel werden die Nuki Devices automatisch durch das Bridgemodul angelegt.
  <br><br>
  <a name="NUKIDevicedefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name&gt; NUKIDevice &lt;Nuki-Id&gt; &lt;IODev-Device&gt; &lt;Device-Type&gt;</code>
    <br><br>
    Device-Type ist 0 f&uuml;r das Smartlock und 2 f&üuml;r den Opener.
    <br><br>
    Beispiel:
    <ul><br>
      <code>define Haust&uuml;r NUKIDevice 1 NBridge1 0</code><br>
    </ul>
    <br>
    Diese Anweisung erstellt ein NUKIDevice mit Namen Haust&uuml;r, der NukiId 1 sowie dem IODev Device NBridge1.<br>
    Nach dem anlegen des Devices wird automatisch der aktuelle Zustand des Smartlocks aus der Bridge gelesen.
  </ul>
  <br><br>
  <a name="NUKIDevicereadings"></a>
  <b>Readings</b>
  <ul>
    <li>state - Status des Smartlock bzw. Fehlermeldung von Fehler vorhanden.</li>
    <li>lockState - aktueller Schlie&szlig;status uncalibrated, locked, unlocked, unlocked (lock ‘n’ go), unlatched, locking, unlocking, unlatching, motor blocked, undefined.</li>
    <li>name - Name des Smart Locks</li>
    <li>paired - pairing Status des Smart Locks</li>
    <li>rssi - rssi Wert des Smart Locks</li>
    <li>succes - true, false Gibt des Status des letzten Schlie&szlig;befehles wieder. Geklappt oder nicht geklappt.</li>
    <li>batteryCritical - Ist die Batterie in einem kritischen Zustand? true, false</li>
    <li>batteryState - Status der Batterie, ok/low</li>
  </ul>
  <br><br>
  <a name="NUKIDeviceset"></a>
  <b>Set</b>
  <ul>
    <li>statusRequest - ruft den aktuellen Status des Smartlocks von der Bridge ab.</li>
    <li>lock - verschlie&szlig;en</li>
    <li>unlock - aufschlie&szlig;en</li>
    <li>unlatch - entriegeln/Falle &ouml;ffnen.</li>
    <li>unpair -  entfernt das pairing mit dem Smart Lock</li>
    <li>locknGo - verschlie&szlig;en wenn gegangen</li>
    <li>locknGoWithUnlatch - verschlie&szlig;en nach dem die Falle ge&ouml;ffnet wurde.</li>
    <br>
  </ul>
  <br><br>
  <a name="NUKIDeviceattribut"></a>
  <b>Attribute</b>
  <ul>
    <li>disable - deaktiviert das Nuki Device</li>
    <br>
  </ul>
</ul>

=end html_DE
=cut
