import threading
import logging


class GpioController:
    def __init__(self, frame_controller, config=None):
        self.__logger = logging.getLogger("gpio_actions.GpioController")
        self.__logger.setLevel(logging.DEBUG)

        # Get pin config with fallback defaults
        if config is None:
            config = {}
        self.__prev_touch_sensor_pin = config.get('prev_touch_sensor_pin', 20)
        self.__next_touch_sensor_pin = config.get('next_touch_sensor_pin', 21)
        self.__clap_sensor_pin = config.get('clap_sensor_pin', 4)
        self.__chip_path = config.get('gpiochip', '/dev/gpiochip0')

        self.__clap_count = 0
        self.__clap_colldown_timer = None
        self.__clap_delay = config.get('clap_delay', 0.7)

        self.__frame_controller = frame_controller

        self.__gpiod = None
        self.__request = None
        self.__pending = {}       # pin -> callback, collected before the request is opened
        self.__callbacks = {}     # pin -> callback, active after the request is opened
        self.__running = False

        try:
            import gpiod
            from gpiod.line import Edge
            self.__gpiod = gpiod
            self.__edge = Edge
            # self.__init_touch_buttons()
            self.__init_clapper()
            self.__start()
        except Exception as e:
            self.__logger.warning("⚠️ GPIO unavailable: %s", e)
            self.__gpiod = None
            self.__request = None

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
        self.__pending[self.__prev_touch_sensor_pin] = self.prev_photo
        self.__pending[self.__next_touch_sensor_pin] = self.next_photo

    def __init_clapper(self):
        self.__pending[self.__clap_sensor_pin] = self.clap_detected

    def __start(self):
        """Open a single line request for all configured pins and start the event loop."""
        if not self.__pending:
            return
        try:
            line_config = {
                pin: self.__gpiod.LineSettings(edge_detection=self.__edge.FALLING)
                for pin in self.__pending
            }
            self.__request = self.__gpiod.request_lines(
                self.__chip_path,
                consumer="picframe",
                config=line_config,
            )
            self.__callbacks = dict(self.__pending)
            self.__running = True
            threading.Thread(target=self.__event_loop, daemon=True).start()
        except Exception as e:
            self.__logger.warning("⚠️ Failed to init GPIO lines, skipping.")
            self.__logger.debug("Cause: %s", e)
            self.__request = None

    def __event_loop(self):
        """Background thread to listen for GPIO edge events."""
        while self.__running:
            # wait_edge_events takes a timeout in seconds (float); returns False on timeout
            if self.__request.wait_edge_events(0.1):  # 100 ms
                for event in self.__request.read_edge_events():
                    cb = self.__callbacks.get(event.line_offset)
                    if cb:
                        cb(event.line_offset)

    def __del__(self):
        try:
            self.__running = False
            if self.__request:
                self.__request.release()
            self.__logger.debug("gpiod cleanup done")
        except Exception as e:
            self.__logger.debug("gpiod cleanup failed: %s", e)
