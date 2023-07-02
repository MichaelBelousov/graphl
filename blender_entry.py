import sys
# NOTE: REPL python seems to have a special sys.path entry of the empty string which probably means cwd
# blender doesn't have it so we need to add it
sys.path.insert(0, '')

from addon import *
