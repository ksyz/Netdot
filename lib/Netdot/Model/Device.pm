package Netdot::Model::Device;

use base 'Netdot::Model';
use warnings;
use strict;
use SNMP::Info;
use Netdot::Util::DNS;
use Parallel::ForkManager;

# Timeout seconds for SNMP queries 
# (different from SNMP connections)
my $TIMEOUT = Netdot->config->get('SNMP_QUERY_TIMEOUT');;

# Define some signal handlers
$SIG{ALRM} = sub { die "timeout" };

# Some regular expressions
my $IPV4        = Netdot->get_ipv4_regex();
my $IPV6        = Netdot->get_ipv6_regex();
my $AIRESPACEIF = '(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\.\d';

# Other fixed variables
my $MAXPROCS    = Netdot->config->get('SNMP_MAX_PROCS');

# Objects we need here
my $logger      = Netdot->log->get_logger('Netdot::Model::Device');
my $dns         = Netdot::Util::DNS->new();


=head1 NAME

Netdot::Model::Device - Network Device Class

=head1 SYNOPSIS

=head1 CLASS METHODS
=cuts


############################################################################
=head2 search - Search Devices

    Overrides base method to extend functionality:

  Arguments:
    Hash with the following keys:
      name - Can be either a string, RR object RR id or IP address, 
             String can be FQDN or hostname.
    
      The rest of the fields in the Device table.

  Returns:
    Array of Device objects or iterator (depending on context)

  Exampless:    
    my @devs = Device->search(name=>'localhost.localdomain');

=cut
sub search {
    my ($class, @args) = @_;
    $class->isa_class_method('search');

    # Class::DBI::search() might include an extra 'options' hash ref
    # at the end.  In that case, we want to extract the 
    # field/value hash first.
    my $opts = @args % 2 ? pop @args : {}; 
    my %argv = @args;

    my $dev;
    
    if ( exists $argv{name} ){
	if ( ref($argv{name}) =~ /RR/ ){ 
	    # We were passed a RR object.  
	    # Proceed as regular search
	    return $class->SUPER::search(%argv, $opts);
	}
	if ( $argv{name} =~ /$IPV4|$IPV6/ ){
	    # Looks like an IP address
	    if ( my $ip = Ipblock->search(address=>$argv{name})->first ){
		if ( $ip->interface && ($dev = $ip->interface->device) ){
		    $argv{name} = $dev->name;
		}else{
		    $logger->debug("Address $argv{name} exists but no Device associated");
		}
	    }else{
		$logger->debug("Device::search: $argv{name} not found in DB");
	    }
	}
	# Notice that we could be looking for a RR with an IP address as name
	# So go on.

	# name is either a string or a RR id
	if ( $argv{name} =~ /\D+/ ){
	    # argument has non-digits.  It's not an id.  Look it up as name
	    if ( my $rr = RR->search(name=>$argv{name})->first ){
		$argv{name} = $rr->id;
	    }else{
		# No use searching for a non-digit string in the name field
		$argv{name} = 0;
	    }
	}
    }

    # Proceed as a regular search
    return $class->SUPER::search(%argv, $opts);
}

############################################################################
=head2 search_like -  Search for device objects.  Allow substrings

    We override the base class to allow 'name' to be searched as 
    part of a hostname

  Arguments: 
    Hash with key/value pairs

  Returns: 
    Array of Device objects or iterator

  Exampless:
    my @switches = Device->search_like(name=>'-sw');

=cut
sub search_like {
    my ($class, %argv) = @_;
    $class->isa_class_method('search_like');

    if ( exists $argv{name} ){
	if ( my @rrs = RR->search_like(name=>$argv{name}) ){
	    return map { $class->search(name=>$_) } @rrs;
	}
	$logger->debug("Device::search_like: $argv{name} not found");
	return;
    }else{
	return $class->SUPER::search(%argv);
    }
}


############################################################################
=head2 assign_name - Determine and assign correct name to device

    This method will try to find or create an appropriate 
    Resource Record for a Device, given a hostname or ip address.

  Arguments:  
    hostname or IP address (string)

  Returns:    
    RR object if successful

  Examples:
    my $rr = Device->assign_name($host)

=cut
sub assign_name {
    my ($class, $host) = @_;
    $class->isa_class_method('assign_name');

    my $rr;
    if ( $rr = RR->search(name=>$host)->first ){
	$logger->debug("Name $host exists in DB");
	return $rr;
    }
    # An RR matching $host does not exist
    my ($ip, $fqdn);
    if ( $host =~ /$IPV4|$IPV6/ ){
	$ip = $host;
	# we were given an IP address
	if ( my $ipb = Ipblock->search(address=>$ip)->first ){
	    if ( $ipb->interface && ( my $dev = $ipb->interface->device ) ){
		# We have a Device with that IP.  Return its name.
		return $dev->name;
	    }
	}
    }else{
	# We were given a name (not an address)
	# Resolve to an IP address
	if ( $ip = ($dns->resolve_name($host))[0] ){
	    $logger->debug("Device::assign_name: $host resolves to $ip");
	}else{
	    # Name does not resolve
	    $logger->debug("Device::assign_name: $host does not resolve");
	}
    }
    if ( $ip ){
	# At this point, we were either passed an IP
	# or we got it from DNS.  The idea is to obtain a FQDN
	if ( $fqdn = $dns->resolve_ip($ip) ){
	    $logger->debug("Device::assign_name: $ip resolves to $fqdn");
	    if ( my $rr = RR->search(name=>$fqdn)->first ){
		$logger->debug("Device::assign_name: RR $fqdn already exists in DB");
		return $rr;
	    }
	}else{
	    # No reverse resolution.
	    # TODO: Try to determine the domain name based on the subnet
	    # (use SubnetZone)
	}
    }
    # If we do not yet have a fqdn, just use what we've got
    $fqdn ||= $host;

    # Now we have a fqdn. First, check if we have a matching domain
    my $mname;
    if ( my @sections = split /\./, $fqdn ){

	# Notice that we search the whole string.  That's because
	# the hostname part might have dots.  The Zone search method
	# will take care of that.
	if ( my $zone = (Zone->search(mname=>$fqdn))[0] ){
	    $mname = $zone->mname;
	    $host = $fqdn;
	    $host =~ s/\.$mname//;
	}else{
	    $logger->debug("Device::assign_name: $fqdn not found");

	    # Assume the zone to be everything to the right
	    # of the first dot. This might be a wrong guess
	    # but it is as close as I can get.
	    $host  = shift @sections;
	    $mname = join '.', @sections;
	}
    }

    # This will create the Zone object if necessary
    $rr = RR->insert({name => $host, zone => $mname});
    $logger->info(sprintf("Inserted new RR: %s", $rr->get_label));
    return $rr;
}

############################################################################
=head2 insert - Insert new Device
    
    We override the insert method for extra functionality:
     - More intelligent name assignment
     - Assign defaults
     - Assign contact lists

  Arguments:
    Arrayref with Device fields and values, plus:
    contacts    - ContactList object(s) (array or scalar)
  Returns:
    New Device object

  Examples:
    my $newdevice = Device->insert(name=>'device1');

=cut
sub insert {
    my ($class, $argv) = @_;
    $class->isa_class_method('insert');

    # name is required
    if ( !exists($argv->{name}) ){
	$class->throw_fatal('Missing required arguments: name');
    }


    # Get the default owner entity from config
    my $config_owner  = Netdot->config->get('DEFAULT_DEV_OWNER');
    my $default_owner = Entity->search(name=>$config_owner)->first;

    # Assign defaults
    # These will be overridden by the given arguments
    my %devtmp = (community        => 'public',
		  monitored        => 1,
		  customer_managed => 0,
		  date_installed   => $class->timestamp,
		  owner            => $default_owner,
		  collect_arp      => 0,
		  collect_fwt      => 0,
		  canautoupdate    => 0,
		  maint_covered    => 0,
		  monitor_config   => 0,
		  monitorstatus    => 0,
		  snmp_bulk        => 0,
		  snmp_managed     => 0,
		  snmp_polling     => 0,
		  );

    # Add given args (overrides defaults).
    # Extract special arguments that affect the inserted device
    my (@contacts, $info);
    foreach my $key ( keys %{$argv} ){
	if ( $key eq 'contacts' ){
	    @contacts = $argv->{contacts};
	}elsif ( $key eq 'info' ){
	    $info = $argv->{info};
	    $devtmp{snmp_managed} = 1;
	}else{
	    $devtmp{$key} = $argv->{$key};
	}
    }
    if ( exists $devtmp{snmp_managed} ){
	if ( !$devtmp{snmp_managed} ){
	    # Means it's being set to 0 or undef
	    # Turn off other flags
	    $devtmp{canautoupdate} = 0;
	    $devtmp{snmp_polling}  = 0;
	    $devtmp{collect_arp}   = 0;
	    $devtmp{collect_fwt}   = 0;
	}
    }


    ###############################################
    # Assign the correct name
    # argument 'name' can be passed either as a RR object
    # or as a string.
    if ( ref($argv->{name}) =~ /RR/ ){
	# We are being passed the RR object
	$devtmp{name} = $argv->{name};
    }else{
	# A string hostname was passed
	$devtmp{name} = $class->assign_name( $argv->{name} );
    }
    
    if ( my $dbdev = $class->search(name=>$devtmp{name})->first ){
	$class->throw_user(sprintf("Device::insert: Device %s already exists in DB as %s\n",
				   $argv->{name}, $dbdev->fqdn));
    }

    $class->_validate_args(\%devtmp);
    my $self = $class->SUPER::insert( \%devtmp );
    
    if ( @contacts ){
	$self->add_contact_lists(@contacts);
    }else{
	$self->add_contact_lists();
    }

    return $self;
}

############################################################################
=head2 get_snmp_info - SNMP-query a Device for general information
    
    This method can either be called on an existing object, or as a 
    class method.

  Arguments:
    Arrayref with the following keys:
     host         (required unless called as object method)
     communities
     version
     timeout
     retries
     bgp_peers
  Returns:
    Hash reference containing SNMP information
  Examples:
    
    Instance call:
    my $info = $device->get_snmp_info();

    Class call:
    my $info = Device->get_snmp_info(host=>$hostname, communities=>['public']);

