import board
import adafruit_dht

DHT_PIN = 4 #board.D25  # Change this to the GPIO pin you connected the AM2301A DATA pin to

dht_device = adafruit_dht.DHT22(DHT_PIN)

try:
    temperature = dht_device.temperature
    humidity = dht_device.humidity
    if humidity is not None and temperature is not None:
        print("Temp={0:0.1f}C Humidity={1:0.1f}%".format(temperature, humidity))
    else:
        print("Failed to retrieve data from sensor")
except RuntimeError as error:
    print(error.args[0])

