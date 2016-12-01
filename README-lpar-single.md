# Ubuntu OpenStack Newton s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Newton using [Juju](https://jujucharms.com) 2.0.2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04.

The Juju bundle, along with deployment procedures and post-deployment
configuration details are documented in the upstream
[OpenStack Charm Guide OpenStack-on-LXD section](http://docs.openstack.org/developer/charm-guide/openstack-on-lxd.html).

### Example Output/Artifacts
This repo contains some [example artifacts](misc/example-newton-single-lpar) from such an exercise:

 - [misc/example-newton-single-lpar/juju_status.txt](misc/example-newton-single-lpar/juju_status.txt)
 - [misc/example-newton-single-lpar/juju_status.yaml](misc/example-newton-single-lpar/juju_status.yaml)
 - [misc/example-newton-single-lpar/misc_output.txt](misc/example-newton-single-lpar/misc_output.txt)
 - [misc/example-newton-single-lpar/misc_perf_output.txt](misc/example-newton-single-lpar/misc_perf_output.txt)

### Known Issues and Workarounds

[Bug 1639239](https://bugs.launchpad.net/nova/+bug/1639239)

`ERROR nova ValueError: Invalid InitiatorConnector protocol specified ISCSI`

Nova and os-brick have known issues with s390x architectures in Newton as of this 
writing.  [Fixes](https://bugs.launchpad.net/nova/+bug/1639239/comments/11) were 
committed to master in those projects, November 2016.  These fixes will need to 
be backported to Newton in order to provide out-of-the-box functionality.

Interested parties should track the status of Ubuntu Cloud Archive targets
in the [bug](https://bugs.launchpad.net/nova/+bug/1639239).

Until that lands, for dev/test scenarios, one can use this workaround on the nova-compute Juju unit after it is initially deployed and before it is attempted to be used.

1. First, deploy the OpenStack-on-LXD Newton bundle.  Wait for units to settle with `watch juju status`.
2. Next, SSH into the nova-compute unit with something like `juju ssh nova-compute/0`.
3. Now create a new file with the following contents, save this as `~/rough.patch`.  *This is NOT the proper patch/fix that has landed in the upstream project repos, nor is it what will be backported.  However, it will suffice as a simple temporary workaround.*
 
    ```
    --- /usr/lib/python2.7/dist-packages/nova/virt/libvirt/driver.py   2016-10-12 20:25:03.000000000 +0000
    +++ /usr/lib/python2.7/dist-packages/nova/virt/libvirt/driver.py   2016-11-30 21:00:40.597903579 +0000
    @@ -350,8 +350,15 @@
     
             self.vif_driver = libvirt_vif.LibvirtGenericVIFDriver()
     
    -        self.volume_drivers = driver.driver_dict_from_config(
    -            self._get_volume_drivers(), self)
    +       # XXX: A very wide net to catch more than we really should!
    +        try:
    +            self.volume_drivers = driver.driver_dict_from_config(
    +                self._get_volume_drivers(), self)
    +        except:
    +            LOG.warning('XXX: Failed to get one or more volume drivers.')
    +
    +#        self.volume_drivers = driver.driver_dict_from_config(
    +#            self._get_volume_drivers(), self)
     
             self._disk_cachemode = None
             self.image_cache_manager = imagecache.ImageCacheManager()
    ```


4. From within the nova-compute/0 unit, apply the patch and restart the service as follows:
    ```
    sudo patch --verbose -Nb /usr/lib/python2.7/dist-packages/nova/virt/libvirt/driver.py < rough.patch
    sudo rm -fv /usr/lib/python2.7/dist-packages/nova/virt/libvirt/*pyc
    sudo service nova-compute restart 
    ```
5. Finally, continue with the remainder of the OpenStack-on-LXD procedure.