=cut
sub get_snmp_info {
    my ($self, %args) = @_;
    
    my $target_address;

    if ( ref($self) ){
	if ( $self->snmp_target && int($self->snmp_target) != 0 ){
	    $target_address = $self->snmp_target->address;
	    $logger->debug("Device::get_snmp_info: Using configured target address: $target_address");
	}else{
	    $target_address = $self->fqdn;
	}
    }else {
	$self->throw_fatal('Device::get_snmp_info: Missing required parameters: host')
	    unless $args{host};
    }
    
    $target_address ||= $args{host};

    # Get SNMP session
    my %sess_args;
    $sess_args{host} = $target_address;
    foreach my $arg ( qw( communities version timeout retries ) ){
	$sess_args{$arg} = $args{$arg} if defined $args{$arg};
    }
    
    my $sinfo = $self->_get_snmp_session(%sess_args);
    
    # Get both name and IP for better error reporting
    my ($ip, $name);
    if ( $target_address =~ /$IPV4|$IPV6/ ){
	# looks like an IP address
	$ip   = $target_address;
	$name = $dns->resolve_ip($ip) || "?";
    }else{
	# looks like a name
	$name = $target_address;
	$ip   = ($dns->resolve_name($name))[0] || "?";
    }

    my %dev;
    $dev{community}    = $sinfo->snmp_comm;
    $dev{snmp_version} = $sinfo->snmp_ver;

    ################################################################
    # SNMP::Info methods that return hash refs
    my @SMETHODS = ( 'e_descr',
		     'interfaces', 'i_name', 'i_type', 'i_index', 'i_alias', 'i_description', 
		     'i_speed', 'i_up', 'i_up_admin', 'i_duplex', 'i_duplex_admin', 
		     'ip_index', 'ip_netmask', 'i_mac',
		     'i_vlan', 'i_vlan_membership', 'qb_v_name', 'v_name',
		     'bgp_peers', 'bgp_peer_id', 'bgp_peer_as');
    my %hashes;
    foreach my $method ( @SMETHODS ){
	$hashes{$method} = $sinfo->$method;
    }

    ################################################################
    # Device's global vars
    $dev{layers}      = $sinfo->layers;
    $dev{sysobjectid} = $sinfo->id;
    if ( defined $dev{sysobjectid} ){
	$dev{sysobjectid} =~ s/^\.(.*)/$1/;  # Remove unwanted first dot
	my %ignored = %{ $self->config->get('IGNOREDEVS') };
	if ( exists($ignored{$dev{sysobjectid}}) ){
	    $self->throw_user(sprintf("Product id %s set to be ignored\n", $dev{sysobjectid}));
	}
    }

    $dev{model}          = $sinfo->model();
    $dev{os}             = $sinfo->os_ver();
    $dev{physaddr}       = $sinfo->mac();
    # Check if it's valid
    if ( $dev{physaddr} ){
	if ( ! PhysAddr->validate($dev{physaddr}) ){
	    $logger->debug("Device::get_snmp_info: $name ($ip) invalid Base MAC: $dev{physaddr}");
	    delete $dev{physaddr};
	}	
    }

    if ( defined $dev{physaddr} ){
	# Check Spanning Tree stuff
	$dev{stp_type} = $sinfo->stp_ver();
    }

    $dev{sysname}        = $sinfo->name();
    $dev{sysdescription} = $sinfo->description();
    $dev{syscontact}     = $sinfo->contact();
    $dev{syslocation}    = $sinfo->location();
    $dev{productname}    = $hashes{'e_descr'}->{1};
    $dev{manufacturer}   = $sinfo->vendor();
    $dev{serialnumber}   = $sinfo->serial();

    # Try to guess product type based on name
    if ( my $NAME2TYPE = $self->config->get('DEV_NAME2TYPE') ){
	foreach my $str ( keys %$NAME2TYPE ){
	    if ( $name =~ /$str/ ){
		$dev{type} = $NAME2TYPE->{$str};
		last;
	    }
	}
    }

    # If not, assign type based on layers
    unless ( $dev{type} ){
	$dev{type}  = "Server"  if ( $sinfo->class =~ /Layer7/ );
	$dev{type}  = "Router"  if ( $sinfo->class =~ /Layer3/ && $sinfo->ipforwarding =~ 'forwarding' );
	$dev{type}  = "Switch"  if ( $sinfo->class =~ /Layer2/ );
	$dev{type}  = "Hub"     if ( $sinfo->class =~ /Layer1/ );
	$dev{type} |= "Switch"; # Last resort
    }

    if ( $sinfo->class =~ /Airespace/ ){
	$dev{type} = 'Wireless Controller';
	$dev{airespace} = {};
	# Fetch Airespace SNMP info
	$self->_get_airespace_snmp($sinfo, \%hashes);
    }

    # Set some defaults specific to device types
    if ( $dev{type} eq 'Router' ){
	$dev{bgplocalas}  =  $sinfo->bgp_local_as();
	$dev{bgpid}       =  $sinfo->bgp_id();
    }
    ################################################################
    # Interface stuff
    
    # Netdot Interface field name to SNMP::Info method conversion table
    my %IFFIELDS = ( name            => "i_description",
		     type            => "i_type",
		     description     => "i_alias",
		     speed           => "i_speed",
		     admin_status    => "i_up",
		     oper_status     => "i_up_admin", 
		     physaddr        => "i_mac", 
		     oper_duplex     => "i_duplex",
		     admin_duplex    => "i_duplex_admin",
		     );
    
    ##############################################
    # for each interface discovered...

    my $ifreserved = $self->config->get('IFRESERVED');

    foreach my $iid ( keys %{ $hashes{interfaces} } ){
	my $ifdescr = $hashes{interfaces}->{$iid};
	$dev{interface}{$iid}{number} = $iid;

	# check whether it should be ignored
	if ( defined $ifreserved ){
	    next if ( $ifdescr =~ /$ifreserved/i );
	}
	foreach my $field ( keys %IFFIELDS ){
	    $dev{interface}{$iid}{$field} = $hashes{$IFFIELDS{$field}}->{$iid} 
	    if ( defined($hashes{$IFFIELDS{$field}}->{$iid}) && 
		 $hashes{$IFFIELDS{$field}}->{$iid} =~ /\w+/ );
	}


	# Check if physaddr is valid
	if ( my $physaddr = $dev{interface}{$iid}{physaddr} ){
	    if ( ! PhysAddr->validate($physaddr) ){
		$logger->debug("Device::get_snmp_info: $name ($ip): Int $ifdescr: Invalid MAC: $physaddr");
		delete $dev{interface}{$iid}{physaddr};
	    }	
	}

	# IP addresses and masks 
	foreach my $ip ( keys %{ $hashes{'ip_index'} } ){
	    if ( $hashes{'ip_index'}->{$ip} eq $iid ){
		if ( !Ipblock->validate($ip) ){
		    $logger->debug("Device::get_snmp_info: $name ($ip): Invalid IP: $ip");
		    next;
		}	
		$dev{interface}{$iid}{ips}{$ip}{address} = $ip;
		if ( my $mask = $hashes{'ip_netmask'}->{$ip} ){
		    $dev{interface}{$iid}{ips}{$ip}{mask} = $mask;
		}
	    }
	}
  
	# Airespace Interfaces that represent thin APs
	if ( exists $dev{airespace} ){
	    
	    # i_index value is different from iid in this case
	    my $ifindex = $hashes{'i_index'}->{$iid};
	    
	    if ( $ifindex =~ /$AIRESPACEIF/ ){
		my $ifname = $hashes{'i_name'}->{$iid};         # this has the name of the AP
		$dev{interface}{$iid}{name}        = $ifindex;  
		$dev{interface}{$iid}{description} = $ifname;

		# Notice that we pass a hashref to get the results appended.
		# This is somewhat confusing but necessary, since each AP might have
		# more than one interface, which would rewrite the local hash
		# if we were to just assign the result
		$self->_get_airespace_ap_info(hashes => \%hashes, 
					      iid    => $iid , 
					      info   => \%{$dev{airespace}{$ifname}} );
	    }
	}

	################################################################
	# Vlan info
	# 
	my ($vid, $vname);
	# This is the default vlan for this port
	if ( $vid = $hashes{'i_vlan'}->{$iid} ){
	    $dev{interface}{$iid}{vlans}{$vid}{vid} = $vid;
	}
	# These are all the vlans that are enabled on this port.
	# We might be able to get away with using only this one,
	# but just in case...
	if ( my $vm = $hashes{'i_vlan_membership'}->{$iid} ){
	    foreach my $vid ( @$vm ){
		$dev{interface}{$iid}{vlans}{$vid}{vid} = $vid;
	    }
	}
	# Get VLAN names
	foreach my $vid ( keys %{$dev{interface}{$iid}{vlans}} ){
	    $vname = $hashes{'qb_v_name'}->{$vid}; # Standard MIB
	    unless ( $vname ){
		# We didn't get a vlan name in the standard place
		# Try Cisco location
		# SNMP::Info should be doing this for me :-(
		if ( $sinfo->cisco_comm_indexing ){
		    my $hvname = $hashes{'v_name'};
		    foreach my $key ( keys %$hvname ){
			if ( $key =~ /^(\d+\.$vid)$/ ){
			    $vname = $hvname->{$key};
			    last;
			}
		    }
		}
	    }
	    $dev{interface}{$iid}{vlans}{$vid}{vname} = $vname if defined ($vname);
	}
    }

    ##############################################
    # Deal with BGP Peers
    # only proceed if we were told to discover peers, either directly or in the config file
    if ( $args{bgp_peers} || $self->config->get('ADD_BGP_PEERS')) {

	if ( scalar keys %{$hashes{'bgp_peers'}} ){
	    $logger->debug("Device::get_snmp_info: Checking for BGPPeers");
	    
	    my %qcache;  # Cache queries for the same AS
	    my $whois;  # Get the whois program path
	    if ( $self->config->get('DO_WHOISQ') ){
		# First Check if we have whois installed
		$whois = `which whois`;
		if ( $whois =~ /not found/i || $whois !~ /\w+/ ){
		    $whois = undef;
		    $logger->warn("Device::get_snmp_info: Whois queries enabled in config file but whois command not found.");
		}else{
		    chomp $whois;
		}
	    }

	    ##############################################
	    # for each BGP Peer discovered...
	    foreach my $peer ( keys %{$hashes{'bgp_peers'}} ) {
		$dev{bgppeer}{$peer}{address} = $peer;
		unless ( $dev{bgppeer}{$peer}{bgppeerid} = $hashes{'bgp_peer_id'}->{$peer} ){
		    $logger->warn("Could not determine BGP peer id of peer $peer");
		}
		my $asn = $hashes{'bgp_peer_as'}->{$peer};
		if ( ! $asn ){
		    $logger->warn("Could not determine AS number of peer $peer");
		}else{
		    $dev{bgppeer}{$peer}{asnumber}  = $asn;
		    $dev{bgppeer}{$peer}{asname}    = "AS $asn";
		    $dev{bgppeer}{$peer}{orgname}   = "AS $asn";
		    
		    if ( defined $whois ){
			# We enabled whois queries in config and we have the whois command
			$logger->debug("Device::get_snmp_info: Going to query WHOIS for $peer: (AS $asn)");
			
			# Query any configured WHOIS servers for more info about this AS
			# But first check if it has been found already
			if ( exists $qcache{$asn} ){
			    foreach my $key ( keys %{$qcache{$asn}} ){
				$dev{bgppeer}{$peer}{$key} = $qcache{$asn}{$key};
			    }
			}else{
			    my %servers = %{ $self->config->get('WHOIS_SERVERS') };
			    foreach my $server ( keys %servers ){
				my $cmd = "$whois -h $server AS$asn";
				$logger->debug("Device::get_snmp_info: Querying: $cmd");
				my @lines = `$cmd`;
				if ( grep /No.*found/i, @lines ){
				    $logger->debug("Device::get_snmp_info: $server AS$asn not found");
				}else{
				    foreach my $key ( keys %{$servers{$server}} ){
					my $exp = $servers{$server}->{$key};
					if ( my @l = grep /^$exp/, @lines ){
					    my (undef, $val) = split /:\s+/, $l[0]; #first line
					    $val =~ s/\s*$//;
					    $logger->debug("Device::get_snmp_info:: $server: Found $exp: $val");
					    $qcache{$asn}{$key} = $val;
					    $dev{bgppeer}{$peer}{$key} = $val;
					}
				    }
				    last;
				}
			    }
			}
		    }else{
			$logger->debug("Device::get_snmp_info: BGPPeer WHOIS queries disabled in config file");
		    }
		}
	    }
	}
    }else{
	$logger->debug("Device::get_snmp_info: BGP Peer discovery not enabled");
    }
    $logger->debug("Device::get_snmp_info: Finished getting SNMP info from $name ($ip)");
    return \%dev;
}


#########################################################################
=head2 snmp_update_all - Update SNMP info for every device in DB
    
  Arguments:
    communities   Arrayref of SNMP communities
    version       SNMP version
    timeout       SNMP timeout
    retries       SNMP retries
    add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
    subs_inherit  Flag. When adding subnets, have them inherit information from the Device
    bgp_peers     Flag. When discovering routers, update bgp_peers
    pretend       Flag. Do not commit changes to the database
  Returns:
    True if successful
    
  Examples:
    Device->snmp_update_all();

=cut
sub snmp_update_all {
    my ($class, %argv) = @_;
    $class->isa_class_method('snmp_update_all');
    my $start = time;

    my @devs   = $class->retrieve_all();
    my $device_count = $class->_snmp_update_list(devs=>\@devs);
    my $end = time;
    $logger->info(sprintf("All Devices updated. %d devices in %d seconds", 
			  $device_count, ($end-$start) ));

}

####################################################################################
=head2 snmp_update_block - Discover and/or update all devices in a given IP block
    
  Arguments:
    Hash with the following keys:
    block         IP block address in CIDR or dotted mask notation
    communities   Arrayref of SNMP communities
    version       SNMP version
    timeout       SNMP timeout
    retries       SNMP retries
    add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
    subs_inherit  Flag. When adding subnets, have them inherit information from the Device
    bgp_peers     Flag. When discovering routers, update bgp_peers
    pretend       Flag. Do not commit changes to the database

  Returns:
    True if successful
    
  Examples:
    Device->snmp_update_block("192.168.0.0/24");

=cut
sub snmp_update_block {
    my ($class, %argv) = @_;
    $class->isa_class_method('snmp_update_block');

    my $block;
    $class->throw_fatal("Missing required argument: IP block address")
	unless defined( $block = $argv{block} );
    delete $argv{block};

    # Get a list of host addresses for the given block
    my $hosts = Ipblock->get_host_addrs($block);

    $logger->debug("SNMP-discovering all devices in $block");
    my $start = time;

    # Call the more generic method
    $argv{hosts} = $hosts;
    my $device_count = $class->_snmp_update_list(%argv);

    my $end = time;
    $logger->info(sprintf("Devices in $block updated. %d devices in %d seconds", 
			  $device_count, ($end-$start) ));

}

####################################################################################
=head2 snmp_update_from_file - Discover and/or update all devices in a given file
    
  Arguments:
    Hash with the following keys:
    file          Path to file with list of hosts (IPs or hostnames) one per line
    communities   Arrayref of SNMP communities
    version       SNMP version
    timeout       SNMP timeout
    retries       SNMP retries
    add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
    subs_inherit  Flag. When adding subnets, have them inherit information from the Device
    bgp_peers     Flag. When discovering routers, update bgp_peers
    pretend       Flag. Do not commit changes to the database

  Returns:
    True if successful
    
  Examples:
    Device->snmp_update_from_file("/path/to/file");

=cut
sub snmp_update_from_file {
    my ($class, %argv) = @_;
    $class->isa_class_method('snmp_update_from_file');

    my $file;
    $class->throw_fatal("Missing required argument: file")
	unless defined( $file = $argv{file} );
    delete $argv{file};

    # Get a list of hosts from given file
    my $hosts = $class->_get_hosts_from_file($file);

    $logger->debug("SNMP-discovering all devices in $file");
    my $start = time;
    
    # Call the more generic method
    $argv{hosts} = $hosts;
    my $device_count = $class->_snmp_update_list(%argv);

    my $end = time;
    $logger->info(sprintf("Devices in $file updated. %d devices in %d seconds", 
			  $device_count, ($end-$start) ));

}


#########################################################################
=head2 discover - Insert or update a device after getting its SNMP info.

    Adjusts a number of settings when inserting, based on certain
    info obtained via SNMP.    
    
  Arguments:
    Hash containing the following keys:
    name          Host name (required)
    communities   Arrayref of SNMP communities
    version       SNMP version
    timeout       SNMP timeout
    retries       SNMP retries
    add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
    subs_inherit  Flag. When adding subnets, have them inherit information from the Device
    bgp_peers     Flag. When discovering routers, update bgp_peers
    pretend       Flag. Do not commit changes to the database
    info          Hashref with SNMP info (optional)

  Returns:
    New or existing Device object
  Examples:
    Device->discover(name=>$hostname, communities=>["public"]);
    Device->discover(name=>$hostname, info=>$info);

=cut
sub discover {
    my ($class, %argv) = @_;
    $class->isa_class_method('discover');

    my $name = $argv{name} || 
	$class->throw_fatal("Device::discover: Missing required arguments: name");

    my $info = $argv{info} if defined $argv{info};
    my $dev;

    if ( $dev = Device->search(name=>$name)->first ){
	$logger->debug("Device::discover: Device $name already exists in DB");
    }else{
	$logger->info("Device $name does not yet exist. Inserting.");
	unless ( $info ){
	    # Get relevant snmp args
	    my %snmpargs;
	    $snmpargs{host} = $name;
	    foreach my $field ( qw(communities version timeout retries bgp_peers) ){
		$snmpargs{$field} = $argv{$field} if defined ($argv{$field});
	    }
	    $info = $class->_exec_timeout($name, sub { return $class->get_snmp_info(%snmpargs) });
	}
	
	# Set some values in the new Device based on the SNMP info obtained
	my %devtmp = (name          => $name,
		      snmp_managed  => 1,
		      canautoupdate => 1,
		      community     => $info->{community},
		      snmp_version  => $info->{snmp_version},
		      );
	
	if ( $info->{layers} ){
	    # We collect rptrAddrTrackNewLastSrcAddress from hubs
	    if ( $class->_layer_active($info->{layers}, 1) ){
		$devtmp{collect_fwt} = 1;
	    }
	    if ( $class->_layer_active($info->{layers}, 2) ){
		$devtmp{collect_fwt} = 1;
	    }
	    if ( $class->_layer_active($info->{layers}, 3) ){
		$devtmp{collect_arp} = 1;
	    }
	}
	# Catch any other Device fields passed to us
	foreach my $field ( $class->meta_data->get_column_names ){
	    if ( defined $argv{$field} && !defined $devtmp{$field} ){
		$devtmp{$field} = $argv{$field};
	    }
	}
	# Insert the new Device
	$dev = $class->insert(\%devtmp);
    }
    
    # Get relevant snmp_update args
    my %uargs;
    foreach my $field ( qw( add_subnets subs_inherit bgp_peers pretend ) ){
	$uargs{$field} = $argv{$field} if defined ($argv{$field});
    }
    $uargs{info} = $info;

    # Update Device with SNMP info obtained
    $dev->snmp_update(%uargs);
    
    return $dev;
}

