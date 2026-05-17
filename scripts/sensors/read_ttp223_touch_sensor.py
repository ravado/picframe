import RPi.GPIO as GPIO
import time

# Set up the GPIO pin connected to the TTP223 sensor
GPIO.setmode(GPIO.BCM)
GPIO.setup(17, GPIO.IN)  # Change this to the GPIO pin you connected the TTP223 I/O pin to

try:
    while True:
        touch_state = GPIO.input(17)  # Read the touch state

        if touch_state:
            print("Touch detected")
        else:
            print("No touch detected")

        time.sleep(0.5)  # Wait for a while before reading the touch state again

except KeyboardInterrupt:
    GPIO.cleanup()  # Clean up the GPIO settings on exit

