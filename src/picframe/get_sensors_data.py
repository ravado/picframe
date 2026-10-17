import time
import threading
import logging
import json
import hashlib

logger = logging.getLogger("sensors")

class SensorData:
    def __init__(self, config):
        self.show_sensors = bool(config.get("show_sensors", False))

        # GPIO pin number where the outside DHT22 sensor is connected
        self.outside_sensor_pin = config.get("outside_sensor_pin", 17)

        # I2C address of the inside BME280 sensor (default 0x76)
        self.inside_sensor_address = config.get("inside_sensor_address", 0x76)

        self.sensors_update_rate_in_seconds = config.get("sensors_update_rate_in_seconds", 30)

        self.__prev_sensors_hash = None
        self.sensors_update_subscribers = []
        self.last_reading_time = 0

        self.inside_sensor_data = self._default_sensor_data()
        self.outside_sensor_data = self._default_sensor_data()

        self.stop_thread = False
        self.thread = threading.Thread(target=self.fetch_sensor_data, daemon=True)
        self.thread.start()

    def _default_sensor_data(self):
        return {
            "is_online": False,
            "temperature": "0.0",
            "humidity": "0",
            "pressure": "0",
        }

    def subscribe_to_sensors_updates(self, callback):
        self.sensors_update_subscribers.append(callback)

    def fetch_sensor_data(self):
        if not self.show_sensors:
            # nothing to do, just idle quietly
            while not self.stop_thread:
                time.sleep(1)
            return

        while not self.stop_thread:
            current_time = time.time()
            if current_time - self.last_reading_time >= self.sensors_update_rate_in_seconds:
                self.inside_sensor_data = self.get_inside_sensor_data()
                self.outside_sensor_data = self.get_outside_sensor_data()
                self.last_reading_time = current_time
                self.__notify_subscribers_if_data_really_changed()
            time.sleep(1)

    def get_inside_sensor_data(self):
        if not self.show_sensors:
            return self._default_sensor_data()
        try:
            import board
            import busio
            from adafruit_bme280 import basic as adafruit_bme280

            i2c = busio.I2C(board.SCL, board.SDA)
            bme280 = adafruit_bme280.Adafruit_BME280_I2C(
                i2c, address=self.inside_sensor_address
            )
            return self.format_sensor_data(bme280.temperature, bme280.humidity, bme280.pressure)
        except Exception as e:
            logger.debug("BME280 sensor unavailable: %s", e)
            return self._default_sensor_data()
    
    def get_outside_sensor_data(self):
        if not self.show_sensors:
            return self._default_sensor_data()
        try:
            from picframe import dht_compat as Adafruit_DHT

            humidity, temperature = Adafruit_DHT.read_retry(
                Adafruit_DHT.DHT22, self.outside_sensor_pin
            )
            return self.format_sensor_data(temperature, humidity)
        except Exception as e:
            logger.debug("DHT22 sensor unavailable: %s", e)
            return self._default_sensor_data()

    def format_sensor_data(self, temperature, humidity, pressure=None):
        is_sensor_online = True
        if humidity is None or temperature is None:
            return self._default_sensor_data()
        if pressure is None:
            pressure = 0.0
        # convert hPa to mmHg
        pressure = pressure * 0.75006
        return {
            "is_online": is_sensor_online,
            "temperature": f"{temperature:.1f}",
            "humidity": f"{humidity:.0f}",
            "pressure": f"{pressure:.0f}"
        }

    def get_last_inside_sensor_data(self):
        return self.inside_sensor_data

    def get_last_outside_sensor_data(self):
        return self.outside_sensor_data

    def stop(self):
        self.stop_thread = True
        self.thread.join(timeout=2)

    def __notify_subscribers_if_data_really_changed(self):
        all_values_string = json.dumps(self.inside_sensor_data) + json.dumps(self.outside_sensor_data)
        current_sensors_hash = hashlib.sha256(all_values_string.encode()).hexdigest()
        if self.__prev_sensors_hash != current_sensors_hash:
            self.__notify_subscribers()
        self.__prev_sensors_hash = current_sensors_hash

    def __notify_subscribers(self):
        for subscriber in self.sensors_update_subscribers:
            try:
                subscriber()
            except Exception as e:
                logger.error("Subscriber callback failed: %s", e)