#########################################################################
=head2 arp_update_all - Update ARP cache from every device in DB
    
  Arguments:
    None
  Returns:
    True if successful
  Examples:
    Device->arp_update_all();

=cut
sub arp_update_all {
    my ($class) = @_;
    $class->isa_class_method('arp_update_all');

    my @alldevs = $class->retrieve_all();
    $logger->debug("Fetching ARP tables from all devices in the database");
    return $class->_arp_update_list(list=>\@alldevs);
}

#########################################################################
=head2 arp_update_block - Update ARP cache from every device within an IP block
    
  Arguments:
    block - IP block in CIDR notation
  Returns:
    True if successful
  Examples:
    Device->arp_update_block();

=cut
sub arp_update_block {
    my ($class, %argv) = @_;
    $class->isa_class_method('arp_update_block');

    defined $argv{block} || $class->throw_fatal("Missing required arguments: block");
    my $devs = $class->get_all_from_block($argv{block});

    $logger->debug("Fetching ARP tables from all devices in block $argv{block}");
    return $class->_arp_update_list(list=>$devs);
}

#########################################################################
=head2 arp_update_from_file - Update ARP cache from devices in given file
    
  Arguments:
    file - Path to file with list of hosts
  Returns:
    True if successful
  Examples:
    Device->arp_update_from_file();

=cut
sub arp_update_from_file {
    my ($class, %argv) = @_;
    $class->isa_class_method('arp_update_from_file');

    my $file;
    $class->throw_fatal("Missing required argument: file")
	unless defined( $file = $argv{file} );

    # Get a list of hosts from given file
    my $devs = $class->_get_devs_from_file($file);

    $logger->debug("Fetching ARP tables from all devices file: $file");
    return $class->_arp_update_list(list=>$devs);
}

#########################################################################
=head2 fwt_update_all - Update FWT for every device in DB
    
  Arguments:
    None
  Returns:
    True if successful
  Examples:
    Device->fwt_update_all();

=cut
sub fwt_update_all {
    my ($class) = @_;
    $class->isa_class_method('fwt_update_all');
    
    my @alldevs = $class->retrieve_all();
    $logger->debug("Fetching forwarding tables from all devices in the database");
    return $class->_fwt_update_list(list=>\@alldevs);
}

#########################################################################
=head2 fwt_update_block - Update FWT for all devices within a IP block
    
  Only devices already in the DB will be queried.  To include all devices
  in a given subnet, run snmp_update_block() first.
    
  Arguments:
    block - IP block in CIDR notation
  Returns:
    True if successful
  Examples:
    Device->fwt_update_block();

=cut
sub fwt_update_block {
    my ($class, %argv) = @_;
    $class->isa_class_method('fwt_update_block');

    defined $argv{block} || $class->throw_fatal("Missing required arguments: block");
    my $devs = $class->get_all_from_block($argv{block});

    $logger->debug("Fetching forwarding tables from all devices in $argv{block}");
    return $class->_fwt_update_list(list=>$devs);
}

#########################################################################
=head2 fwt_update_from_file - Update FWT for all devices in given file
    
  Arguments:
    file - Path to file with list of hosts
  Returns:
    True if successful
  Examples:
    Device->fwt_update_block();

=cut
sub fwt_update_from_file {
    my ($class, %argv) = @_;
    $class->isa_class_method('fwt_update_block');

    my $file;
    $class->throw_fatal("Missing required argument: file")
	unless defined( $file = $argv{file} );

    # Get a list of hosts from given file
    my $devs = $class->_get_devs_from_file($file);

    $logger->debug("Fetching forwarding tables from all devices in $argv{block}");
    return $class->_fwt_update_list(list=>$devs);
}

#########################################################################
=head2 get_all_from_block - Retrieve devices with addresses within an IP block

  Arguments:
    block - IP block in CIDR notation
  Returns:
    Array ref of Device objects
  Examples:
    my $devs = Device->get_all_from_block('192.168.1.0/24');

=cut
sub get_all_from_block {
    my ($class, $block) = @_;
    $class->isa_class_method('fwt_update_block');

    defined $block || $class->throw_fatal("Missing required arguments: block");

    # Get a list of host addresses for the given block
    my $hosts = Ipblock->get_host_addrs($block);
    my %devs;
    foreach my $ip ( @$hosts ){
	if ( my $dev = $class->search(name=>$ip)->first ){
	    $devs{$dev->id} = $dev; #index by id to avoid duplicates
	}
    }
    my @devs = values %devs;
    return \@devs;
}

=head1 INSTANCE METHODS

=cut
############################################################################
############################################################################
########################## INSTANCE METHODS ################################
############################################################################
############################################################################


############################################################################
=head2 add_contact_lists - Add Contact Lists to Device
    
  Arguments:
    Array reference of ContactList objects or single ContactList object.
    If called with no arguments, it assigns the default contact list.
  Returns:
    Array of DeviceContacts objects
  Examples:

    $self->add_contact_lists(\@cl);
    
=cut
sub add_contact_lists{
    my ($self, $argv) = @_;
    $self->isa_object_method('add_contact_lists');

    my @cls;
    if ( ! $argv ){
	my $confcl = $self->config->get('DEFAULT_CONTACTLIST');
	if ( my $default_cl = ContactList->search(name=>$confcl)->first ){
	    push @cls, $default_cl;
	}else{
	    $logger->warn("add_contact_lists: Default Contact List not found: $confcl");
	    return;
	}
    }else{
	if( ref($argv) eq "ARRAY" ){
	    @cls = @{ $argv };
	}else{
	    push @cls, $argv;
	}
    }
    my @ret;
    foreach my $cl ( @cls ){
	my $n = DeviceContacts->insert({ device => $self, contactlist => $cl });
	push @ret, $n;
    }
    return @ret;
}

############################################################################
=head2 has_layer - Determine if Device performs a given OSI layer function
    

  Arguments:
    Layer number
  Returns:
    True/False

  Examples:
    $device->has_layer(2);

=cut
sub has_layer {
    my ($self, $layer) = @_;
    $self->isa_object_method('has_layer');

    my $layers = $self->layers();
    return undef unless defined($layers);
    return undef unless length($layers);
    return substr($layers,8-$layer, 1);
}

#########################################################################
=head2 arp_update - Update ARP cache in DB
    
  Arguments:
    Hash with the following keys:
    cache          - hash reference with arp cache info (optional)
    no_update_macs - Do not update MAC addresses (bool)
    no_update_ips  - Do not update IP addresses (bool)
    intmacs        - List of MAC addresses that belong to interfaces (optional)
  Returns:
    True if successful
    
  Examples:
    $self->arp_update();

=cut
sub arp_update {
    my ($self, %argv) = @_;
    $self->isa_object_method('arp_update');

    my $host      = $self->fqdn;
    my $dbh       = $self->db_Main;
    my $timestamp = $self->timestamp;

    unless ( $self->collect_arp ){
	$logger->debug("$host excluded from ARP collection. Skipping");
	return;
    }
    # Fetch from SNMP if necessary
    my %args;
    $args{intmacs} = $argv{intmacs} if defined $argv{intmacs};
    my $cache = $argv{cache} || $self->_exec_timeout($host, sub { return $self->_get_arp_from_snmp(%args) });
    
    unless ( keys %$cache ){
	$logger->info("$host: ARP cache empty");
	return;	
    }
    
    # Measure only db update time
    my $start = time;
    $logger->debug("$host: Updating ARP cache");
  
    # Create ArpCache object
    my $ac = ArpCache->insert({device  => $self,
			       tstamp  => $timestamp});

    unless ( $argv{no_update_macs} ){
	$self->_update_macs_from_cache([$cache]);
    }
    unless ( $argv{no_update_ips} ){
	$self->_update_ips_from_cache([$cache]);
    }
    
    my ($arp_count, @ce_updates);

    foreach my $idx ( keys %$cache ){
	my $if = Interface->search(device=>$self, number=>$idx)->first;
	unless ( $if ){
	    $logger->error("Device::arp_update: $host: Interface number $idx does not exist!  Run device update.");
	    next;
	}
	foreach my $mac ( keys %{$cache->{$idx}} ){
	    $arp_count++;
	    my $ip = $cache->{$idx}->{$mac};
	    push @ce_updates, {
		arpcache  => $ac->id,
		interface => $if->id,
		ipaddr    => Ipblock->ip2int($ip),
		physaddr  => $mac,
	    };
	}
    }
    ArpCacheEntry->fast_insert(list=>\@ce_updates);

    # Set the last_arp timestamp
    $self->update({last_arp=>$self->timestamp});

    my $end = time;
    $logger->info(sprintf("$host: ARP cache updated. %s entries in %d seconds", 
			  $arp_count, ($end-$start) ));

    return 1;
}

#########################################################################
=head2 fwt_update - Update Forwarding Table in DB
    
  Arguments:
    Hash with the following keys:
    fwt            - hash reference with FWT info (optional)
    no_update_macs - Do not update MAC addresses (bool)
    intmacs        - List of MAC addresses that belong to interfaces (optional)
  Returns:
    True if successful
    
  Examples:
    $self->fwt_update();

=cut
sub fwt_update {
    my ($self, %argv) = @_;
    $self->isa_object_method('fwt_update');

    my $host      = $self->fqdn;
    my $dbh       = $self->db_Main;
    my $timestamp = $self->timestamp;

    unless ( $self->collect_fwt ){
	$logger->debug("$host excluded from FWT collection. Skipping");
	return;
    }

    # Fetch from SNMP if necessary
    my %args;
    $args{intmacs} = $argv{intmacs} if defined $argv{intmacs};
    my $fwt = $argv{fwt} || $self->_exec_timeout($host, sub { return $self->_get_fwt_from_snmp(%args) });
    
    unless ( keys %$fwt ){
	$logger->info("$host: FWT empty");
	return;	
    }
    
    # Measure only db update time
    my $start = time;

    $logger->debug("$host: Updating Forwarding Table (FWT)");
    
    # Create FWTable object
    my $fw = FWTable->insert({device  => $self,
			      tstamp  => $timestamp});

    unless ( $argv{no_update_macs} ){
	$self->_update_macs_from_cache([$fwt]);
    }
    
    my @fw_updates;
    foreach my $idx ( keys %{$fwt} ){
	my $if = Interface->search(device=>$self, number=>$idx)->first;
	unless ( $if ){
	    $logger->error("Device::fwt_update: $host: Interface number $idx does not exist!");
	    next;
	}
	foreach my $mac ( keys %{$fwt->{$idx}} ){
	    push @fw_updates, {
		fwtable   => $fw->id,
		interface => $if->id,
		physaddr  => $mac,
	    };
	}
    }

    $logger->debug("$host: Updating FWTable...");
    FWTableEntry->fast_insert(list=>\@fw_updates);
    
    ##############################################################
    # Set the last_fwt timestamp
    $self->update({last_fwt=>$self->timestamp});

    my $end = time;
    $logger->info(sprintf("$host: FWT updated. %s entries in %d seconds", 
			  scalar @fw_updates, ($end-$start) ));
    
    return 1;
}

############################################################################
=head2 delete - Delete Device object
    
    We override the insert method for extra functionality:
     - Remove orphaned Resource Records if necessary

  Arguments:
    None
  Returns:
    True if successful

  Examples:
    $device->delete();

=cut
sub delete {
    my ($self) = @_;
    $self->isa_object_method('delete');

    my $rrid = ( $self->name )? $self->name->id : "";
    
    $self->SUPER::delete();

    # If the RR had a RRADDR, it was probably deleted.  
    # Otherwise, we do it here.
    if ( my $rr = RR->retrieve($rrid) ){
	$rr->delete() unless $rr->arecords;
    }
}

############################################################################
=head2 short_name - Get/Set name of Device
   
    The device name is actually a pointer to the Resorce Record (RR) table

  Arguments:
    name string (optional)
  Returns:
    Short name of Device (Resource Record Name)
  Examples:
    $device->short_name('switch1');

=cut
    
sub short_name {
    my ($self, $name) = @_;
    $self->isa_object_method('short_name');
    
    my $rr;
    $self->throw_fatal("Device has no RR defined") 
	unless ( int($rr = $self->name) != 0 );
    if ( $name ){
	$rr->name($name);
	$rr->update;
    }
    return $rr->name;
}


############################################################################
=head2 fqdn - Get Fully Qualified Domain Name
   
  Arguments:
    None
  Returns:
    FQDN string
  Examples:
   print $device->fqdn(), "\n";

=cut

sub fqdn {
    my $self = shift;
    $self->isa_object_method('short_name');
    
    return $self->name->get_label;
}

############################################################################
=head2 update - Update Device in Database
    
    We override the update method for extra functionality:
      - Update 'last_updated' field with current timestamp
      - snmp_managed flag turns off all other snmp access flags

  Arguments:
    Hash ref with Device fields
  Returns:
    Updated Device object
  Example:
    $device->update( \%data );

=cut

