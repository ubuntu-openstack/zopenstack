tokenise.py takes some params (-h for help) and writes out a preseed and parmfile
from those values, using templates.

e.g.:

	tokenise.py -i 10.0.0.1 -d 10.0.0.100 -v 2020 -n server1 -a 0.0.0200,0.0.0300 -f ftpserver
