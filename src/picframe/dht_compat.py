# picframe/dht_compat.py
import time
import logging
import board
import adafruit_dht

logger = logging.getLogger("dht_compat")

# Map your GPIO number to a board pin. Extend if you use more pins.
GPIO_TO_BOARD = {
    4: board.D4,
    17: board.D17,
    27: board.D27,
    22: board.D22,
}

class DHT22:
    """Tag only, for API parity with legacy Adafruit_DHT."""
    pass

def read_retry(sensor, gpio_pin, retries=15, delay_seconds=2.0):
    """Mimic Adafruit_DHT.read_retry returning (humidity, temperature)."""
    pin = GPIO_TO_BOARD.get(gpio_pin)
    if pin is None:
        logger.warning(f"Unsupported GPIO pin {gpio_pin} for DHT sensor")
        return (None, None)

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
                logger.debug("Retry failed reading DHT22: %s", e)
            time.sleep(delay_seconds)
    finally:
        dht.exit()

    logger.warning("All retries failed reading DHT22 on pin %s. Last error: %s", gpio_pin, last_exc)
    return (None, None)