sub update {
    my ($self, $argv) = @_;
    
    # Update the timestamp
    $argv->{last_updated} = $self->timestamp;

    if ( exists $argv->{snmp_managed} ){
	if ( !$argv->{snmp_managed} ){
	    # Means it's being set to 0 or undef
	    # Turn off other flags
	    $argv->{canautoupdate} = 0;
	    $argv->{snmp_polling}  = 0;
	    $argv->{collect_arp}   = 0;
	    $argv->{collect_fwt}   = 0;
	}
    }
    $self->_validate_args($argv);
    return $self->SUPER::update($argv);
    
}

############################################################################
=head2 update_bgp_peering - Update/Insert BGP Peering information using SNMP info

    
  Arguments:
    Hash with the following keys
    peer - Hashref containing Peer SNMP info:
    address
    asname
    asnumber
    orgname
    bgppeerid
    oldpeerings - Hash ref containing old peering objects
  Returns:
    BGPPeering object or undef if error
  Example:
    
=cut

sub update_bgp_peering {
    my ($self, %argv) = @_;
    my ($peer, $oldpeerings) = @argv{"peer", "oldpeerings"};
    $self->isa_object_method('update_bgp_peering');

    $self->throw_fatal("Missing Required Arguments: peer, oldpeerings")
	unless ( $peer && $oldpeerings );
    my $host = $self->fqdn;

    my $p; # bgppeering object

    # Check if we have basic Entity info
    my $entity;
    if ( exists ($peer->{asname}) || 
	 exists ($peer->{orgname})|| 
	 exists ($peer->{asnumber}) ){
	
	# Build Entity info
	#
	my $entityname = $peer->{orgname} || $peer->{asname};
	$entityname .= " ($peer->{asnumber})";
	my $type = (EntityType->search(name => "Peer"))[0] || 0;
	my %etmp = ( name     => $entityname,
		     asname   => $peer->{asname},
		     asnumber => $peer->{asnumber},
		     );
	
	# Check if Entity exists
	#
	if ( $entity = Entity->search(asnumber => $peer->{asnumber})->first ||
	     Entity->search(asname => $peer->{asname})->first               ||
	     Entity->search(name   => $peer->{orgname})->first
	     ){
	    # Update it
	    $entity->update( \%etmp );
	}else{
	    # Doesn't exist. Create Entity
	    #
	    $logger->info(sprintf("%s: Peer Entity %s not found. Inserting", 
				  $host, $entityname ));
	    
	    $entity = Entity->insert( \%etmp );
	    $logger->info(sprintf("%s: Created Peer Entity %s.", $host, $entityname));
	}

	# Make sure Entity has role "peer"
	my %eroletmp = ( entity => $entity, type => $type );
	my $erole;
	if ( $erole = EntityRole->search(%eroletmp)->first ){
	    $logger->debug(sprintf("%s: Entity %s already has 'Peer' role", 
				   $host, $entityname ));
	}else{
	    EntityRole->insert(\%eroletmp);
	    $logger->info(sprintf("%s: Added 'Peer' role to Entity %s", 
				   $host, $entityname ));
	}

    }else{
	$logger->warn( sprintf("%s: Missing peer info. Cannot associate peering %s with an entity", 
			       $host, $peer->{address}) );
    }
    $entity ||= 0;
    
    # Create a hash with the peering's info for update or insert
    my %pstate = (device      => $self,
		  entity      => $entity,
		  bgppeerid   => $peer->{bgppeerid},
		  bgppeeraddr => $peer->{address},
		  monitored   => 1);
	
    # Check if peering exists
    foreach my $peerid ( keys %{ $oldpeerings } ){

	my $oldpeer = $oldpeerings->{$peerid};
	if ( $oldpeer->bgppeeraddr eq $peer->{address} ){
	    
	    # Peering Exists.  
	    $p = $oldpeer;
	    
	    # Delete from list of old peerings
	    delete $oldpeerings->{$peerid};
	    last;
	}
    }
    if ( $p ){
	# Update in case anything has changed
	$p->update(\%pstate);
	$logger->debug(sprintf("%s: Updated Peering with: %s. ", $host, $entity->name));
	
    }else{
	# Peering Doesn't exist.  Create.
	#
	$p = BGPPeering->insert(\%pstate);
	$logger->info(sprintf("%s: Inserted new Peering with: %s. ", $host, $entity->name));
    }
    return $p;
}

############################################################################
=head2 snmp_update - Update Device in Database using SNMP info

    Updates an existing Device based on information gathered via SNMP.  
    This is exclusively an object method.

  Arguments:
    Hash with the following keys:
    info          Hashref with Device SNMP information. 
                  If not passed, this method will try to get it.
    communities   Arrayref of SNMP Community strings
    snmpversion   SNMP Version [1|2|3]
    add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
    subs_inherit  Flag. When adding subnets, have them inherit information from the Device
    bgp_peers     Flag. When discovering routers, update bgp_peers
    pretend       Flag. Do not commit changes to the database
    
  Returns:
    Updated Device object

  Example:
    my $device = $device->snmp_update();

=cut
sub snmp_update {
    my ($self, %argv) = @_;
    $self->isa_object_method('snmp_update');
    
    my $class = ref $self;
    my $start = time;

    $argv{bgp_peers} = defined($argv{bgp_peers}) ? 
	$argv{bgp_peers} : $self->config->get('ADD_BGP_PEERS');

    # Show full name in output
    my $host = $self->fqdn;

    # Get SNMP info
    my $snmpversion = $argv{snmp_version} || $self->snmp_version 
	|| $self->config->get('DEFAULT_SNMPVERSION');

    my $communities = $argv{communities} || [$self->community] || $self->config->get('DEFAULT_SNMPCOMMUNITIES');
    
    my $info = $argv{info} 
    || $class->_exec_timeout($host, sub { return $self->get_snmp_info(communities => $communities, 
								      version     => $snmpversion) });
    
    unless ( $info ){
	$logger->error("$host: No SNMP info received");
	return;	
    }
    unless ( ref($info) eq 'HASH' ){
	$self->throw_fatal("Invalid SNMP data structure");
    }
    
    # Pretend works by turning off autocommit in the DB handle and rolling back
    # all changes at the end
    if ( $argv{pretend} ){
	$logger->info("$host: Performing a dry-run");
	unless ( Netdot::Model->db_auto_commit(0) == 0 ){
	    $self->throw_fatal("Unable to set AutoCommit off");
	}
    }
    
    # Data that will be passed to the update method
    my %devtmp;

    # Assign Base MAC
    if ( my $address = $info->{physaddr} ) {
	# Look it up
	my $mac;
	if ( $mac = PhysAddr->search(address=>$address)->first ){
	    # The address exists
	    # (may have been discovered in fw tables/arp cache)
	    $mac->update({last_seen=>$self->timestamp});
	    $logger->debug("$host: Using existing $address as base bridge address");		
	}else{
	    # address is new.  Add it
	    my %mactmp = (address    => $address,
			  first_seen => $self->timestamp,
			  last_seen  => $self->timestamp 
			  );
	    $mac = PhysAddr->insert(\%mactmp);
	    $logger->info(sprintf("%s: Inserted new base MAC: %s", $host, $mac->address));
	}
	$devtmp{physaddr} = $mac->id;
    }else{
	$logger->debug("$host did not return base MAC");
    }

    # Serial Number
    unless ( $devtmp{serialnumber} = $info->{serialnumber} ){
    	$logger->debug("$host did not return serial number");
    }
    
    # Fill in some basic device info
    foreach my $field ( qw( community snmp_version layers sysdescription os collect_arp collect_fwt ) ){
	$devtmp{$field} = $info->{$field} if exists $info->{$field};
    }
    
    # Assign Product
    my $name = $info->{model} || $info->{productname};
    if ( defined $info->{sysobjectid} ){
	$devtmp{product} = Product->find_or_create( name           => $name,
						    description    => $name,
						    sysobjectid    => $info->{sysobjectid},
						    type           => $info->{type},
						    manufacturer   => $info->{manufacturer}, 
						    hostname       => $host,
						    );
    }
    
    # Set Local BGP info
    if( defined $info->{bgplocalas} ){
	$logger->debug(sprintf("%s: BGP Local AS is %s", $host, $info->{bgplocalas}));
	$devtmp{bgplocalas} = $info->{bgplocalas};
    }
    if( defined $info->{bgpid} ){
	$logger->debug(sprintf("%s: BGP ID is %s", $host, $info->{bgpid}));
	$devtmp{bgpid} = $info->{bgpid};
    }
    
    # Spanning Tree stuff
    $devtmp{stp_type}    = $info->{stp_type};
    $devtmp{stp_enabled} = 1 if ( defined $info->{stp_type} && $info->{stp_type} ne 'unknown' );
    if ( $devtmp{stp_enabled} ){
	$logger->debug(sprintf("%s: Spanning Tree is enabled", $host));
	$logger->debug(sprintf("%s: Spanning Tree type is: %s", $host, $devtmp{stp_type}));
    }

    # Update Device object
    $self->update( \%devtmp );
    
    ##############################################
    # Add/Update Interfaces
    #
    # Do not update interfaces for these devices
    # (specified in config file)
    #
    my %ignored = %{ $self->config->get('IGNOREPORTS') };
    unless ( defined $info->{sysobjectid} && exists $ignored{$info->{sysobjectid}} ){
	
	# How to deal with new subnets
	# First grab defaults from config file
	my $add_subnets_default  = $self->config->get('ADDSUBNETS');
	my $subs_inherit_default = $self->config->get('SUBNET_INHERIT_DEV_INFO');
	
	# Then check what was passed
	my $add_subnets   = ( $info->{type} eq "Router" && defined($argv{add_subnets}) ) ? 
	    $argv{add_subnets} : $add_subnets_default;
	my $subs_inherit = ( $add_subnets && defined($argv{subs_inherit}) ) ? 
	    $argv{subs_inherit} : $subs_inherit_default;
	
 	# Get old IPs (if any)
 	my %oldips;
	if ( my $devips = $self->get_ips ){
	    map { $oldips{$_->address} = $_ } @{ $devips };
	}
	
 	# Get old Interfaces (if any).
 	my ( %oldifs, %oldifsbynumber, %oldifsbyname );

	# Flag for determining if IP info has changed
	my $ipv4_changed = 0;
	my $ipv6_changed = 0;
	
	##############################################
	# Try to solve the problem with devices that change ifIndex
	# We use the name as the most stable key to identify interfaces
	my %tmpifs;
	$tmpifs{tmp}++; # Just so we can start the loop
	while ( keys %tmpifs ){
	    delete $tmpifs{tmp};

	    # Index by object id. 	
	    map { $oldifs{$_->id} = $_ } $self->interfaces();
	    
	    # Index by interface name (ifDescr) and number (ifIndex)
	    foreach my $id ( keys %oldifs ){
		$oldifsbynumber{$oldifs{$id}->number} = $oldifs{$id}
		if ( defined($oldifs{$id}->number) );
		
		$oldifsbyname{$oldifs{$id}->name} = $oldifs{$id}
		if ( defined($oldifs{$id}->name) );
	    }
	    
	    foreach my $newif ( sort keys %{ $info->{interface} } ) {
		my $newname   = $info->{interface}->{$newif}->{name};
		my $newnumber = $info->{interface}->{$newif}->{number};
		my $oldif;
		if ( defined $newname && ($oldif = $oldifsbyname{$newname}) ){
		    # Found one with the same name
		    
		    $logger->debug(sprintf("%s: Interface with name %s found", 
					   $host, $oldif->name));
		    
		    if ( $oldif->number ne $newnumber ){
			# New and old numbers do not match for this name
			$logger->info(sprintf("%s: Interface %s had number: %s, now has: %s", 
					      $host, $oldif->name, $oldif->number, $newnumber));
			
			# Check if a third one has that number
			my $thirdif;
			if ( ($thirdif = $oldifsbynumber{$newnumber}) &&
			    $thirdif->name ne $newname ){

			    # The number field is unique in the DB, 
			    # so we need to assign temporary numbers
			    my $rand = int(rand 1000) + 1;
			    my $tmp = $thirdif->number . "-" . $rand;
			    $thirdif->update({number=>$tmp});
			    $tmpifs{$thirdif->id}++;
			}
		    }
		    
		}elsif ( exists $oldifsbynumber{$newnumber} ){
		    # Name not found, but found one with the same number
		    $oldif = $oldifsbynumber{$newnumber};
		    $logger->debug(sprintf("%s: Interface with number %s found", 
					   $host, $oldif->number));
		}
		
		my $if;
		if ( $oldif ){
		    # Remove the new interface's ip addresses from list to delete
		    foreach my $newaddr ( keys %{$info->{interface}->{$newif}->{ips}} ){
			delete $oldips{$newaddr} if exists $oldips{$newaddr};
		    }
		    $if = $oldif;
		}else{
		    # Interface does not exist.  Add it.
		    my $ifname = $info->{interface}->{$newif}->{name} || $newnumber;
		    $logger->info(sprintf("%s: Interface %s (%s) not found. Inserting.", 
					  $host, $newnumber, $ifname));
		    
		    my %args = (device      => $self, 
				number      => $newif, 
				name        => $ifname,
				);
		    # Make sure we can write to the description field when
		    # device is airespace - we store the AP name as the int description
		    $args{overwrite_descr} = 1 if ( $info->{airespace} );

		    $if = Interface->insert(\%args);
		}
		
		$self->throw_fatal("$host: Could not find or create interface: $newnumber") 
		    unless $if;
		
		# Now update it with snmp info
		$if->snmp_update(info         => $info->{interface}->{$newif},
				 add_subnets  => $add_subnets,
				 subs_inherit => $subs_inherit,
				 ipv4_changed => \$ipv4_changed,
				 ipv6_changed => \$ipv6_changed,
				 );
		
		$logger->debug(sprintf("%s: Interface %s (%s) updated", 
				       $host, $if->number, $if->name));
		
		# Remove this interface from list to delete
		delete $oldifs{$if->id} if exists $oldifs{$if->id};  

		# Remove from list of temporarily-numbered ifs
		delete $tmpifs{$if->id} if exists $tmpifs{$if->id};  
		
		
	    } #end foreach my newif
	} # end while 

	##############################################
	# remove each interface that no longer exists
	#
	foreach my $id ( keys %oldifs ) {
	    my $if = $oldifs{$id};
	    $logger->info(sprintf("%s: Interface %s,%s no longer exists.  Removing.", 
				  $host, $if->number, $if->name));
	    $if->delete();
	}
	
	##############################################
	# remove ip addresses that no longer exist
	foreach my $oldip ( keys %oldips ){
	    my $ip = $oldips{$oldip};
	    # Check that it still exists 
	    # (could have been deleted if its interface was deleted)
	    next unless ( defined $ip && ref($ip) );
	    
	    $logger->info(sprintf("%s: IP %s no longer exists.  Removing.", 
				  $host, $ip->address));
	    $ip->delete(no_update_tree=>1);
	    $ipv4_changed = 1;
	}
	
	# Rebuild IP space tree
	# Notice we do this at the end instead of per IP to speed things up
	Ipblock->build_tree(4) if $ipv4_changed;
	Ipblock->build_tree(6) if $ipv6_changed;
    }
    ###############################################################
    # Add/Update/Delete BGP Peerings
    #
    if ( $argv{bgp_peers} ){
	
	# Get current bgp peerings
	#
	my %oldpeerings;
	map { $oldpeerings{ $_->id } = $_ } $self->bgppeers();
	
	# Update BGP Peerings
	#
	foreach my $peer ( keys %{$info->{bgppeer}} ){
	    $self->update_bgp_peering(peer        => $info->{bgppeer}->{$peer},
				      oldpeerings => \%oldpeerings);
	}
	# remove each BGP Peering that no longer exists
	#
	foreach my $peerid ( keys %oldpeerings ) {
	    my $p = $oldpeerings{$peerid};
	    $logger->info(sprintf("%s: BGP Peering with %s (%s) no longer exists.  Removing.", 
				   $host, $p->entity->name, $p->bgppeeraddr));
	    $p->delete();
	}
    }
    
    ##############################################################
    # Update A records for each IP address
    #
    # Get addresses that the main Device name resolves to
    my @hostnameips;
    if ( @hostnameips = $dns->resolve_name($host) ){
	$logger->debug(sprintf("Device::snmp_update: %s resolves to: %s",
			       $host, (join ", ", @hostnameips)) );
    }
    
    foreach my $ip ( @{ $self->get_ips() } ){
	$ip->update_a_records(\@hostnameips);
    }
    
    ##############################################################
    # Assign the snmp_target address if it's not there yet
    #
    if ( !defined($self->snmp_target) || $self->snmp_target == 0 ){
	my $ipb;
	if ( my $rr = RR->search(name=>$self->fqdn)->first ){
	    if ( my $rraddr = ($rr->arecords)[0] ){
		$ipb = $rraddr->ipblock;
	    }
	}elsif ( scalar @hostnameips ){
	    $ipb = Ipblock->search(address=>$hostnameips[0])->first;
	}
	if ( $ipb ){
	    $self->update({snmp_target=>$ipb});
	    $logger->info(sprintf("%s: SNMP target address set to %s", 
				  $host, $self->snmp_target->address));
	}else{
	    $logger->error("Could not determine main IP address!");
	}
    }

    ##############################################################
    # Airespace APs
    #
    if ( exists $info->{airespace} ){

	my %oldaps;

	# Get all the APs we already had
	foreach my $int ( $self->interfaces ){
	    if ( $int->name =~ /$AIRESPACEIF/ ){
		my $apmac = $int->number;
		$apmac =~ s/^(.*)\.\d$/$1/;
		$oldaps{$apmac}++;
	    }
	}
		
	# Insert or update the APs returned
	# When creating, we turn off snmp_managed because
	# the APs don't actually do SNMP
	# We also inherit some values from the Controller
	foreach my $ap ( keys %{ $info->{airespace} } ){
	    my $dev;
	    unless ( $dev = $class->search(name=>$ap)->first ){
		$dev = $class->insert({name          => $ap,
				       snmp_managed  => 0,
				       canautoupdate => 0,
				       owner         => $self->owner,
				       used_by       => $self->used_by,
				       contacts      => map { $_->contactlist } $self->contacts,
				      });
	    }
	    $dev->snmp_update(info=>$info->{airespace}->{$ap});

	    my $apmac = $info->{airespace}->{$ap}->{physaddr};
	    delete $oldaps{$apmac};
	}

	# Notify about the APs no longer associated with this controller
	# Note: If the AP was removed from the network, it will have
	# to be removed from Netdot manually.  This avoids the unwanted case of
	# removing APs that change controllers, thus losing their manually-entered information
	# (location, links, etc)
	foreach my $mac ( keys %oldaps ){
	    if ( my $dev = Device->search(physaddr=>$mac)->first ){
		$logger->warn(sprintf("AP %s (%s) no longer associated with controller: %s", 
				      $mac, $dev->short_name, $host));
	    }
	}
	
    }

    my $end = time;
    $logger->debug(sprintf("%s: SNMP update completed in %d seconds", 
			  $host, ($end-$start)));

    if ( $argv{pretend} ){
	$logger->debug("$host: Rolling back changes");
	eval {
	    $self->dbi_rollback;
	};
	if ( my $e = $@ ){
	    $self->throw_fatal("Rollback Failed!: $e");
	}
	$logger->debug("Turning AutoCommit back on");
	unless ( Netdot::Model->db_auto_commit(1) == 1 ){
	    $self->throw_fatal("Unable to set AutoCommit on");
	}
    }

    return $self;
}

