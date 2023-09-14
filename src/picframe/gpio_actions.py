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
        self.__clap_sensor_pin = 17 # GPIO for clapper

        # Variables to keep track of claps
        self.__clap_count = 0
        self.__clap_colldown_timer = None
        self.__clap_delay = 0.7  # Adjust this delay as needed

        self.__frame_controller = frame_controller

        # self.__init_touch_buttons()
        self.__init_clapper()
    
    def next_photo(self, channel):
        self.__logger.info("GPIO: On Next photo pressed")
        self.__frame_controller.next()

    def prev_photo(self, channel):
        self.__logger.info("GPIO: On Previous photo pressed")
        self.__frame_controller.back()


    def clap_detected(self, channel):
        # global clap_count, timer

        print("-- clap")

        if self.__clap_colldown_timer:
            self.__clap_colldown_timer.cancel() 

        self.__clap_count += 1

        # if(clap_count > 2):
        #     clap_count = 0
        #     print("Too many claps. Start again")
        #     return

        if self.__clap_count == 1:
            # print("Single clap detected!")
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_single_clap)
            self.__clap_colldown_timer.start()
        elif self.__clap_count == 2:
            # print("Double clap detected!")
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_double_clap)
            self.__clap_colldown_timer.start()
        else:
            self.__clap_colldown_timer = threading.Timer(self.__clap_delay, self.__handle_too_many_claps)
            self.__clap_colldown_timer.start()
            return
        
    def __handle_single_clap(self):
        # global clap_count
        if self.__clap_count == 1:
            print("Single clap confirmed!")
            self.next_photo(None)
        self.__clap_count = 0

    def __handle_double_clap(self):
        # global clap_count
        if self.__clap_count == 2:
            print("Double clap confirmed!")
            self.prev_photo(None)
        self.__clap_count = 0
    
    def __handle_too_many_claps(self):
        print("Too many claps. Start again")
        self.__clap_count = 0

    def __init_touch_buttons(self):
        
        # Set up GPIO
        GPIO.cleanup()
        GPIO.setmode(GPIO.BCM)

        GPIO.setup(self.__prev_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(self.__next_touch_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        GPIO.add_event_detect(self.__prev_touch_sensor_pin, GPIO.FALLING, callback=self.prev_photo, bouncetime=200)
        GPIO.add_event_detect(self.__next_touch_sensor_pin, GPIO.FALLING, callback=self.next_photo, bouncetime=200)
    
    def __init_clapper(self):
        
        # Set up GPIO
        GPIO.cleanup()
        GPIO.setmode(GPIO.BCM)

        GPIO.setup(self.__clap_sensor_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        # Add an event listener to detect claps
        GPIO.add_event_detect(self.__clap_sensor_pin, GPIO.FALLING, callback=self.clap_detected, bouncetime=100)

    def __del__(self):
        # Perform the cleanup operations here
        GPIO.cleanup()
        self.__logger.debug(f"Pin {self.__prev_touch_sensor_pin} and {self.__next_touch_sensor_pin} cleanup done")