# Ubuntu Native LPAR Testing with Juju 1.25.x and 2.1

## Preseeding

The preseed examples in this repo (named lpar_1 in tools/0-preseed/) can be used to manually
craft a set of files which will configure an lpar for network connectivity. 

This lpar will have a primary disk containing a root and swap partition.

A preseed bundle consists of: lpar_name.ins, parmfile-lpar_name, and 
preseed-lpar_name.

Please read the heading of each file to see what information you will need.

In general, you will need to know:

* Disk IDs
* Network IDs
* VLAN IDs
* Preseed FTP Server address, directories and file names.

There is also a tool called 'tokenise' included here, which will currently
generate a single preseed file based on command line switches. A future version
of tokenise will use a yaml to output multiple preseed bundles.

The tokenise tool can be found in tools/0-preseed/tokenise.

There is currently a bug with setting bridge_state after a reboot. It must be set manually after any reboot, e.g.:

~~~~
echo primary > /sys/devices/qeth/0.0.c003/bridge_role
~~~~


## Deploying 

Once your preseed bundles are crafted, each lpar can be "reloaded from removable 
media" manually and the appropriate preseed selected

### Bootstrap juju environment

#### juju 1.x

To achieve this, you will need to use an existing LPAR or other machine which 
has network connectivity to the LPARS. First, install juju (instructions?)

Your ~/.juju/environments.yaml should have a 'manual' stanza which looks like
the following:

~~~~
environments:
  manual:
    type: manual
    bootstrap-host: 10.0.0.2
~~~~

To bootstrap: 
~~~~
juju switch manual
juju bootstrap
~~~~

#### juju 2.1.0

Currently, the easiest way to install juju 2.1.0 on z is with via a snap (at the time of writing, 2.1.0 is in the 'beta' channel', other versions can be installed by checking "snap info juju" and specifying the appropriate channel):

~~~~
sudo apt-get install snapd
sudo snapd install juju --devmode --beta
~~~~

To bootstrap:

~~~~
juju bootstrap manual/Bootstrap_host_IP controller_name --debug --verbose --constraints arch=architecture

e.g.

juju bootstrap manual/127.0.0.1 s390x --debug --verbose --constraints arch=s390x
~~~~


### Add machines to juju

If you have specified a user other than ubuntu in your preseed, change it here.
You will also need to know the ip address of each LPAR.

~~~~
juju add-machine ssh:ubuntu@10.0.0.3
juju add-machine ssh:ubuntu@10.0.0.4
juju add-machine ssh:ubuntu@10.0.0.5
juju add-machine ssh:ubuntu@10.0.0.6
juju add-machine ssh:ubuntu@10.0.0.7
~~~~

### Clone this repo

~~~~
git@github.com:ubuntu-openstack/zopenstack.git
git checkout multi-lpar-native
~~~~

### Deploy the openstack bundle

Note: please ensure juju-deployer is version 0.9.2 or greater. 0.10 is available via pip at time of writing.
~~~~
cd zopenstack
juju-deployer -vdc bundles/lpar/xenial-mitaka-stable.yaml
~~~~

## Configuring Openstack
### Configure and the s390x profile

The openstack-charm-testing repo provides scripts and profiles
to configure an openstack environment.

simply run 

~~~~
cd tools/2-configure
source novarc
./configure s390x-multi-lpar
~~~~

Once the configuration is complete, you can move onto the testing phase

## Testing
### Manual testing

You should be able to launch a nova instance as follows:

~~~~
# launch some instances
./tools/instance_launch.sh 5 xenial-s390x
# give these instances public (ext_net) ip addresses
./tools/float_all.sh
~~~~

To see if the instance was launched successfully:

~~~~
nova list
~~~~

If the instance is ready, use the ssh command provided in the instance_launch
output to see if you can ssh to the nova instance, e.g.:

~~~~
ssh -i ~/testkey.pem ubuntu@ip_address
~~~~

### Tempest testing

WIP

## Collection

WIP