############################################################################
=head2 add_ip - Add an IP address (assumes only one interface)
   
  Arguments:
    IP address in dotted-quad notation
  Returns:
    Ipblock object
  Examples:
    $device->add_ip('10.0.0.1');

=cut
sub add_ip {
    my ($self, $address) = @_;
    $self->isa_object_method('add_ip');
    my $int = ($self->interfaces)[0];
    my $n = Ipblock->insert({address=>$address, interface=>$int, status=>'Static'});
    return $n;
}
############################################################################
=head2 get_ips - Get all IP addresses from a device
   
  Arguments:
    Hash with the following keys:
       sort_by  [address|interface]
  Returns:
    Arrayref of Ipblock objects
  Examples:
    print $_->address, "\n" foreach $device->get_ips( sort_by => 'address' );

=cut

sub get_ips {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_ips');
    
    $argv{sort_by} ||= "address";
    
    my @ips;
    if ( $argv{sort_by} eq "address" ){
	@ips = Ipblock->search_devipsbyaddr($self->id);
    }elsif ( $argv{sort_by} eq "interface" ){
	@ips = Ipblock->search_devipsbyint($self->id);
    }else{
	$self->throw_fatal("Invalid sort criteria: $argv{sort_by}");
    }
    return \@ips;
}

############################################################################
=head2 get_subnets  - Get all the subnets in which this device has any addresses
   
  Arguments:
    None
  Returns:
    hashref of Ipblock objects, keyed by id
  Examples:
    my %s = $device->get_subnets();
    print $s{$_}->address, "\n" foreach keys %s;

=cut

sub get_subnets {
    my $self = shift;
    $self->isa_object_method('get_subnets');
    
    my %subnets;
    foreach my $ip ( @{ $self->get_ips() } ){
	my $subnet;
	if ( (int($subnet = $ip->parent) != 0) 
	     && $subnet->status 
	     && $subnet->status->name eq "Subnet" ){
	    $subnets{$subnet->id} = $subnet;
	}
    }
    return \%subnets;
}

############################################################################
=head2 add_interfaces - Manually add a number of interfaces to an existing device

    The new interfaces will be added with numbers starting after the highest existing 
    interface number

  Arguments:
    Number of interfaces
  Returns:
    Arrayref of new interface objects
  Examples:
    $device->add_interfaces(2);

=cut

sub add_interfaces {
    my ($self, $num) = @_;
    $self->isa_object_method('add_interfaces');

    unless ( $num > 0 ){
	$self->throw_user("Invalid number of Interfaces to add: $num\n");
    }
    # Determine highest numbered interface in this device
    my @ints;
    my $start;
    my $ints = $self->ints_by_number;
    if ( defined $ints && scalar @$ints ){
 	my $lastidx = @$ints - 1;
	$start = int ( $ints->[$lastidx]->number );
    }else{
	$start = 0;
    }
    my %tmp = ( device => $self->id, number => $start );
    my $i;
    my @newints;
    for ( $i = 0; $i < $num; $i++ ){
	$tmp{number}++;
	push @newints, Interface->insert( \%tmp );
    }
    return \@newints;
}

############################################################################
=head2 ints_by_number - Retrieve interfaces from a Device and sort by number.  

    The number field can actually contain alpha characters. If so, 
    sort alphanumerically, removing any non-alpha characters.  Otherwise,
    sort numerically.
    
  Arguments:  
    None
  Returns:    
    Sorted arrayref of interface objects
  Examples:
    print $_->number, "\n" foreach @{ $device->ints_by_number() };

=cut

sub ints_by_number {
    my $self = shift;
    $self->isa_object_method('ints_by_number');

    my @ifs = $self->interfaces();

    my ($nondigit, $letters);
    for ( @ifs ) { 
	if ($_->number =~ /\D/){ 
	    $nondigit = 1;  
	    if ($_->number =~ /[A-Za-z]/){ 
		$letters = 1;  
	    }
	}
    }

    if ( $nondigit ){
	    my @tmp;
	    foreach my $if ( @ifs ){
		my $num = $if->number;
		$num =~ s/\W+//g;
		push @tmp, [$num, $if];
	    }
	if ( $letters ){
	    @ifs = map { $_->[1] } sort { $a->[0] cmp $b->[0] } @tmp;	    
	}else{
	    @ifs = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @tmp;
	}
    }else{
	@ifs = sort { $a->number <=> $b->number } @ifs;
    }

    return \@ifs;
}

############################################################################
=head2 ints_by_name - Retrieve interfaces from a Device and sort by name.  

    This method deals with the problem of sorting Interface names that contain numbers.
    Simple alphabetical sorting does not yield useful results.

  Arguments:  
    None
  Returns:    
    Sorted arrayref of interface objects
  Exampless:

=cut

sub ints_by_name {
    my $self = shift;
    $self->isa_object_method('ints_by_name');

    my @ifs = $self->interfaces;
    
    # The following was borrowed from Netviewer
    # and was slightly modified to handle Netdot Interface objects.
    # Yes. It is ugly.
    @ifs = ( map { $_->[0] } sort { 
	       $a->[1] cmp $b->[1]
	    || $a->[2] <=> $b->[2]
	    || $a->[3] <=> $b->[3]
	    || $a->[4] <=> $b->[4]
	    || $a->[5] <=> $b->[5]
	    || $a->[6] <=> $b->[6]
	    || $a->[7] <=> $b->[7]
	    || $a->[8] <=> $b->[8]
	    || $a->[0]->name cmp $b->[0]->name }  
	     map{ [ $_, $_->name =~ /^(\D+)\d/, 
		    ( split( /\D+/, $_->name ))[0,1,2,3,4,5,6,7,8] ] } @ifs);
    
    return \@ifs;
}

############################################################################
=head2 ints_by_speed - Retrieve interfaces from a Device and sort by speed.  

  Arguments:  
    None
  Returns:    
    Sorted array of interface objects

=cut

sub ints_by_speed {
    my $self = shift;
    $self->isa_object_method('ints_by_speed');

    my @ifs = Interface->search( device => $self->id, {order_by => 'speed'});
    
    return \@ifs;
}

############################################################################
=head2 interfaces_by_vlan - Retrieve interfaces from a Device and sort by vlan ID

Arguments:  None
Returns:    Sorted arrayref of interface objects

Note: If the interface has/belongs to more than one vlan, sort function will only
use one of the values.

=cut

sub ints_by_vlan {
    my $self = shift;
    $self->isa_object_method('ints_by_vlan');

    my @ifs = $self->interfaces();
    my @tmp = map { [ ($_->vlans) ? ($_->vlans)[0]->vlan->vid : 0, $_] } @ifs;
    @ifs = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @tmp;

    return \@ifs;
}

############################################################################
=head2 ints_by_jack - Retrieve interfaces from a Device and sort by Jack id

Arguments:  None
Returns:    Sorted arrayref of interface objects

=cut

sub ints_by_jack {
    my ( $self, $o ) = @_;
    $self->isa_object_method('ints_by_jack');

    my @ifs = $o->interfaces();
    my @tmp = map { [ ($_->jack) ? $_->jack->jackid : 0, $_] } @ifs;
    @ifs = map { $_->[1] } sort { $a->[0] cmp $b->[0] } @tmp;

    return \@ifs;
}

############################################################################
=head2 ints_by_descr - Retrieve interfaces from a Device and sort by description

Arguments:  None
Returns:    Sorted arrayref of interface objects

=cut

sub ints_by_descr {
    my ( $self, $o ) = @_;
    $self->isa_object_method('ints_by_descr');

    my @ifs = Interface->search( device => $self->id, {order_by => 'description'});

    return \@ifs;
}

############################################################################
=head2 ints_by_monitored - Retrieve interfaces from a Device and sort by 'monitored' field

Arguments:  None
Returns:    Sorted arrayref of interface objects

=cut

sub ints_by_monitored {
    my ( $self, $o ) = @_;
    $self->isa_object_method('ints_by_monitored');

    my @ifs = Interface->search( device => $self->id, {order_by => 'monitored DESC'});

    return \@ifs;
}

############################################################################
=head2 ints_by_snmp - Retrieve interfaces from a Device and sort by 'snmp_managed' field

Arguments:  None
Returns:    Sorted arrayref of interface objects

=cut

sub ints_by_snmp {
    my ( $self, $o ) = @_;
    $self->isa_object_method('ints_by_snmp');

    my @ifs = Interface->search( device => $self->id, {order_by => 'snmp_managed DESC'});

    return \@ifs;
}

############################################################################
=head2 interfaces_by - Retrieve sorted list of interfaces from a Device

    This will call different methods depending on the sort field specified

  Arguments:
    Hash with the following keys:
      sort_by  [number|name|speed|vlan|jack|descr|monitored|snmp]
  Returns:    
    Sorted arrayref of interface objects
  Examples:
    print $_->name, "\n" foreach $device->interfaces_by('name');
    
=cut

