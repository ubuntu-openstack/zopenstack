#!/usr/bin/env python

from glob import glob
from jinja2 import FileSystemLoader, Environment
import json
import os
import shutil

# path to hosts (parmfile.json)
path = "./hosts"

templates = [ "preseed.cfg.jinja",
              "parmfile.ubuntu.jinja" ]
template_loader = FileSystemLoader( "templates" )
templateEnv = Environment( loader = template_loader )

def my_render(parms):
  target = parms[ "HOSTNAME" ]
  output_target = "output/" + target

  print( "\nGenerating preseed for " + target )

  print( "... populating " + output_target )
  shutil.copytree( "preseed_input", output_target )

  print( "... rendering " + output_target + "/boot/parmfile.ubuntu" )
  template = templateEnv.get_template( "parmfile.ubuntu.jinja" )
  f = open( output_target + "/boot/parmfile.ubuntu", "w" )
  f.write( template.render( parms ) )
  f.close()

  print( "... rendering " + output_target + "/boot/preseed/preseed.cfg" )
  template = templateEnv.get_template( "preseed.cfg.jinja" )
  f = open( output_target + "/boot/preseed/preseed.cfg", "w" )
  f.write( template.render( parms ) )
  f.close()

def gather_parmfiles(path):
  return glob( path + "/*.parmfile.json" )

if __name__ == "__main__":
  if os.path.exists( "output/" ):
    print( "\nCleaning up stale contents in output directory ..." )
    shutil.rmtree( "output/" )

  for parmfile in gather_parmfiles( path ):
    with open( parmfile, "r" ) as f:
      parms = json.loads( f.read() )
    my_render(parms)
