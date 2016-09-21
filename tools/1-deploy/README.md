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

~~~~~
environments:
  manual:
    type: manual
    bootstrap-host: 10.0.0.2
~~~

To bootstrap: 
~~~
juju bootstrap -e manual
~~~

## Add machines to juju

If you have specified a user other than ubuntu in your preseed, change it here.
You will also need to know the ip address of each LPAR.

~~~
juju add-machine ssh:ubuntu@10.0.0.3
juju add-machine ssh:ubuntu@10.0.0.4
juju add-machine ssh:ubuntu@10.0.0.5
juju add-machine ssh:ubuntu@10.0.0.6
juju add-machine ssh:ubuntu@10.0.0.7
~~~


## Deploy the openstack bundle

~~~
(from dir ./zopenstack/tools/1-deploy)
juju-deployer -vdc ../../bundles/lpar/xenial-mitaka-stable.yaml
~~~