sub interfaces_by {
    my ( $self, $sort ) = @_;
    $self->isa_object_method('interfaces_by');

    $sort ||= "number";

    if ( $sort eq "number" ){
	return $self->ints_by_number;
    }elsif ( $sort eq "name" ){
	return $self->ints_by_name;
    }elsif( $sort eq "speed" ){
	return $self->ints_by_speed;
    }elsif( $sort eq "vlan" ){
	return $self->ints_by_vlan;
    }elsif( $sort eq "jack" ){
	return $self->ints_by_jack;
    }elsif( $sort eq "descr"){
	return $self->ints_by_descr;
    }elsif( $sort eq "monitored"){
	return $self->ints_by_monitored;
    }elsif( $sort eq "snmp"){
	return $self->ints_by_snmp;
    }else{
	$self->throw_fatal("Unknown sort field: $sort");
    }
}

############################################################################
=head2 bgppeers_by_ip - Sort by remote IP

  Arguments:  
    Array ref of BGPPeering objects
  Returns:    
    Sorted arrayref of BGPPeering objects
=cut
sub bgppeers_by_ip {
    my ( $self, $peers ) = @_;
    $self->isa_object_method('bgppeers_by_ip');

    my @peers = map { $_->[1] } 
    sort  { pack("C4"=>$a->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) 
		cmp pack("C4"=>$b->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/); }  
    map { [$_->bgppeeraddr, $_] } @$peers ;
    
    return unless scalar @peers;
    return \@peers;
}

############################################################################
=head2 bgppeers_by_id - Sort by BGP ID

  Arguments:  
    Array ref of BGPPeering objects
  Returns:    
    Sorted arrayref of BGPPeering objects

=cut
sub bgppeers_by_id {
    my ( $self, $peers ) = @_;
    $self->isa_object_method('bgppeers_by_id');

    my @peers = map { $_->[1] } 
    sort  { pack("C4"=>$a->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) 
		cmp pack("C4"=>$b->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/); }  
    map { [$_->bgppeerid, $_] } @$peers ;
    
    return unless scalar @peers;
    return \@peers;
}

############################################################################
=head2 bgppeers_by_entity - Sort by Entity name, AS number or AS Name

  Arguments:  
    Array ref of BGPPeering objects, 
    Entity table field to sort by [name*|asnumber|asname]
  Returns:    
    Sorted array of BGPPeering objects

=cut
sub bgppeers_by_entity {
    my ( $self, $peers, $sort ) = @_;
    $self->isa_object_method('bgppeers_by_id');

    $sort ||= "name";
    unless ( $sort =~ /name|asnumber|asname/ ){
	$self->throw_fatal("Invalid Entity field: $sort");
    }
    my $sortsub = ($sort eq "asnumber") ? 
	sub{$a->entity->$sort <=> $b->entity->$sort} :
	sub{$a->entity->$sort cmp $b->entity->$sort};
    my @peers = sort $sortsub @$peers;
    
    return unless scalar @peers;
    return \@peers;
}


############################################################################
=head2 get_bgp_peers - Retrieve BGP peers that match certain criteria and sort them

    This overrides the method auto-generated by Class::DBI

 Arguments:  
    Hash with the following keys:
    entity    <string>  Return peers whose entity name matches <string>
    id        <integer> Return peers whose ID matches <integer>
    ip        <address> Return peers whose Remote IP matches <address>
    as        <integer> Return peers whose AS matches <integer>
    type      <string>  Return peers of type [internal|external|all*]
    sort      <string>  Sort by [entity*|asnumber|asname|id|ip]

    (*) default

  Returns:    
    Sorted arrayref of BGPPeering objects
  Examples:
    print $_->entity->name, "\n" foreach @{ $device->get_bgp_peers() };

=cut
sub get_bgp_peers {
    my ( $self, %argv ) = @_;
    $self->isa_object_method('get_bgp_peers');

    $argv{type} ||= "all";
    $argv{sort} ||= "entity";
    my @peers;
    if ( $argv{entity} ){
	@peers = grep { $_->entity->name eq $argv{entity} } $self->bgppeers;
    }elsif ( $argv{id} ){
	@peers = grep { $_->bgppeerid eq $argv{id} } $self->bgppeers;	
    }elsif ( $argv{ip} ){
	@peers = grep { $_->bgppeeraddr eq $argv{id} } $self->bgppeers;	
    }elsif ( $argv{as} ){
	@peers = grep { $_->asnumber eq $argv{as} } $self->bgppeers;	
    }elsif ( $argv{type} ){
	if ( $argv{type} eq "internal" ){
	    @peers = grep { $_->entity->asnumber == $self->bgplocalas } $self->bgppeers;
	}elsif ( $argv{type} eq "external" ){
	    @peers = grep { $_->entity->asnumber != $self->bgplocalas } $self->bgppeers;
	}elsif ( $argv{type} eq "all" ){
	    @peers = $self->bgppeers();
	}else{
	    $self->throw_fatal("Invalid type: $argv{type}");
	}
    }elsif ( ! $argv{sort} ){
	$self->throw_fatal("Missing or invalid search criteria");
    }
    if ( $argv{sort} =~ /entity|asnumber|asname/ ){
	$argv{sort} =~ s/entity/name/;
	return $self->bgppeers_by_entity(\@peers, $argv{sort});
    }elsif( $argv{sort} eq "ip" ){
	return $self->bgppeers_by_ip(\@peers);
    }elsif( $argv{sort} eq "id" ){
	return $self->bgppeers_by_id(\@peers);
    }else{
	$self->throw_fatal("Invalid sort argument: $argv{sort}");
    }
    
    return \@peers if scalar @peers;
    return;
}

###################################################################################################
=head2 set_overwrite_if_descr - Set the overwrite_description flag in all interfaces of this device

    This flag controls whether the ifAlias value returned from the Device should
    overwrite the value of the Interface description field in the database.  
    Some devices return a null string, which would erase any user-entered descriptions in Netdot.
    This method sets that value of this flag for each interface in the device.

  Arguments:  
    0 or 1 (true or false)
  Returns:    
    True if successful
  Example:
    $device->set_overwrite_if_descr(1);

=cut
sub set_overwrite_if_descr {
    my ($self, $value) = @_;
    $self->isa_object_method("set_overwrite_if_descr");
    
    $self->throw_fatal("Invalid value: $value.  Should be 0|1")
	unless ( $value =~ /0|1/ );

    foreach my $int ( $self->interfaces ){
	$int->update({overwrite_descr=>$value});
    }
    
    return 1;
}


#####################################################################
#
# Private methods
#
#####################################################################

############################################################################
# Validate arguments to insert and update
# 
#   Arguments:
#     hash reference with field/value pairs for Device
#   Returns:
#     True or throws exceptions
#
sub _validate_args {
    my ($proto, $args) = @_;
    my ($self, $class);
    if ( $class = ref $proto ){
	$self = $proto;
    }else{
	$class = $proto;
    }
    
    # We need a name always
    $args->{name} ||= $self->name if ( defined $self );
    unless ( $args->{name} ){
	$class->throw_user("Name cannot be null\n");
    }
    
    # SNMP Version
    if ( defined $args->{snmp_version} ){
	if ( $args->{snmp_version} !~ /^1|2|3$/ ){
	    $class->throw_user("Invalid SNMP version.  It must be either 1, 2 or 3\n");
	}
    }

    # Serial number
    if ( my $sn = $args->{serialnumber} ){
	if ( my $otherdev = $class->search(serialnumber=>$sn)->first ){
	    if ( defined $self ){
		if ( $self->id != $otherdev->id ){
		    $self->throw_user( sprintf("%s: S/N %s belongs to existing device: %s.\n", 
					       $self->fqdn, $sn, $otherdev->fqdn) ); 
		}
	    }else{
		$class->throw_user( sprintf("S/N %s belongs to existing device: %s.\n", 
					    $sn, $otherdev->fqdn) ); 
	    }
	}
    }
    
    # Base bridge MAC
    if ( defined $args->{physaddr} ){
	# Notice we use int() to stringify the object if it is one
	if ( my $mac = PhysAddr->retrieve(int($args->{physaddr})) ){
	    my $address = $mac->address;
	    if ( my $otherdev = ($mac->devices)[0] ){
		if ( defined $self ){
		    if ( $self->id != $otherdev->id ){
			# Another device has this address!
			$class->throw_user( sprintf("%s: Base MAC %s belongs to existing device: %s\n", 
						   $self->fqdn, $address, $otherdev->fqdn ) ); 
		    }
		}else{
		    $class->throw_user( sprintf("Base MAC %s belongs to existing device: %s\n", 
					       $address, $otherdev->fqdn ) ); 
		}
	    }
	}
    }

    return 1;
}

########################################################################################
# _layer_active - Determine if a particular layer is active in the layers bit string
#    
#
#   Arguments:
#     layers bit string
#     layer number
#   Returns:
#     True/False
#
#   Examples:
#     $class->_layer_active(2);
#
sub _layer_active {
    my ($class, $layers, $layer) = @_;
    $class->isa_class_method('_layer_active');
    
    $class->throw_fatal("Missing required arguments")
	unless ( $layers && $layer );
    
    return substr($layers,8-$layer, 1);
}

# ############################################################################
# _get_snmp_session - Establish a SNMP session.  Tries to reuse sessions.
#    
#   Arguments:
#     Arrayref with the following keys (mostly optional):
#      host         IP or hostname (required unless called as instance method)
#      communities  Arrayref of SNMP Community strings
#      version      SNMP version
#      bulkwalk     Whether to use SNMP BULK
#      timeout      SNMP Timeout
#      retries      Number of retries after Timeout
#      sclass       SNMP::Info class
#
#   Returns:
#     SNMP::Info object if successful
#
#   Examples:
#    
#     Instance call:
#     my $session = $device->get_snmp_session();
#
#     Class call:
#     my $session = Device->get_snmp_session(host=>$hostname, communities=>['public']);
#

sub _get_snmp_session {
    my ($self, %argv) = @_;
    
    my $class;
    my $sclass = $argv{sclass} if defined ( $argv{sclass} );

    if ( $class = ref($self) ){
	# Being called as an instance method

	# Do not continue unless snmp_managed flag is on
	$self->throw_user(sprintf("Device %s not SNMP-managed. Aborting.\n", $self->fqdn))
	    unless $self->snmp_managed;

	# Fill up communities argument from object if it wasn't passed to us
	push @{$argv{communities}}, $self->community unless defined $argv{communities};

	# We might already have a session
	if ( defined $self->{_snmp_session} ){
	    foreach my $comm ( @{$argv{communities}} ){
		if ( defined $self->{_snmp_session}->{$comm} ){
		    $logger->debug(sprintf("Device::get_snmp_session: Reusing existing session with %s, community %s", 
					   $self->fqdn, $comm));
		    return $self->{_snmp_session}->{$comm};
		}
	    }
	}
	
	# We might already have a SNMP::Info class
	$sclass ||= $self->{_sclass};
	
	# Fill out some arguments if not given explicitly
	unless ( $argv{host} ){
	    if ( defined $self->snmp_target && ref($self->snmp_target) =~ /Ipblock/ ){
		$argv{host} = $self->snmp_target->address;
	    }else{
		$argv{host} = $self->fqdn;
	    }
	}
	$self->throw_user("Could not determine IP nor hostname for Device id: %d", $self->id)
	    unless $argv{host};

	$argv{version}  ||= $self->snmp_version;
	$argv{bulkwalk} ||= $self->snmp_bulk;
	
    }
    
    # If we still don't have any communities, get defaults from config file
    $argv{communities} = $self->config->get('DEFAULT_SNMPCOMMUNITIES')
	unless defined $argv{communities};
    
    $sclass ||= 'SNMP::Info';
    
    my @mibdirs;
    foreach my $md ( @{ $self->config->get('SNMP_MIB_DIRS') } ){
	push @mibdirs, $self->config->get('NETDOT_PATH')."/".$md;
    }
    # Set defaults
    my %sinfoargs = ( DestHost      => $argv{host},
		      Version       => $argv{version} || $self->config->get('DEFAULT_SNMPVERSION'),
		      Timeout       => (defined $argv{timeout}) ? $argv{timeout} : $self->config->get('DEFAULT_SNMPTIMEOUT'),
		      Retries       => (defined $argv{retries}) ? $argv{retries} : $self->config->get('DEFAULT_SNMPRETRIES'),
		      AutoSpecify   => 1,
		      Debug         => 0,
		      BulkWalk      => (defined $argv{bulkwalk}) ? $argv{bulkwalk} :  $self->config->get('DEFAULT_SNMPBULK'),
		      BulkRepeaters => 20,
		      MibDirs       => \@mibdirs,
		      );
    
    my ($sinfo, $layers);

    # Try each community
    foreach my $community ( @{$argv{communities}} ){
	$sinfoargs{Community} = $community;
	
	$logger->debug(sprintf("Device::get_snmp_session: Trying session with %s, community %s",
			       $sinfoargs{DestHost}, $sinfoargs{Community}));
	
	$sinfo = $sclass->new( %sinfoargs );
	
	# Test for connectivity
	$layers = $sinfo->layers() if defined $sinfo;
	
	# Try Version 1 if we haven't already
	if ( !defined $sinfo && !defined $layers && $sinfoargs{Version} != 1 ){
	    $logger->debug(sprintf("Device::get_snmp_session: %s: SNMPv%d failed. Trying SNMPv1", 
				   $sinfoargs{DestHost}, $sinfoargs{Version}));
	    $sinfoargs{Version} = 1;
	    $sinfo = $sclass->new( %sinfoargs );
	}
	
	if ( defined $sinfo ){
	    # Check for errors
	    if ( my $err = $sinfo->error ){
		$self->throw_user(sprintf("Device::get_snmp_session: SNMPv%d error: device %s, community '%s': %s\n", 
					  $sinfoargs{Version}, $sinfoargs{DestHost}, $sinfoargs{Community}, $err));
	    }
	    last; # If we made it here, we are fine.  Stop trying communities
	}else{
	    $logger->debug(sprintf("Device::get_snmp_session: Failed %s session with %s community '%s'", 
				   $sinfoargs{Version}, $sinfoargs{DestHost}, $sinfoargs{Community}));
	}
    }
    
    unless ( defined $sinfo ){
	$self->throw_user(sprintf("Device::get_snmp_session: Cannot connect to %s community '%s'\n", 
				  $sinfoargs{DestHost}, $sinfoargs{Community}));
    }

    # Save SNMP::Info class if we are an object
    $logger->debug("Device::get_snmp_session: $argv{host} is: ", $sinfo->class());
    if ( $class ){
	$self->{_sclass} = $sinfo->class();
    }

    # We might have tried a different SNMP version and community above. Rectify DB if necessary
    if ( $class ){
	my %uargs;
	$uargs{snmp_version} = $sinfoargs{Version}   if ( $self->snmp_version ne $sinfoargs{Version} );
	$uargs{community}    = $sinfoargs{Community} if ( $self->community    ne $sinfoargs{Community} );
	$self->update(\%uargs) if ( keys %uargs );
    }
    $logger->debug(sprintf("SNMPv%d session with host %s, community '%s' established",
			  $sinfoargs{Version}, $sinfoargs{DestHost}, $sinfoargs{Community}) );

    # We want to do our own 'munging' for certain things
    my $munge = $sinfo->munge();
    delete $munge->{'i_speed'};      # We store these as integers in the db.  Munge at display
    $munge->{'i_speed_high'}                   = sub{ return $self->_munge_speed_high(@_) };
    $munge->{'i_mac'}                          = sub{ return $self->_oct2hex(@_) };
    $munge->{'fw_mac'}                         = sub{ return $self->_oct2hex(@_) };
    $munge->{'mac'}                            = sub{ return $self->_oct2hex(@_) };
    $munge->{'at_paddr'}                       = sub{ return $self->_oct2hex(@_) };
    $munge->{'rptrAddrTrackNewLastSrcAddress'} = sub{ return $self->_oct2hex(@_) };
    $munge->{'airespace_ap_mac'}               = sub{ return $self->_oct2hex(@_) };
    $munge->{'airespace_bl_mac'}               = sub{ return $self->_oct2hex(@_) };
    $munge->{'airespace_if_mac'}               = sub{ return $self->_oct2hex(@_) };


    if ( $class ){
	# Save session if object exists
	# Notice that there can be different sessions depending on the community
	$self->{_snmp_session}->{$sinfoargs{Community}} = $sinfo;
    }
    return $sinfo;
}

