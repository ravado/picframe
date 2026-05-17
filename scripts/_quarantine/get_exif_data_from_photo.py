from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS

def get_exif_data(filename):
    image = Image.open(filename)
    exif_data = image._getexif()
    return exif_data

def display_basic_metadata(exif_data):
    for tag, value in exif_data.items():
        if TAGS.get(tag) in ["Make", "Model", "Software"]:
            print(f"{TAGS[tag]}: {value}")

def display_gps_data(exif_data):
    gps_data = {}
    for tag, value in exif_data.items():
        if TAGS.get(tag) == "GPSInfo":
            for t in value:
                gps_data[GPSTAGS.get(t)] = value[t]
            break

    if gps_data:
        gps_latitude = gps_data.get("GPSLatitude")
        gps_latitude_ref = gps_data.get("GPSLatitudeRef")
        gps_longitude = gps_data.get("GPSLongitude")
        gps_longitude_ref = gps_data.get("GPSLongitudeRef")

        if gps_latitude and gps_latitude_ref and gps_longitude and gps_longitude_ref:
            lat = _convert_to_degrees(gps_latitude)
            if gps_latitude_ref != "N":
                lat = -lat
            lon = _convert_to_degrees(gps_longitude)
            if gps_longitude_ref != "E":
                lon = -lon
            print(f"GPS Latitude: {lat}, GPS Longitude: {lon}")
        else:
            print("No GPS data available.")
    else:
        print("No GPS data available.")

def _convert_to_degrees(value):
    d = float(value[0])
    m = float(value[1])
    s = float(value[2])

    return d + (m / 60.0) + (s / 3600.0)

if __name__ == "__main__":
    filename = "/home/ivan.cherednychok/Pictures/PhotoFrame/20220116_210743_resized.jpg"
    exif_data = get_exif_data(filename)
    display_basic_metadata(exif_data)
    display_gps_data(exif_data)

