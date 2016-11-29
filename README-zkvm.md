# s390x z/KVM Compute Nodes + amd64 Ubuntu Control Plane Testing with Juju 2.x

## Prep

### z/KVM Preseeding

The preseed examples included in this repo (named zkvm_1* in the
tools/0-preseed directory) can be used to manually craft a set of files which
will boot, install and configure a z/KVM instance on an LPAR.

This z/KVM instance will have a primary disk containing a root and swap partition.

A preseed bundle consists of: zkvm_name.ins, zkvm_name.prm, and
zkvm_name-kickstart.cfg

Please read the heading of each file to see what information you will need.

Minimum requirements for this step:

	Disk IDs 
	Network IDs 
	VLAN IDs 
	Preseed FTP Server address, directories and file names.
	SSH key which the charm will use to log into the z/KVM instance
	OS and openstack prereqs and packages location

1. Copy zkvm_1*example files to an ftp server accessible to your lpars
2. Configure ins, prm and kickstart files with correct disks, network interfaces and network configuration
3. Access zSystems HMC - right click on the appropriate LPAR and select Recovery / Load from removable Media or Server
4. Enter correct details for ftp server
5. Select appropriate ins file

The example file contains a reboot command at the end, so after completing the installation the instance will reboot.
Once it has rebooted it is ready to be provisioned via the nova-compute-proxy charm.

### z/KVM Machine Prep

After manually provisioning or preseeding a z/KVM instance as desribed above, 
the following steps will be required.

1. Modify the bundle (bundles/zkvm/xenial-mitaka-2-machine-control-plane-next.yaml) and insert the private key generated
during the preseed step (it is also possible but not recommended to use a password
for the user specified in the bundle configuration)

2. Ensure that the nova-compute-proxy charm config values for the z/KVM IP addresses
are accurate in the xenial-mitaka-2-machine-control-plane-next.yaml file.

3. Set remote-repos to the ftp location for the openstack packages repo, e.g.
ftp://anonymous:me@10.10.10.10/zKVM/1.1.3/MAIN/openstack/mitaka/


### x86 Machine Prep

x86 machines need to be enlisted, commissioned and ready to deploy in MAAS.
See [maas.io](maas.io) for more information.  Installation and configuration
of MAAS is outside the scope of this document, as it is the same procedure as
one would follow to set up any MAAS.


#### Juju Prep

Juju needs to be configured to utilize the MAAS cluster.  See
[https://jujucharms.com/docs/stable/clouds-maas](https://jujucharms.com/docs/stable/clouds-maas) for more info.

## Deploy and Configure
  * The following script will deploy, wait for status to settle and then configure. 
    Review, adjust if necessary, and run:

    ```sh
    ./tools/1-deploy/zkvm-deploy.sh
    ```
    
## Testing

* TODO: add testing section

## Known Issues

There is a bug (https://bugs.launchpad.net/charm-nova-compute-proxy/+bug/1641464) related to the systemd timeout for the openstack-nova-compute service in combination with the way the openstack and neutron services are enabled and (re)started with systemctl - the workaround at time of writing is to ssh into the z/KVM instance and kill the hung systemctl process, then manually enable and restart the openstack and neutron services. Another slightly more simple workaround is to modify the systemd service file for openstack-nova-compute and set the start timeout to something between 30 and 60 seconds.