#########################################################################
# Retrieve a list of device objects from given file (one per line)
#
# Arguments:  File path
# Returns  :  Arrayref of device objects
#
sub _get_devs_from_file {
    my ($class, $file) = @_;
    $class->isa_class_method('get_devs_from_file');

    my $hosts = $class->_get_hosts_from_file($file);
    my @devs;
    foreach my $host ( keys %$hosts ){
	if ( my $dev = $class->search(name=>$host)->first ){
	    push @devs, $dev; 
	}else{
	    $logger->info("Device $host does not yet exist in the Database.");
	}
    }
    $class->throw_user("Device::_get_devs_from_file: No existing devices in list.  You might need to run a discover first.\n")
	unless ( scalar @devs );

    return \@devs;
}
#########################################################################
# Retrieve a list of hostnames/communities from given file (one per line)
# 
# Arguments:  File path
# Returns  :  Hashref with hostnames (or IP addresses) as key 
#             and SNMP community as value
# 
sub _get_hosts_from_file {
    my ($class, $file) = @_;
    $class->isa_class_method('get_hosts_from_file');

    $class->throw_user("Device::_get_hosts_from_file: Missing or invalid file: $file\n")
	unless ( defined($file) && -r $file );
  
    open(FILE, "<$file") or 
	$class->throw_user("Can't open file $file for reading: $!\n");
    
    $logger->debug("Device::_get_hosts_from_file: Retrieving host list from $file");

    my %hosts;
    while (<FILE>){
	chomp($_);
	next if ( /^#/ );
	if ( /\w+\s+\w+/ ){
	    my ($host, $comm) = split /\s+/, $_;
	    $hosts{$host} = $comm;
	}
    }
    
    $class->throw_user("Host list is empty!\n")
	unless ( scalar keys %hosts );
    
    close(FILE);
    return \%hosts;
}

#########################################################################
# Initialize ForkManager
# Arguments:    None
# Returns  :    Parallel::ForkManager object
#
sub _fork_init {
    my ($class) = @_;
    $class->isa_class_method('_fork_init');

    # Tell DBI that we don't want to disconnect the server's DB handle
    my $dbh = $class->db_Main;
    unless ( $dbh->{InactiveDestroy} = 1 ) {
	$class->throw_fatal("Device::_fork_init: Cannot set InactiveDestroy: ", $dbh->errstr);
    }

    # MAXPROCS processes for parallel updates
    $logger->debug("Device::_fork_init: Launching up to $MAXPROCS children processes");
    my $pm = Parallel::ForkManager->new($MAXPROCS);

    return $pm;
}

#########################################################################
# _fork_end - Wrap up ForkManager
#    Wait for all children
#    Set InactiveDestroy back to default
#
# Arguments:    Parallel::ForkManager object
# Returns  :    True if successful
#
sub _fork_end {
    my ($class, $pm) = @_;
    $class->isa_class_method('_fork_end');

    # Wait for all children to finish
    $logger->debug("Device::_fork_end: Waiting for children...");
    $pm->wait_all_children;
    $logger->debug("Device::_fork_end: All children finished");

    # Return DBI to its normal DESTROY behavior
    my $dbh = $class->db_Main;
    $dbh->{InactiveDestroy} = 0;
    return 1;
}

####################################################################################
# _snmp_update_list - Discover and/or update all devices in a given list
#    
#   Arguments:
#     Hash with the following keys:
#     hosts         Hashref of host names and their communities
#     devs          Arrayref of Device objects
#     communities   Arrayref of SNMP communities
#     version       SNMP version
#     timeout       SNMP timeout
#     retries       SNMP retries
#     add_subnets   Flag. When discovering routers, add subnets to database if they do not exist
#     subs_inherit  Flag. When adding subnets, have them inherit information from the Device
#     bgp_peers     Flag. When discovering routers, update bgp_peers
#     pretend       Flag. Do not commit changes to the database
#   
#   Returns: 
#     Device count
#
sub _snmp_update_list {
    my ($class, %argv) = @_;
    $class->isa_class_method('snmp_update_list');

    my ($hosts, $devs);
    if ( defined $argv{hosts} ){
	$class->throw_fatal("Invalid hosts hash") if ( ref($argv{hosts}) ne "HASH" );
	$hosts = $argv{hosts};
    }elsif ( defined $argv{devs} ){
	$class->throw_fatal("Invalid devs array") if ( ref($argv{devs}) ne "ARRAY" );
	$devs = $argv{devs};
    }else{
	$class->throw_fatal("Missing required parameters: hosts or devs");
    }
    
    # Init ForkManager
    my $pm = $class->_fork_init();

    my $device_count = 0;
    my %do_devs;            # Key on device ID to avoid querying the same device twice
    if ( $devs ){
	foreach my $dev ( @$devs ){
	    # Put in list
	    $do_devs{$dev->id} = $dev;
	}
    }elsif ( $hosts ){
	foreach my $host ( keys %$hosts ){
	    my $dev;
	    if ( $dev = $class->search(name=>$host)->first ){
		# Device is already in DB
		$logger->debug(sprintf("Device::snmp_update_list: %s exists in DB as %s", 
				       $host, $dev->fqdn));
		# Put in list
		$do_devs{$dev->id} = $dev;
	    }else{
		# Device does not yet exist
		# Get relevant snmp args
		my %snmpargs;
		foreach my $field ( qw(communities version timeout retries) ){
		    $snmpargs{$field} = $argv{$field} if defined ($argv{$field});
		}
		# Give preference to the community being passed (if any)
		if ( my $commstr = $hosts->{$host} ){
		    $snmpargs{communities} = [$commstr];
		}
		# FORK
		$device_count++;
		$pm->start and next;
		$class->_launch_child(pm   => $pm, 
				      code => sub { return $class->discover(name=>$host, %snmpargs) },
				      );
	    }
	}
    }
    # Now go over list of existing devices
    # Get relevant snmp_update args
    my %uargs;
    foreach my $field ( qw( add_subnets subs_inherit bgp_peers pretend ) ){

	$uargs{$field} = $argv{$field} if defined ($argv{$field});
    }
    foreach my $dev ( values %do_devs ){
	unless ( $dev->canautoupdate ){
	    $logger->debug("%s excluded from auto-updates. Skipping", 
			   $dev->fqdn);
	    next;
	}
	# FORK
	$device_count++; # this isn't real, but...
	$pm->start and next;
	$class->_launch_child(pm   => $pm, 
			      code => sub { return $dev->snmp_update(%uargs); },
			      );
    }
    
    # End forking state
    $class->_fork_end($pm);

    return $device_count;
}




############################################################################
#_get_arp_from_snmp - Fetch ARP tables via SNMP
#
#     Performs some validation and abstracts snmp::info logic
#     Some logic borrowed from netdisco's arpnip()
#    
#   Arguments:
#     Hash with following keys:
#       intmacs - Hash ref with Interface MACs
#   Returns:
#     Hash ref.
#    
#   Examples:
#     $self->get_snmp_arp;
#
#
sub _get_arp_from_snmp {
    my ($self, %argv) = @_;


    $self->isa_object_method('_get_arp_from_snmp');
    my $host = $self->fqdn;

    my $intmacs = $argv{intmacs} || PhysAddr->from_interfaces();

    my %cache;
    my $sinfo = $self->_get_snmp_session();

    # Fetch ARP Cache
    $logger->debug("$host: Fetching ARP cache");
    my $start      = time;
    my $at_paddr   = $sinfo->at_paddr();

    my $arp_count = 0;
    foreach my $key ( keys %$at_paddr ){
	my ($ip, $idx, $mac);
	if ( $key =~ /(\d+)\.($IPV4)/ ){
	    $idx = $1;
	    $ip  = $2;
	    $mac = $at_paddr->{$key};
	}else{
	    $logger->debug("Device::_get_arp_from_snmp: $host: Unrecognized hash key: $key");
	    next;
	}
        unless ( defined($ip) ){
	    $logger->debug("Device::_get_arp_from_snmp: $host: IP not defined in hash key: $key");
	    next;
	}
	unless ( defined($idx) ){
	    $logger->debug("Device::_get_arp_from_snmp: $host: ifIndex not defined in hash key: $key");
	    next;
	}
	unless ( defined($mac) ){
	    $logger->debug("Device::_get_arp_from_snmp: $host: MAC not defined in at_paddr->{$key}");
	    next;
	}
	if ( ! PhysAddr->validate($mac) ){
	    $logger->debug("Device::get_snmp_arp: $host: Invalid MAC: $mac");
	    next;
	}	
	
	# Skip MACs that belong to interfaces
	if ( $intmacs->{$mac} ){
 	    $logger->debug("Device::get_snmp_arp: $host: $mac is a port.  Skipping.");
	    next;
	}

	# Store in hash
	$cache{$idx}{$mac} = $ip;

	$logger->debug("Device::get_snmp_arp: $host: $idx -> $ip -> $mac");
    }
    
    map { $arp_count+= scalar(keys %{$cache{$_}}) } keys %cache;

    my $end = time;
    $logger->info(sprintf("$host: ARP cache fetched. %s entries in %d seconds", 
		  $arp_count, ($end-$start) ));

    return \%cache;
}


############################################################################
#_get_fwt_from_snmp - Fetch fowarding tables via SNMP
#
#     Performs some validation and abstracts snmp::info logic
#     Some logic borrowed from netdisco's macksuck()
#    
#   Arguments:
#     intmacs - Hashref with Interface MACs
#   Returns:
#     Hash ref.
#    
#   Examples:
#     $self->get_fwt_from_snmp;
#
#
sub _get_fwt_from_snmp {
    my ($self, %argv) = @_;

    $self->isa_object_method('get_fwt_from_snmp');
    my $class = ref($self);

    my $host = $self->fqdn;

    my $start   = time;
    my $sinfo   = $self->_get_snmp_session();
    my $sints   = $sinfo->interfaces();
    my $intmacs = $argv{intmacs} || PhysAddr->from_interfaces();

    # Build a hash with device's interfaces, indexed by ifIndex
    my %devints;
    foreach my $int ( $self->interfaces ){
	$devints{$int->number} = $int;
    }

    # Fetch FWT. 
    # Notice that we pass the result variable as a parameter since that's the
    # easiest way to append more info later using the same function (see below).
    my %fwt; 
    $logger->debug("$host: Fetching forwarding table");
    $self->_walk_fwt(sinfo   => $sinfo,
		     sints   => $sints,
		     intmacs => $intmacs,
		     devints => \%devints,
		     fwt     => \%fwt,
		     ); 
    
    # For certain Cisco switches you have to connect to each
    # VLAN and get the forwarding table out of it.
    # Notably the Catalyst 5k, 6k, and 3500 series
    my $cisco_comm_indexing = $sinfo->cisco_comm_indexing();
    if ( $cisco_comm_indexing ){
        $logger->debug("$host supports Cisco community string indexing. Connecting to each VLAN");
        my $v_name   = $sinfo->v_name() || {};
        my $i_vlan   = $sinfo->i_vlan() || {};
	my $sclass   = $sinfo->class();
	
        # Get list of VLANs currently in use by ports
        my %vlans;
        foreach my $key ( keys %$i_vlan ){
            my $vlan = $i_vlan->{$key};
            $vlans{$vlan}++;
        }
	
        # For each VLAN, connect and then retrieve forwarding tables
	# VLAN id comes as 1.142 instead of 142
        foreach my $vid (sort { my $aa=$a; my $bb=$b; $aa =~ s/^\d+\.//;$bb=~ s/^\d+\.//;
                                # Sort by VLAN id
                                $aa <=> $bb
				}
                         keys %$v_name){
	    
            my $vlan_name = $v_name->{$vid} || '(Unnamed)';
            my $vlan = $vid;
            $vlan =~ s/^\d+\.//;
	    
            # Only get macs from VLAN if in use by port
            # but check to see if device serves us that list first
            if ( scalar keys(%$i_vlan) && !defined $vlans{$vlan} ){
                $logger->debug("VLAN:$vlan_name ($vlan) skipped because not in use by a port");
		next;
	    }
	    
            my %args = ('host'        => $host,
                        'communities' => [$self->community . '@' . $vlan],
                        'version'     => $self->snmp_version,
			'sclass'      => $sclass,
			);
            my $vlan_sinfo = $class->_get_snmp_session(%args);
	    
            unless ( defined $vlan_sinfo ){
                $logger->error("$host: Error getting SNMP session for VLAN: $vlan");
                next;
            }
            $self->_walk_fwt(sinfo      => $vlan_sinfo,
			     sints      => $sints,
			     intmacs    => $intmacs,
			     devints    => \%devints,
			     fwt        => \%fwt);
        }
    }
	    
    my $end = time;
    my $fwt_count = 0;
    map { $fwt_count+= scalar keys %{ $fwt{$_} } } keys %fwt;
    $logger->info(sprintf("$host: FWT fetched. %d entries in %d seconds", 
			  $fwt_count, ($end-$start) ));
    
    return \%fwt;
}

#########################################################################
sub _walk_fwt {
    my ($self, %argv) = @_;
    $self->isa_object_method('_walk_fwt');

    my ($sinfo, $sints, $intmacs, $devints, $fwt) = @argv{"sinfo", "sints", "intmacs", "devints",  "fwt"};
    
    my $host = $self->fqdn;
    
    $self->throw_fatal("Missing required arguments") 
	unless ( $sinfo && $sints && $intmacs && $devints && $fwt );

    # Try BRIDGE mib stuff first, then REPEATER mib
    if ( my $fw_mac = $sinfo->fw_mac() ){
	
	my $fw_port    = $sinfo->fw_port();
	my $bp_index   = $sinfo->bp_index();
	
	# To map the port in the forwarding table to the
	# physical device port we have this triple indirection:
	#      fw_port -> bp_index -> interfaces
	
	foreach my $fw_index ( keys %$fw_mac ){

	    my $mac = $fw_mac->{$fw_index};
	    unless ( defined $mac ) {
		$logger->debug("Device::_walk_fwt: $host: MAC not defined at index $fw_index.  Skipping");
		next;
	    }

	    my $bp_id  = $fw_port->{$fw_index};
	    unless ( defined $bp_id ) {
		$logger->debug("Device::_walk_fwt: $host: Port $fw_index has no fw_port mapping.  Skipping");
		next;
	    }
	    
	    my $iid = $bp_index->{$bp_id};
	    unless ( defined $iid ) {
		$logger->debug("Device::_walk_fwt: $host: Interface $bp_id has no bp_index mapping. Skipping");
		next;
	    }
	    
	    $fwt->{$iid}->{$mac}++;
	}
    
    }elsif ( my $last_src = $sinfo->rptrAddrTrackNewLastSrcAddress() ){
	
	foreach my $iid ( keys %{ $last_src } ){
	    my $mac = $last_src->{$iid};
	    unless ( defined $mac ) {
		$logger->debug("Device::_walk_fwt: $host: MAC not defined at rptr index $iid. Skipping");
		next;
	    }
	    
	    $fwt->{$iid}->{$mac}++;
	}
	    
    }
    
    # Clean up here to avoid repeating these checks in each loop above
    foreach my $iid ( keys %$fwt ){
	my $descr = $sints->{$iid};
	unless ( defined $descr ) {
	    $logger->debug("Device::_walk_fwt: $host: SNMP iid $iid has no physical port matching. Skipping");
	    delete $fwt->{$iid};
	    next;
	}
	
	unless ( $devints->{$iid} ){
	    $logger->warn("Device::_walk_fwt: $host: Interface $iid ($descr) is not in database. Skipping");
	    delete $fwt->{$iid};
	    next;
	}
	
	foreach my $mac ( keys %{ $fwt->{$iid} } ){

	    if ( ! PhysAddr->validate($mac) ){
		$logger->debug("Device::_walk_fwt: $host: Invalid MAC: $mac");
		delete $fwt->{$iid}->{$mac};
		next;
	    }	

	    if ( $intmacs->{$mac} ){
		$logger->debug("Device::_walk_fwt: $host: $mac is an interface.  Skipping.");
		delete $fwt->{$iid}->{$mac};
		next;
		
	    }

	    $logger->debug("Device::_walk_fwt: $host: $iid ($descr) -> $mac ");
	}
	
    }

    return 1;
}

#########################################################################
# Run given code within TIMEOUT time
# Uses ALRM signal to tell process to throw an exception
#
# Rationale: 
# An SNMP connection is established but the agent never replies to a query.  
# In those cases, the standard Timeout parameter for the SNMP session 
# does not help.
#
# Arguments: 
#   hostname
#   code reference
# Returns:
#   Array with results
#
sub _exec_timeout {
    my ($class, $host, $code) = @_;
    $class->throw_fatal("Missing required argument: code") unless $code;
    my @result;
    eval {
	alarm($TIMEOUT);
	@result = $code->();
	alarm(0);
    };
    if ( my $e = $@ ){
	if ( $e =~ /timeout/ ){
	    $logger->error("Device $host timed out ($TIMEOUT sec)\n");
	}
	return;
    }
    wantarray ? @result : $result[0];
}

#########################################################################
#  Executes given code as a child process.  Makes sure DBI handle does
#  not disconnect
#
# Arguments:
#   hash with following keys:
#     code   - Code reference to execute
#     pm     - Parallel::ForkManager object
#   
#
sub _launch_child {
    my ($class, %argv) = @_;
    $class->isa_class_method("_launch_child");

    my ($code, $pm) = @argv{"code", "pm"};

    $class->throw_fatal("Missing required arguments")
	unless ( defined $pm && defined $code );

    # Tell DBI that we don't want to disconnect the server's DB handle
    my $dbh = $class->db_Main;
    unless ( $dbh->{InactiveDestroy} = 1 ) {
	$class->throw_fatal("Cannot set InactiveDestroy: ", $dbh->errstr);
    }
    # Run given code
    $code->();
    $dbh->disconnect();
    $pm->finish; # exit the child process
}

#####################################################################
sub _update_macs_from_cache {
    my ($class, $caches) = @_;
    
    my %mac_updates;
    my $timestamp = $class->timestamp;
    foreach my $cache ( @$caches ){
	foreach my $idx ( keys %{$cache} ){
	    foreach my $mac ( keys %{$cache->{$idx}} ){
		$mac_updates{$mac} = $timestamp;
	    }
	}
    }
    PhysAddr->fast_update(\%mac_updates);
    return 1;
}

#####################################################################
sub _update_ips_from_cache {
    my ($class, $caches) = @_;

    my %ip_updates;
    my $timestamp = $class->timestamp;

    my $ip_status = (IpblockStatus->search(name=>'Discovered'))[0];
    $class->throw_fatal("IpblockStatus 'Discovered' not found?")
	unless $ip_status;
    
    foreach my $cache ( @$caches ){
	foreach my $idx ( keys %{$cache} ){
	    foreach my $mac ( keys %{$cache->{$idx}} ){
		my $ip = $cache->{$idx}->{$mac};
		$ip_updates{$ip} = {
		    prefix     => 32,
		    version    => 4,
		    timestamp  => $timestamp,
		    physaddr   => $mac,
		    status     => $ip_status,
		};
	    }
	}
    }
    
    Ipblock->fast_update(\%ip_updates);
    Ipblock->build_tree(4);
    return 1;
}


#####################################################################
# Add more specific info to the SNMP hashes
#
sub _get_airespace_snmp {
    my ($self, $sinfo, $hashes) = @_;
    
    my @METHODS = ('airespace_apif_slot', 'airespace_ap_model', 'airespace_ap_mac', 'bsnAPEthernetMacAddress',
		   'airespace_ap_ip', 'bsnAPNetmask', 'airespace_apif_type', 'bsnAPIOSVersion',
		   'airespace_apif', 'airespace_apif_admin', 'airespace_ap_serial');
    
    foreach my $method ( @METHODS ){
	$hashes->{$method} = $sinfo->$method;
    }
    
    return 1;
}

#####################################################################
# Given Airespace interfaces info, create a hash with the necessary
# info to create a Device for each AP
#
sub _get_airespace_ap_info {
    my ($self, %argv) = @_;

    my ($hashes, $iid, $info) = @argv{"hashes", "iid", "info"};
    
    my $idx = $iid;
    $idx =~ s/\.\d+$//;
    
    if ( defined(my $model = $hashes->{'airespace_ap_model'}->{$idx}) ){
	$info->{model} = $model;
    }
    if ( defined(my $os = $hashes->{'bsnAPIOSVersion'}->{$idx}) ){
	$info->{os} = $os;
    }
    if ( defined(my $serial = $hashes->{'airespace_ap_serial'}->{$idx}) ){
	$info->{serialnumber} = $serial;
    }

    # This is the bsnAPTable oid.  Kind of a hack
    $info->{sysobjectid} = '1.3.6.1.4.1.14179.2.2';
    $info->{type} = "Access Point";

    # AP Ethernet MAC
    if ( defined(my $basemac = $hashes->{'airespace_ap_mac'}->{$idx}) ){
	if ( ! PhysAddr->validate($basemac) ){
	    $logger->debug("Device::get_airspace_if_info: iid $iid: Invalid MAC: $basemac");
	}else{
	    $info->{physaddr} = $basemac;
	}
    } 

    # Interfaces in this AP
    if ( defined( my $slot = $hashes->{'airespace_apif_slot'}->{$iid} ) ){

	my $radio = $hashes->{'airespace_apif_type'}->{$iid};
	if ( $radio eq "dot11b" ){
	    $radio = "802.11b/g";
	}elsif ( $radio eq "dot11a" ){
	    $radio = "802.11a";
	}elsif ( $radio eq "uwb" ){
	    $radio = "uwb";
	}
	my $name      = $radio;
	my $apifindex = $slot + 1;
	$info->{interface}{$apifindex}{name}   = $name;
	$info->{interface}{$apifindex}{number} = $apifindex;
	if ( defined(my $oper = $hashes->{'airespace_apif'}->{$iid}) ){
	    $info->{interface}{$apifindex}{oper_status} = $oper;
	}
	if ( defined(my $admin = $hashes->{'airespace_apif_admin'}->{$iid}) ){
	    $info->{interface}{$apifindex}{admin_status} = $admin;
	}
    }

    # Add an Ethernet interface
    my $ethidx = 3;
    $info->{interface}{$ethidx}{name}   = 'FastEthernet0';
    $info->{interface}{$ethidx}{number} = $ethidx;
    
    if ( my $mac = $hashes->{'bsnAPEthernetMacAddress'}->{$idx}){
	$mac = $self->_oct2hex($mac);
	$info->{interface}{$ethidx}{physaddr} = $mac;
    }
    # Assign the IP and Netmask to the Ethernet interface
    if ( my $ip = $hashes->{'airespace_ap_ip'}->{$idx}  ){
	$info->{interface}{$ethidx}{ips}{$ip}{address} = $ip;
	if ( my $mask = $hashes->{'bsnAPNetmask'}->{$idx}  ){
	    $info->{interface}{$ethidx}{ips}{$ip}{mask} = $mask;
	}
    }
    
    return 1;
}

#########################################################################
# _fwt_update_list - Update FWT for a given list of devices
#    
#   Arguments:
#     list - array ref of Device objects
#   Returns:
#     True if successful
#   Examples:
#     Device->fwt_update_list(list=>\@devs);
#
#
sub _fwt_update_list {
    my ($class, %argv) = @_;
    $class->isa_class_method('fwt_update_list');
    my $list = $argv{list} or throw_fatal("Missing required arguments: list");
    my $start = time;

    # Get a hash with all interface MACs
    my $intmacs = PhysAddr->from_interfaces();

    # Init ForkManager
    my $pm = $class->_fork_init();

    my $device_count = 0;
    foreach my $dev ( @$list ){
	next unless ( $dev->has_layer(2) && $dev->collect_fwt );
	# FORK
	$device_count++;
	$pm->start and next;
	$class->_launch_child(pm   => $pm,
			      code => sub { return $dev->fwt_update(intmacs=>$intmacs) },
			      );
    }

    # End forking state
    $class->_fork_end($pm);

    my $end = time;
    $logger->info(sprintf("Forwarding tables updated. %d devices in %d seconds", 
			  $device_count, ($end-$start) ));

    return 1;
}

#########################################################################
# _arp_update_list - Update ARP cache from devices in given list
#    
#   Arguments:
#     list - array ref of Device objects
#   Returns:
#     True if successful
#   Examples:
#     Device->arp_update_list(list=>\@devs);
#
sub _arp_update_list {
    my ($class, %argv) = @_;
    $class->isa_class_method('_arp_update_list');

    my $list = $argv{list} or $class->throw_fatal("Missing required arguments: list");
    my $start = time;

    # Get a hash with all interface MACs
    my $intmacs = PhysAddr->from_interfaces();

    # Init ForkManager
    my $pm = $class->_fork_init();

    my $device_count = 0;
    foreach my $dev ( @$list ){
	next unless ( $dev->has_layer(3) && $dev->collect_arp );
	# Fork
	$device_count++;
	$pm->start and next;
	$class->_launch_child(pm   => $pm,
			      code => sub{ return $dev->arp_update(int_macs=>$intmacs) },
			      );
    }

    # End forking state
    $class->_fork_end($pm);

    my $end = time;
    $logger->info(sprintf("ARP caches updated. %d devices in %d seconds", 
			  $device_count, ($end-$start) ));

    return 1;
}

#####################################################################
# Convert octet stream values returned from SNMP into an ASCII HEX string
#
sub _oct2hex {
    my ($self, $v) = @_;
    return uc( sprintf('%s', unpack('H*', $v)) );
}

#####################################################################
# ifHighSpeed is an estimate of the interface's current bandwidth in units
# of 1,000,000 bits per second.  
# We store interface speed as bps (integer format)
#
sub _munge_speed_high {
    my ($self, $v) = @_;
    return $v * 1000000;
}

############################################################################
#
# search_by_type - Get a list of Device objects by type
#
#
__PACKAGE__->set_sql(by_type => qq{
    SELECT d.id
	FROM device d, product p, producttype t, rr
	WHERE d.product = p.id AND
	p.type = t.id AND
	rr.id = d.name AND
	t.id = ?
	ORDER BY rr.name
    });

__PACKAGE__->set_sql(no_type => qq{
    SELECT p.name, p.id, COUNT(d.id) AS numdevs
        FROM device d, product p
        WHERE d.product = p.id AND
        p.type = 0
        GROUP BY p.name, p.id
        ORDER BY numdevs DESC
    });


=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2006 University of Oregon, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

#Be sure to return 1
1;

