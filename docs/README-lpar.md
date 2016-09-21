TODO: automated 3-testing and 4-collect

# Ubuntu Native LPAR Testing with Juju 1.25.x [stable]

## Preseeding

The preseed examples in this directory (named lpar_1) can be used to manually
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

Tokenise can also be found at: github.com/xxxxx/tokenise

There is currently a bug with setting bridge_state after a reboot. It must be set manually after any reboot.


## Deploying 

Once your preseed bundles are crafted, each lpar can be "reloaded from removable 
media" manually and the appropriate preseed selected

### Bootstrap juju environment

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
output to see if you can ssh to the nova instance.

~~~~
e.g. 
ssh -i ~/testkey.pem ubuntu@ip_address
~~~~

### 4-collect




