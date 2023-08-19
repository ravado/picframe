import threading
import logging
import RPi.GPIO as GPIO
import time

class GpioController:

    def __init__(self, frame_controller):
        self.__logger = logging.getLogger("gpio_actions.GpioController")
        self.__logger.setLevel(logging.DEBUG)
        self.__prev_touch_sensor_pin = 20 # GPIO for previous button
        self.__next_touch_sensor_pin = 21 # GPIO for next button

        self.__frame_controller = frame_controller

        # Set up GPIO
        GPIO.cleanup()
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(self.__prev_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(self.__next_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        GPIO.add_event_detect(self.__prev_touch_sensor_pin, GPIO.FALLING, callback=self.prev_photo, bouncetime=200)
        GPIO.add_event_detect(self.__next_touch_sensor_pin, GPIO.FALLING, callback=self.next_photo, bouncetime=200)
    
    def next_photo(self, channel):
        self.__logger.info("GPIO: On Next photo pressed")
        self.__frame_controller.next()

    def prev_photo(self, channel):
        self.__logger.info("GPIO: On Previous photo pressed")
        self.__frame_controller.back()

    def __del__(self):
        # Perform the cleanup operations here
        GPIO.cleanup()
        self.__logger.debug(f"Pin {self.__prev_touch_sensor_pin} and {self.__next_touch_sensor_pin} cleanup done")