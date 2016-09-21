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
