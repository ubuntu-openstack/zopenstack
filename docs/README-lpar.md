TODO: create a step-by-step doc for reproducing the deployment of the test model, and the testing of said model.

# Ubuntu Native LPAR Testing with Juju 1.25.x [stable]
## Deployment

We will assume you are in the zopenstack root directory.

### 0-preseed

link: tools/0-preseed/README.md

The preseed examples in this directory (named lpar_1) can be used to manually
craft a set of files which will configure an lpar for network connectivity. 

This lpar will have a primary disk containing a root and swap partition.

A preseed bundle consists of: lpar_name.ins, parmfile-lpar_name, and 
preseed-lpar_name.

Please read the heading of each file to see what information you will need.

In general, you will need to know:

Disk IDs
Network IDs
VLAN IDs
Preseed FTP Server address, directories and file names.

There is also a tool called 'tokenise' included here, which will currently
generate a single preseed file based on command line switches. A future version
of tokenise will use a yaml to output multiple preseed bundles.

Tokenise can also be found at: github.com/xxxxx/tokenise

### 1-deploy

link: tools/1-deploy/README.md

# Deploying 

## Preseed

Once your preseed bundles are crafted, each lpar can be "reloaded from removable 
media" manually and the appropriate preseed selected

## Bootstrap juju environment

To achieve this, you will need to use an existing LPAR or other machine which 
has network connectivity to the LPARS. First, install juju (instructions?)

Then bootstrap:

juju 1.25.x:

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
juju bootstrap -e manual
~~~~

## Add machines to juju

If you have specified a user other than ubuntu in your preseed, change it here.
You will also need to know the ip address of each LPAR.

~~~~
juju add-machine ssh:ubuntu@10.0.0.3
juju add-machine ssh:ubuntu@10.0.0.4
juju add-machine ssh:ubuntu@10.0.0.5
juju add-machine ssh:ubuntu@10.0.0.6
juju add-machine ssh:ubuntu@10.0.0.7
~~~~


## Deploy the openstack bundle

~~~~
juju-deployer -vdc bundles/lpar/xenial-mitaka-stable.yaml
~~~~


### 2-configure

link: tools/2-configure/README.md

# Configuring Openstack
## Configure and the s390x profile

The openstack-charm-testing repo provides profiles scripts and profiles
to configure an openstack environment.

simply run 

~~~~
source tools/2-configure/novarc
tools/2-configure/configure s390x-multi-lpar
~~~~

Once the configuration is complete, you can move onto the testing phase

Todo: modify neutron-net and neutron-tenant to add vlan in as per pastebin:

https://pastebin.canonical.com/164921/


### 3-test

link: tools/3-test/README.md

# Testing
## Manual testing

You should be able to launch a nova instance as follows:

~~~~
tools/2-configure/tools/instance_launch.sh 5 xenial-s390x
~~~~

You should receive details on how to ssh to this machine in the output.

To see if the instance was launched successfully:

~~~~
nova list
~~~~

If the instance is ready, use the ssh command provided in the instance_launch
output to see if you can ssh to the nova instance.

### 4-collect




