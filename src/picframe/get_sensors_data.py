import time
import threading
import Adafruit_DHT
import board
import busio
import json
import hashlib
import adafruit_bme280
from adafruit_bme280 import basic as adafruit_bme280

class SensorData:
    def __init__(self, update_rate_in_seconds):
        self.__prev_sensors_hash = None

        self.outside_gpio = 4
        self.inside_i2c_address = 0x76

        self.sensors_update_subscribers = []
        self.last_reading_time = 0
        self.sensors_update_rate_in_seconds = update_rate_in_seconds
        
        self.inside_sensor_data = {}
        self.outside_sensor_data = {}
        
        self.stop_thread = False
        self.thread = threading.Thread(target=self.fetch_sensor_data)
        self.thread.start()

    def subscribe_to_sensors_updates(self, callback):
        # print(f"SensorData: Subscribed")
        self.sensors_update_subscribers.append(callback)

    def fetch_sensor_data(self):
        while not self.stop_thread:
            current_time = time.time()
            if current_time - self.last_reading_time >= self.sensors_update_rate_in_seconds:
                self.inside_sensor_data = self.get_inside_sensor_data()
                self.outside_sensor_data = self.get_outside_sensor_data()
                self.last_reading_time = current_time
                
                # # Fire event for subscribers only if data has really changed
                
                # all_values_string = self.inside_sensor_data + self.outside_sensor_data;
                # current_sensors_hash = hash(all_values_string)
                
                # if (self.__prev_sensors_hash != current_sensors_hash):
                #     self.__notify_subscribers()
                
                # self.__prev_sensors_hash = current_sensors_hash
                self.__notify_subscribers_if_data_really_changed()

            time.sleep(1)

    def get_inside_sensor_data(self):
        try:
            # Create I2C bus
            i2c = busio.I2C(board.SCL, board.SDA)

            # Create BME280 object
            bme280 = adafruit_bme280.Adafruit_BME280_I2C(i2c, address=0x76)

            #sensor = BME280(i2c_dev='/dev/i2c-1', i2c_addr=self.inside_i2c_address)
            temperature = bme280.temperature
            humidity = bme280.humidity
            pressure = bme280.pressure
            
            # print("BME280: ---- ")
            # print(f"Temperature: {bme280.temperature} °C")
            # print(f"Humidity: {bme280.humidity} %")
            # print(f"Pressure: {bme280.pressure} hPa")

        except Exception as e:
            temperature = None
            humidity = None
            pressure = None

        return self.format_sensor_data(temperature, humidity, pressure)
    
    def get_outside_sensor_data(self):
        humidity, temperature = Adafruit_DHT.read_retry(Adafruit_DHT.DHT22, self.outside_gpio)

        # print("DHT22: ---- ")
        # print(f"Temperature: {temperature} °C")
        # print(f"Humidity: {humidity} %")

        return self.format_sensor_data(temperature, humidity)

    def format_sensor_data(self, temperature, humidity, pressure =None):
        is_sensor_online = True
        if humidity is None:
            is_sensor_online = False
            humidity = 0.0
        if temperature is None:
            is_sensor_online = False
            temperature = 0.0
        if pressure is None:
            pressure = 0.0
        return {
            'is_online': is_sensor_online,
            'temperature': f"{temperature:.1f}",
            'humidity': f"{humidity:.0f}",
            'pressure': f"{pressure:.0f}"
        }

    def get_last_inside_sensor_data(self):
        return self.inside_sensor_data

    def get_last_outside_sensor_data(self):
        return self.outside_sensor_data

    def stop(self):
        self.stop_thread = True
    
    def __notify_subscribers_if_data_really_changed(self):
        all_values_string = json.dumps(self.inside_sensor_data) + json.dumps(self.outside_sensor_data)
        current_sensors_hash = hash(all_values_string)
        
        # print(f"Prev hash: {self.__prev_sensors_hash}, currentHash: {current_sensors_hash}")
        if (self.__prev_sensors_hash != current_sensors_hash):
            self.__notify_subscribers()
        
        self.__prev_sensors_hash = current_sensors_hash

    def __notify_subscribers(self):
        # print(f"SensorData: Notify subscribers")
        # Notify all subscribers
        for subscriber in self.sensors_update_subscribers:
            subscriber()
    
    def __calculate_hash(dictionary):
        json_string = json.dumps(dictionary, sort_keys=True)
        return hashlib.sha256(json_string.encode()).hexdigest()
