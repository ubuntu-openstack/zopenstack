#!/usr/bin/env python

# Copyright 2017 IBM Corp. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
  path = output_target + "/boot/preseed"
  os.makedirs( path )
  template = templateEnv.get_template( "preseed.cfg.jinja" )
  f = open( path + "/preseed.cfg", "w" )
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
