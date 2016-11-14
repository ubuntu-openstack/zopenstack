# s390x z/KVM Compute Nodes + amd64 Ubuntu Control Plane Testing with Juju 2.x

## Prep

### z/KVM Machine Prep

The z/KVM machines need to be provisioned and configured in advance of the
OpenStack control plane and compute node deployment.

1. SSH keys generated and added to authorized_keys, to allow the proxy charm to perform remote operations on the z/KVM machines via ssh. 
2. Mount and repoprep the osprereqs and openstack compute ISOs on each z/KVM machine.
    * Example:
        ```
        mkdir /mnt/osprereqs
        mkdir /mnt/osmitakacomp
        mount -o loop zkvm-1.1.2-rc1.6-osprereqs-0.1.0.iso /mnt/osprereqs
        mount -o loop openstack-mitaka-compute-0.1.0.iso /mnt/osmitakacomp
        createrepo /mnt/osmitakacomp
        createrepo /mnt/osprereqs
        ```
3. Ensure that the nova-compute-proxy charm config values for these are accurate in the bundle.yaml file.
   

### x86 Machine Prep

x86 machines need to be enlisted, commissioned and ready to deploy in MAAS. 
See [maas.io](maas.io) for more information.  Installation and configuration
of MAAS is outside the scope of this document, as it is the same procedure as
one would follow to set up any MAAS.


#### Juju Prep

Juju needs to be configured to utilize the MAAS cluster.  See
[https://jujucharms.com/docs/stable/clouds-maas](https://jujucharms.com/docs/stable/clouds-maas) for more info.

## Deploying
  * Review, adjust if necessary, and run:
    ```sh
    ./tools/1-deploy/zkvm-deploy.sh
    ```

## Post-Deploy Configuration
  * After confirming Juju status for all units is reported as Ready, configure
    the deployed cloud with tenants, images, networks, and such.
    ```sh
    cd ../tools/2-configure
    ./configure
    ```

## Post-Deploy Configuration

* TODO: add post-deploy config section

## Testing

* TODO: add testing section
