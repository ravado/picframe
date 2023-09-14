import json
import urllib.request
import locale
import logging

URL = "https://nominatim.openstreetmap.org/reverse?format=geojson&lat={}&lon={}&zoom={}&email={}&accept-language={}"


class GeoReverse:
    def __init__(self, geo_key, locale_for_address=None, zoom=18, key_list=None):
        self.__logger = logging.getLogger("geo_reverse.GeoReverse")
        self.__geo_key = geo_key
        self.__zoom = zoom
        self.__key_list = key_list
        self.__geo_locations = {}
        
        if locale_for_address:
            self.__language = locale_for_address[:2]
        else:
            self.__language = locale.getlocale()[0][:2]

    def get_address(self, lat, lon):
        try:
            reverse_url_formatted = URL.format(lat, lon, self.__zoom, self.__geo_key, self.__language)
            self.__logger.info(f"== Getting address from coordinates with {reverse_url_formatted}")
            
            with urllib.request.urlopen(reverse_url_formatted,
                                        timeout=3.0) as req:
                data = json.loads(req.read().decode())
            
            self.__logger.info(f"== Response: {data}")
            adr = data['features'][0]['properties']['address']
            self.__logger.info(f"== Using the {adr}")
            # some experimentation might be needed to get a good set of alternatives in key_list
            adr_list = []
            if self.__key_list is not None:
                for part in self.__key_list:
                    for option in part:
                        if option in adr:
                            adr_list.append(adr[option])
                            break  # add just the first one from the options
            else:
                adr_list = adr.values()
            return ", ".join(adr_list)
        except Exception as e:  # TODO return different thing for different exceptions
            self.__logger.error("lat=%f, lon=%f -> %s", lat, lon, e)
            return ""
