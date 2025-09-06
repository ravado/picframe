import threading
import logging
import RPi.GPIO as GPIO
import time

class GpioController:

    def __init__(self, frame_controller):
        self.__logger = logging.getLogger("gpio_actions.GpioController")
        self.__logger.setLevel(logging.DEBUG)

        self.__prev_touch_sensor_pin = 20  # GPIO for previous button
        self.__next_touch_sensor_pin = 21  # GPIO for next button
        self.__clap_sensor_pin = 4        # GPIO for clapper

        self.__clap_count = 0
        self.__clap_colldown_timer = None
        self.__clap_delay = 0.7  # seconds

        self.__frame_controller = frame_controller

        try:
            # self.__init_touch_buttons()
            self.__init_clapper()
        except Exception as e:
            self.__logger.warning("⚠️ GPIO init failed, running without GPIO support.")
            self.__logger.debug("Cause: %s", e)

    def next_photo(self, channel):
        self.__logger.info("GPIO: Next photo pressed")
        self.__frame_controller.next()

    def prev_photo(self, channel):
        self.__logger.info("GPIO: Previous photo pressed")
        self.__frame_controller.back()

    def clap_detected(self, channel):
        print("-- clap")
        if self.__clap_colldown_timer:
            self.__clap_colldown_timer.cancel()

        self.__clap_count += 1

        if self.__clap_count == 1:
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_single_clap)
        elif self.__clap_count == 2:
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_double_clap)
        else:
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_too_many_claps)

        self.__clap_colldown_timer.start()

    def __handle_single_clap(self):
        if self.__clap_count == 1:
            print("Single clap confirmed!")
            self.next_photo(None)
        self.__clap_count = 0

    def __handle_double_clap(self):
        if self.__clap_count == 2:
            print("Double clap confirmed!")
            self.prev_photo(None)
        self.__clap_count = 0

    def __handle_too_many_claps(self):
        print("Too many claps. Start again")
        self.__clap_count = 0

    def __init_touch_buttons(self):
        try:
            GPIO.cleanup([self.__prev_touch_sensor_pin, self.__next_touch_sensor_pin])
            GPIO.setmode(GPIO.BCM)

            GPIO.setup(self.__prev_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
            GPIO.setup(self.__next_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

            GPIO.add_event_detect(self.__prev_touch_sensor_pin, GPIO.FALLING, callback=self.prev_photo, bouncetime=200)
            GPIO.add_event_detect(self.__next_touch_sensor_pin, GPIO.FALLING, callback=self.next_photo, bouncetime=200)
        except Exception as e:
            self.__logger.warning("⚠️ Failed to init touch buttons, skipping.")
            self.__logger.debug("Cause: %s", e)

    def __init_clapper(self):
        try:
            GPIO.cleanup([self.__clap_sensor_pin])
            GPIO.setmode(GPIO.BCM)

            GPIO.setup(self.__clap_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
            GPIO.remove_event_detect(self.__clap_sensor_pin)  # just in case
            GPIO.add_event_detect(self.__clap_sensor_pin, GPIO.FALLING,
                                  callback=self.clap_detected, bouncetime=100)
        except Exception as e:
            self.__logger.warning("⚠️ Failed to init clapper, skipping.")
            self.__logger.debug("Cause: %s", e)

    def __del__(self):
        try:
            GPIO.cleanup()
            self.__logger.debug("GPIO cleanup done")
        except Exception as e:
            self.__logger.debug("GPIO cleanup failed: %s", e)