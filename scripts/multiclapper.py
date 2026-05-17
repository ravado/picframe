import RPi.GPIO as GPIO
import time
import threading

# GPIO pin for the sensor
SENSOR_PIN = 4

# Variables to keep track of claps
clap_count = 0
timer = None
clap_delay = 0.7  # Adjust this delay as needed

# Callback function when a clap is detected
def clap_detected(channel):
    global clap_count, timer

    print("-- clap")

    if timer:
        timer.cancel() 

    clap_count += 1

    if(clap_count > 2):
        clap_count = 0
        print("Too many claps. Start again")
        return

    if clap_count == 1:
        # print("Single clap detected!")
        timer = threading.Timer(clap_delay, handle_single_clap)
        timer.start()
    elif clap_count == 2:
        # print("Double clap detected!")
        timer = threading.Timer(clap_delay, handle_double_clap)
        timer.start()

def handle_single_clap():
    global clap_count
    if clap_count == 1:
        print("Single clap confirmed!")
    clap_count = 0


def handle_double_clap():
    global clap_count
    if clap_count == 2:
        print("Double clap confirmed!")
    clap_count = 0

# Set up GPIO
GPIO.setmode(GPIO.BCM)
GPIO.setup(SENSOR_PIN, GPIO.IN, pull_up_down=GPIO.PUD_OFF)

# Add an event listener to detect claps
GPIO.add_event_detect(SENSOR_PIN, GPIO.FALLING, callback=clap_detected, bouncetime=300)

try:
    print("Listening for claps... (Ctrl+C to exit)")
    while True:
        pass  # Keep the script running

except KeyboardInterrupt:
    print("\nExiting...")

finally:
    GPIO.cleanup()
