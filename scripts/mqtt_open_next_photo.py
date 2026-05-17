import paho.mqtt.client as mqtt

# MQTT broker details
broker_address = "localhost"
broker_port = 1883
broker_username = ""
broker_password = ""

# MQTT message details
topic = "homeassistant/button/picframe_next/set"
payload = "ON"

# Callback for successful connection to the broker
def on_connect(client, userdata, flags, rc):
    print("Connected with result code " + str(rc))
    client.publish(topic, payload)

# Callback for successful message publication
def on_publish(client, userdata, mid):
    print("Message published, id: " + str(mid))

# Create an MQTT client
client = mqtt.Client()

# Set MQTT client credentials, if required
client.username_pw_set(broker_username, broker_password)

# Assign event callbacks
client.on_connect = on_connect
client.on_publish = on_publish

# Connect to the MQTT broker
client.connect(broker_address, broker_port, 60)

# Start the MQTT loop
client.loop_forever()

