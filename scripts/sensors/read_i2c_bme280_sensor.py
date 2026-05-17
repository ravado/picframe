import board
import busio
import adafruit_bme280
from adafruit_bme280 import basic as adafruit_bme280

# Create I2C bus
i2c = busio.I2C(board.SCL, board.SDA)

# Create BME280 object
bme280 = adafruit_bme280.Adafruit_BME280_I2C(i2c, address=0x76)

# Read and print data
print(f"Temperature: {bme280.temperature} °C")
print(f"Humidity: {bme280.humidity} %")
print(f"Pressure: {bme280.pressure} hPa")