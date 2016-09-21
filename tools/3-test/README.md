# Testing
## Manual testing

You should be able to launch a nova container as follows:

If you have not already sourced novarc:

~~~
source novarc
~~~

Then, to launch a xenial instance:

~~~
./tools/instance_launch.sh 5 xenial-s390x
~~~

You should receive details on how to ssh to this machine in the output.

To see if the instance was launched successfully:

~~~
nova list
~~~

If the instance is ready, use the ssh command provided in the instance_launch
output to see if you can ssh to the nova instance.

