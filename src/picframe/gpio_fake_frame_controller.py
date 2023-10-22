import logging
import argparse
import os
import locale
import sys
from distutils.dir_util import copy_tree

from picframe import model, viewer_display, controller, gpio_actions, __version__

class GpioFakeController:
    def __init__(self):
        print("init")
        gpio_controller = gpio_actions.GpioController(self)
        
    def next(self):
        print("on next")

    def back(self):
        print("on back")

try:
    print("Init here too")
    controller = GpioFakeController()
    while True:
        pass  # Keep the script running

except KeyboardInterrupt:
    print("\nExiting...")