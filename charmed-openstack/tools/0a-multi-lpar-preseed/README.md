# Ubuntu LPAR (s390x) Installation Preseed Generator script

## Use a python virtual environment to keep your environment clean.
Currently we're only using jinja2 here.

```
$ virtualenv preseeder; cd preseeder/; source bin/activate
(preseeder)[preseeder]$ git clone https://github.com/vmorris/ubuntu_lpar_preseed_generator.git
(preseeder)[preseeder]$ cd ubuntu_lpar_preseed_generator/
(preseeder)[ubuntu_lpar_preseed_generator]$ pip install -r requirements.txt
```

## Usage:
TODO: give better description using the example inputs
* hosts/ contains a json parameter files, each one represents an LPAR
* after creating all the host parameter files desired, simply run generate.py
* output/ will contain a directory for each input host file with unique parameters applied
* some interesting behavior in labeling multiple disks, see hosts/example2.parmfile.json

## Note:
* The contents of the preseed_input/boot directory are copied from the [Ubuntu 16.04.1 ISO][1] /boot directory.

[1]: http://cdimage.ubuntu.com/releases/xenial/release/ubuntu-16.04.1-server-s390x.iso
