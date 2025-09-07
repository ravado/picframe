import threading
import logging
import gpiod
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
            self.__chip = gpiod.Chip("gpiochip0")
            self.__lines = {}
            # self.__init_touch_buttons()
            self.__init_clapper()
        except Exception as e:
            self.__logger.warning("⚠️ gpiod init failed, running without GPIO support.")
            self.__logger.debug("Cause: %s", e)
            self.__chip = None

    def next_photo(self, line):
        self.__logger.info("GPIO: Next photo pressed")
        self.__frame_controller.next()

    def prev_photo(self, line):
        self.__logger.info("GPIO: Previous photo pressed")
        self.__frame_controller.back()

    def clap_detected(self, line):
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
            for pin, cb in [
                (self.__prev_touch_sensor_pin, self.prev_photo),
                (self.__next_touch_sensor_pin, self.next_photo),
            ]:
                line = self.__chip.get_line(pin)
                line.request(consumer="picframe", type=gpiod.LINE_REQ_EV_FALLING_EDGE)
                self.__lines[pin] = (line, cb)

            threading.Thread(target=self.__event_loop, daemon=True).start()
        except Exception as e:
            self.__logger.warning("⚠️ Failed to init touch buttons, skipping.")
            self.__logger.debug("Cause: %s", e)

    def __init_clapper(self):
        try:
            line = self.__chip.get_line(self.__clap_sensor_pin)
            line.request(consumer="picframe", type=gpiod.LINE_REQ_EV_FALLING_EDGE)
            self.__lines[self.__clap_sensor_pin] = (line, self.clap_detected)

            threading.Thread(target=self.__event_loop, daemon=True).start()
        except Exception as e:
            self.__logger.warning("⚠️ Failed to init clapper, skipping.")
            self.__logger.debug("Cause: %s", e)

    def __event_loop(self):
        """Background thread to listen for GPIO events."""
        while True:
            for pin, (line, cb) in self.__lines.items():
                ev = line.event_wait(sec=0.1)
                if ev:
                    event = line.event_read()
                    if event.type == gpiod.LineEvent.FALLING_EDGE:
                        cb(pin)

    def __del__(self):
        try:
            for line, _ in self.__lines.values():
                line.release()
            if self.__chip:
                self.__chip.close()
            self.__logger.debug("gpiod cleanup done")
        except Exception as e:
            self.__logger.debug("gpiod cleanup failed: %s", e)