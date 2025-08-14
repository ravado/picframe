# picframe/dht_compat.py
import time
import board
import adafruit_dht

# Map your GPIO number to a board pin. Example: GPIO4 -> board.D4
# Adjust this to your actual pin:
GPIO_TO_BOARD = {
    4: board.D4,
    17: board.D17,
    27: board.D27,
    22: board.D22,
    # add others if needed
}

class DHT22: pass  # tag only, for API parity

def read_retry(sensor, gpio_pin, retries=15, delay_seconds=2.0):
    """Mimic Adafruit_DHT.read_retry returning (humidity, temperature)."""
    pin = GPIO_TO_BOARD[gpio_pin]
    dht = adafruit_dht.DHT22(pin, use_pulseio=False)
    last_exc = None
    try:
        for _ in range(retries):
            try:
                t = dht.temperature    # °C
                h = dht.humidity       # %
                if (t is not None) and (h is not None):
                    return (h, t)
            except Exception as e:
                last_exc = e
            time.sleep(delay_seconds)
    finally:
        dht.exit()
    # If all retries failed, behave like legacy lib: return (None, None)
    return (None, None)