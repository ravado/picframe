import time
import Adafruit_DHT
import threading

class SensorData:
    def __init__(self, pin):
        self.pin = pin
        self.last_reading_time = 0
        self.sensors_update_rate_in_seconds = 30
        self.sensor_data = {}
        self.stop_thread = False
        self.thread = threading.Thread(target=self.fetch_sensor_data)
        self.thread.start()

    def fetch_sensor_data(self):
        while not self.stop_thread:
            current_time = time.time()
            if current_time - self.last_reading_time >= self.sensors_update_rate_in_seconds:
                # Sensor type
                sensor = Adafruit_DHT.DHT22

                # Get a reading from the sensor
                humidity, temperature = Adafruit_DHT.read_retry(sensor, self.pin)

                # If the reading failed, use 0 as the default value
                is_sensor_online = True
                if humidity is None:
                    is_sensor_online = False
                    humidity = 0.0
                if temperature is None:
                    is_sensor_online = False
                    temperature = 0.0

                # Prepare the result as a dictionary
                self.sensor_data = {
                    'is_online': is_sensor_online,
                    'temperature': f"{temperature:.1f}",
                    'humidity': f"{humidity:.1f}"
                }

                self.last_reading_time = current_time

            time.sleep(1)

    def get_latest_sensor_data(self):
        return self.sensor_data

    def stop(self):
        self.stop_thread = True
