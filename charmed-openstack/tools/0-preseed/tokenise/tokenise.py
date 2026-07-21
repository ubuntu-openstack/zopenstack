#!/usr/bin/env python
import argparse
import sys

parser = argparse.ArgumentParser(description="Generate parmfile and preseed from template")

parser.add_argument('-t', '--cfgtemplate', help='preseed template filename, defaults to preseed.cfg.template', default='preseed.cfg.template')
parser.add_argument('-r', '--parmtemplate', help='parmfile template filename, defaults to parmfile.template', default='parmfile.template')
parser.add_argument('-s', '--instemplate', help='ins template filename, defaults to hostname.ins.template', default='hostname.ins.template')
parser.add_argument('-c', '--cfgfile', help='preseed output filename, defaults to preseed-$hostname.cfg')
parser.add_argument('-p', '--parmfile', help='parmfile output filename, defaults to parmfile.hostname')
parser.add_argument('-b', '--insfile', help='ins output filename, defaults to hostname.ins')
parser.add_argument('-i', '--ip', help='ip address', required=True)
parser.add_argument('-m', '--mask', help='netmask, defaults to 255.255.255.0 (/24)', default='255.255.255.0')
parser.add_argument('-g', '--gateway', help='network gateway, defaults to ipaddress.1')
parser.add_argument('-d', '--dns', help='nameserver', required=True)
parser.add_argument('-v', '--vlan', help='vlan id', required=True)
parser.add_argument('-n', '--hostname', help='hostname', required=True)
parser.add_argument('-x', '--domain', help='domain name, defaults to canonical.com', default='canonical.com')
parser.add_argument('-a', '--dasd', help='dasd id for primary disk, e.g. 0.0.0200', required=True)
# the following parser tokens are yet to be implemented: 
#parser.add_argument('-o', '--otherdasd', help='comma separated dasd string for non-root partitions, e.g. 0.0.3000,0.0.0400', required=True)
#parser.add_argument('-l', '--labels', help='comma separated label list for other dasds, e.g. ceph,swift. If no label for a dasds then it will not be mounted', required=True)
#parser.add_argument('-1', '--blocksize', help='comma separted blocksizes for other dasds, e.g. 4096,4096', required=True)
#parser.add_argument('-2', '--filesystem', help='comma separted filesystems for other dasds, e.g. xfs,ext4', required=True)
#parser.add_argument('-3', '--network2', help='second network interface')
#parser.add_argument('-4', '--bridge', help='a single interface to put in bridge port mode')
parser.add_argument('-f', '--ftp', help='ftp server address', required=True)
parser.add_argument('-u', '--username', help='access username', required=True)
parser.add_argument('-e', '--fullname', help='access user fullname', required=True)
parser.add_argument('-w', '--passwdcrypted', help='access user passwd crypted', required=True)
args = parser.parse_args()

tokens = {}

tokens['CFGFILE'] = args.cfgfile
tokens['PARMFILE'] = args.parmfile
tokens['INSFILE']  =args.insfile
tokens['IP_ADDR'] = args.ip
tokens['MASK'] = args.mask
tokens['GATEWAY'] = args.gateway
tokens['DOMAIN'] = args.domain
tokens['OTHERDASD'] = args.otherdasd
if tokens['GATEWAY'] == None:
	tokens['GATEWAY'] = '.'.join(tokens['IP_ADDR'].split('.')[0:3]) + '.1'
tokens['DNS'] = args.dns
tokens['VLAN'] = args.vlan
tokens['HOSTNAME'] = args.hostname
if tokens['CFGFILE'] == None:
	tokens['CFGFILE'] = 'preseed-' + tokens['HOSTNAME'] + '.cfg'
if tokens['PARMFILE'] == None:
	tokens['PARMFILE'] = 'parmfile.' + tokens['HOSTNAME']
if tokens['INSFILE'] == None:
	tokens['INSFILE'] = tokens['HOSTNAME'] + '.ins'
tokens['DASDSTRING'] = args.dasd
tokens['FTPSERVER'] = args.ftp
tokens['USERNAME'] = args.username
tokens['FULLNAME'] = args.fullname
tokens['PASSWDCRYPTED'] = args.passwdcrypted

def create_file(infile, outfile):
	f = open(infile, "r")
	filedata = f.read()
	f.close()

	for key, value in tokens.iteritems():
		wrapkey = "{" + key + "}"
		filedata = filedata.replace(wrapkey, value)

	f = open(outfile, "w")
	f.write(filedata)
	f.close()

create_file(args.parmtemplate, tokens['PARMFILE'])
create_file(args.cfgtemplate, tokens['CFGFILE'])
create_file(args.instemplate, tokens['INSFILE'])
