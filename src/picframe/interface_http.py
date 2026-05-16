#!/usr/bin/env python
# -*- coding: utf-8 -*-
from typing import Optional
import time
import os
import logging
import json
import threading
import base64
import io
from collections import OrderedDict
from PIL import Image, ImageOps

try:
    from http.server import BaseHTTPRequestHandler, HTTPServer  # py3
    import urllib.parse as urlparse
except ImportError:
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer  # py2
    import urlparse

from jinja2 import Environment, FileSystemLoader, select_autoescape

try:
    from pi_heif import register_heif_opener
except ImportError:
    register_heif_opener = None

EXTENSIONS = [".jpg", ".jpeg", ".png"]
QUEUE_PREVIEW_LIMIT = 8
QUEUE_THUMB_SIZE = (112, 84)
THUMB_CACHE_SIZE = 24
THUMB_RESAMPLE = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
EXTENSION_TO_MIMETYPE = {
    # Videos
    '.mp4': 'video/mp4',
    '.mkv': 'video/x-matroska',
    '.flv': 'video/x-flv',
    '.mov': 'video/quicktime',
    '.avi': 'video/x-msvideo',
    '.webm': 'video/webm',
    '.hevc': 'video/mp4',  # HEVC usually wrapped in MP4 container

    # Images
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',

    # Static UI files
    '.html': 'text/html',
    '.js': 'application/javascript',
    '.css': 'text/css',
}
if register_heif_opener is not None:
    EXTENSIONS += [".heif", ".heic"]
    EXTENSION_TO_MIMETYPE.update({
        '.heif': 'image/heif',
        '.heic': 'image/heic'
    })


def heif_to_image(fname: str) -> Optional[Image.Image]:
    """
    Converts a HEIF image file to a PIL Image object.

    This function attempts to use the `pi_heif` library to register a HEIF opener
    for handling HEIF image files. If the library is not installed, it logs a warning
    and skips the conversion.

    Args:
        fname (str): The file path to the HEIF image.

    Returns:
        PIL.Image.Image: The converted image as a PIL Image object. If the conversion
        fails, the function logs a warning and returns None.

    Notes:
        - The function ensures the image is in "RGB" mode. If the image is not in
          "RGB" or "RGBA" mode, it will be converted to "RGB".
        - Ensure the `pi_heif` library is installed to enable HEIF image handling.
    """
    try:
        try:
            from pi_heif import register_heif_opener
            register_heif_opener()
        except ImportError:
            register_heif_opener = None

        image = Image.open(fname)
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGB")
        return image
    except (OSError, IOError) as e:
        logger = logging.getLogger("interface_http.heif_to_jpg")
        logger.warning("Failed attempt to convert %s due to %s \n** Have you installed pi_heif? **", fname, e)
        return None

CONTROL_GROUPS = [
    {"key": "nav", "label": "Navigation", "danger": False, "controls": [
        {"id": "back",   "type": "action", "fn": "back={}",  "val": False},
        {"id": "next",   "type": "action", "fn": "next={}",  "val": False},
        {"id": "paused", "type": "bool",   "fn": "setter",   "val": False},
    ]},
    {"key": "display", "label": "Display", "danger": False, "controls": [
        {"id": "display_is_on", "type": "bool",   "fn": "setter", "val": False},
        {"id": "shuffle",       "type": "bool",   "fn": "setter", "val": False},
        {"id": "brightness",    "type": "number", "fn": "setter", "val": 0},
        {"id": "fade_time",     "type": "number", "fn": "setter", "val": 0},
        {"id": "time_delay",    "type": "number", "fn": "setter", "val": 0},
    ]},
    {"key": "text", "label": "Text Overlays", "danger": False, "controls": [
        {"id": "text_name",         "type": "bool",   "fn": 'set_show_text={"txt_key":"name","val":$val}',     "val": False},
        {"id": "text_date",         "type": "bool",   "fn": 'set_show_text={"txt_key":"date","val":$val}',     "val": False},
        {"id": "text_folder",       "type": "bool",   "fn": 'set_show_text={"txt_key":"folder","val":$val}',   "val": False},
        {"id": "text_location",     "type": "bool",   "fn": 'set_show_text={"txt_key":"location","val":$val}', "val": False},
        {"id": "clear_text",        "type": "action", "fn": "set_show_text={}",                                 "val": False},
        {"id": "refresh_show_text", "type": "action", "fn": "refresh_show_text={}",                             "val": False},
    ]},
    {"key": "filter", "label": "Filters", "danger": False, "controls": [
        {"id": "date_from",       "type": "date", "fn": "setter", "val": 0},
        {"id": "date_to",         "type": "date", "fn": "setter", "val": 0},
        {"id": "subdirectory",    "type": "text", "fn": "setter", "val": ""},
        {"id": "location_filter", "type": "text", "fn": "setter", "val": ""},
        {"id": "tags_filter",     "type": "text", "fn": "setter", "val": ""},
    ]},
    {"key": "actions", "label": "Actions", "danger": True, "controls": [
        {"id": "delete",      "type": "action", "fn": "delete={}",      "val": False},
        {"id": "purge_files", "type": "action", "fn": "purge_files={}", "val": False},
        {"id": "stop",        "type": "action", "fn": "stop={}",        "val": False},
    ]},
]


class RequestHandler(BaseHTTPRequestHandler):

    def do_AUTHHEAD(self):
        if self.server._auth is not None:
            if self.headers.get("Authorization") == None:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Restricted"')
                self.send_header("Content-type", "text/html")
                self.end_headers()
                response_message = "Error: No authorization header received. Please provide valid credentials.\n"
                self.wfile.write(response_message.encode('utf-8'))
                self.connection.close()
                return False
            elif self.headers.get("Authorization") != "Basic " + self.server._auth:
                self.send_response(403)
                self.send_header("Content-type", "text/html")
                self.end_headers()
                response_message = "Error: Invalid authentication credentials. Access denied.\n"
                self.wfile.write(response_message.encode('utf-8'))
                self.connection.close()
                return False
        return True

    def do_GET(self):  # noqa: C901
        if not self.do_AUTHHEAD():
            source_ip = self.client_address[0]
            log_message = f"Authentication failed for source IP: {source_ip}"
            self.server._logger.warning(log_message)
            return
        try:
            parsed_url = urlparse.urlsplit(self.path)
            request_path = parsed_url.path
            params = dict(urlparse.parse_qsl(parsed_url.query, True))
            page_ok = False
            if request_path != "/":  # serve static page from html_path...
                html_page = request_path.strip("/")
            else:
                html_page = "index.html"
            _, extension = os.path.splitext(html_page)
            serve_static = (
                not parsed_url.query
                or html_page in ("current_image", "current_image_original")
                or extension in [".html", ".js", ".css"]
            )
            if serve_static:
                if request_path != "/":  # serve static page from html_path...
                    html_page = request_path.strip("/")
                else:
                    html_page = "index.html"
                _, extension = os.path.splitext(html_page)
                if extension not in [".html", ".js", ".css"]:
                    page = self.server._controller.get_current_path()
                    extension = os.path.splitext(page)[1].lower()
                    content_type = EXTENSION_TO_MIMETYPE.get(extension, 'application/octet-stream')
                    if html_page != "current_image_original":
                        from picframe.video_streamer import VIDEO_EXTENSIONS
                        if extension in ('.heic', '.heif'):
                            # as current_image may be heic
                            image = heif_to_image(page)
                            if image is not None:
                                buf = io.BytesIO()
                                image.save(buf, format="JPEG")
                                buf.seek(0)
                                page_bytes = buf.read()
                            else:
                                page_bytes = b""
                            content_type = EXTENSION_TO_MIMETYPE['.jpg']
                            is_bytes = True
                        elif extension in VIDEO_EXTENSIONS:
                            # as current_image may be video
                            file = os.path.splitext(page)[0]
                            page = file + ".1.frame"
                            content_type = EXTENSION_TO_MIMETYPE['.jpg']
                            is_bytes = False
                        else:
                            is_bytes = False
                    else:
                        is_bytes = False
                else:
                    page = os.path.join(self.server._html_path, html_page)
                    content_type = EXTENSION_TO_MIMETYPE.get(extension, "text/html")
                    is_bytes = False
                page = urlparse.unquote(page)
                if html_page == "index.html":
                    rendered = self.server._render_index()
                    self.send_response(200)
                    self.send_header('Content-type', 'text/html')
                    self.send_header('Content-Length', str(len(rendered)))
                    self.end_headers()
                    self.wfile.write(rendered)
                    self.connection.close()
                    page_ok = True
                elif (not is_bytes and os.path.isfile(page)) or is_bytes:
                    self.send_response(200)
                    self.send_header('Content-type', content_type)
                    file_size = os.path.getsize(page)
                    self.send_header('Content-Length', str(file_size))
                    filename = os.path.basename(page)
                    if is_bytes:
                        filename += ".jpg"
                    filename_encoded = urlparse.quote(filename)
                    self.send_header('Content-Disposition', f'inline; filename="{filename}"; filename*=utf-8\'\'{filename_encoded}')
                    # TODO check if html or js - in which case application/javascript
                    # really should filter out attempts to render all other file types (jpg etc?)
                    self.end_headers()
                    if is_bytes:
                        self.wfile.write(page_bytes)
                    else:
                        # Stream the file in chunks
                        with open(page, "rb") as f:
                            while True:
                                chunk = f.read(64 * 1024)  # 64 KB chunks
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                    self.connection.close()
                    page_ok = True
            else:  # server type request - get or set info
                start_time = time.time()
                if "queue_snapshot" in params:
                    self.server._send_json(self, self.server._controller.get_queue_snapshot(limit=QUEUE_PREVIEW_LIMIT))
                    self.connection.close()
                    return
                if "queue_jump" in params:
                    result = self.server._controller.jump_to_queue_index(params.get("queue_jump"))
                    self.server._send_json(self, result)
                    self.connection.close()
                    return
                if "queue_thumb" in params:
                    thumb_bytes = self.server._get_queue_thumb_bytes(params.get("queue_thumb"))
                    self.send_response(200)
                    self.send_header('Content-type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(thumb_bytes)))
                    self.end_headers()
                    self.wfile.write(thumb_bytes)
                    self.connection.close()
                    return

                message = {}
                self.send_response(200)
                self.server._logger.debug('http request from: ' + self.client_address[0])

                for key, value in params.items():
                    self.send_header('Content-type', 'text')
                    self.end_headers()
                    if key == "all":
                        for subkey in self.server._setters:
                            message[subkey] = getattr(self.server._controller, subkey)
                    elif key in dir(self.server._controller):
                        if value != "" or key in ("subdirectory", "location_filter", "tags_filter"):  # parse_qsl can return empty string for value when just querying
                            lwr_val = value.lower()
                            if lwr_val in ("true", "on", "yes"):  # this only works for simple values *not* json style kwargs # noqa: E501
                                value = True
                            elif lwr_val in ("false", "off", "no"):
                                value = False
                            try:
                                if key in self.server._setters:
                                    setattr(self.server._controller, key, value)
                                else:
                                    value = value.replace("\'", "\"")  # only " permitted in json
                                    # value must be json kwargs
                                    getattr(self.server._controller, key)(**json.loads(value))
                            except Exception as e:
                                message['ERROR'] = 'Excepton:{}>{};'.format(key, e)
                        if key in self.server._setters:  # can get info back from controller TODO
                            message[key] = getattr(self.server._controller, key)

                    self.wfile.write(bytes(json.dumps(message), "utf8"))
                    self.connection.close()
                    page_ok = True

                self.server._logger.info(message)
                self.server._logger.debug("request finished in:  %s seconds" % (time.time() - start_time))
            if not page_ok:
                self.send_response(404)
                self.connection.close()
        except Exception as e:
            self.server._logger.warning(e)
            self.send_response(400)
            self.connection.close()

        return

    def log_request(self, code):
        pass

    def do_POST(self):
        self.do_GET()

    def end_headers(self):
        try:
            super().end_headers()
        except BrokenPipeError as e:
            self.connection.close()
            self.server._logger.error('httpserver error: {}'.format(e))


class InterfaceHttp(HTTPServer):
    def __init__(
            self,
            controller,
            html_path,
            pic_dir,
            no_files_img,
            port=9000,
            auth=False,
            username=None,
            password=None,
        ):
        super(InterfaceHttp, self).__init__(("0.0.0.0", port), RequestHandler)
        # NB name mangling throws a spanner in the works here!!!!!
        # *no* __dunders
        self._logger = logging.getLogger("simple_server.InterfaceHttp")
        self._logger.info("creating an instance of InterfaceHttp")
        self._controller = controller
        self._pic_dir = os.path.expanduser(pic_dir)
        self._no_files_img = os.path.expanduser(no_files_img)
        self._html_path = os.path.expanduser(html_path)
        self._auth = None
        if auth:
            self._auth = base64.b64encode(f"{username}:{password}".encode()).decode()
        # TODO check below works with all decorated methods.. seems to work
        controller_class = controller.__class__
        self._setters = [method for method in dir(controller_class)
                         if 'setter' in dir(getattr(controller_class, method))]
        self._jinja_env = Environment(
            loader=FileSystemLoader(self._html_path),
            autoescape=select_autoescape(("html", "xml")),
        )
        self._thumb_cache = OrderedDict()
        self._thumb_cache_lock = threading.Lock()
        self._thumb_placeholder = self._build_placeholder_thumb()
        t = threading.Thread(target=self.serve_forever)
        t.start()

    def _render_index(self):
        state = {key: getattr(self._controller, key) for key in self._setters}
        groups = []
        ids_js = {}
        for group in CONTROL_GROUPS:
            controls = []
            for ctrl in group["controls"]:
                c = dict(ctrl)
                c["val"] = state.get(ctrl["id"], ctrl["val"])
                controls.append(c)
                ids_js[ctrl["id"]] = {"type": ctrl["type"], "fn": ctrl["fn"], "val": c["val"]}
            groups.append({**group, "controls": controls})
        return self._jinja_env.get_template("index.html").render(
            groups=groups,
            ids=ids_js,
        ).encode("utf-8")

    def _send_json(self, handler, payload):
        body = json.dumps(payload).encode("utf-8")
        handler.send_response(200)
        handler.send_header('Content-type', 'application/json')
        handler.send_header('Content-Length', str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    def _build_placeholder_thumb(self):
        image = Image.new("RGB", QUEUE_THUMB_SIZE, color=(28, 28, 30))
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=60)
        return buf.getvalue()

    def _read_thumb_cache(self, cache_key):
        with self._thumb_cache_lock:
            cached = self._thumb_cache.get(cache_key)
            if cached is None:
                return None
            self._thumb_cache.move_to_end(cache_key)
            return cached

    def _write_thumb_cache(self, cache_key, thumb_bytes):
        with self._thumb_cache_lock:
            self._thumb_cache[cache_key] = thumb_bytes
            self._thumb_cache.move_to_end(cache_key)
            while len(self._thumb_cache) > THUMB_CACHE_SIZE:
                self._thumb_cache.popitem(last=False)

    def _get_queue_thumb_bytes(self, index):
        source_path = self._controller.get_queue_thumb_source(index)
        if not source_path:
            return self._thumb_placeholder

        source_path = urlparse.unquote(source_path)
        extension = os.path.splitext(source_path)[1].lower()
        if extension in ('.heic', '.heif'):
            try:
                source_mtime = os.path.getmtime(source_path)
            except OSError:
                return self._thumb_placeholder
        elif extension in EXTENSION_TO_MIMETYPE or extension in ('.png',):
            try:
                source_mtime = os.path.getmtime(source_path)
            except OSError:
                return self._thumb_placeholder
        else:
            try:
                from picframe.video_streamer import VIDEO_EXTENSIONS
                if extension in VIDEO_EXTENSIONS:
                    frame_path = os.path.splitext(source_path)[0] + ".1.frame"
                    source_mtime = os.path.getmtime(frame_path)
                    source_path = frame_path
                else:
                    return self._thumb_placeholder
            except OSError:
                return self._thumb_placeholder

        cache_key = (source_path, source_mtime, QUEUE_THUMB_SIZE)
        cached = self._read_thumb_cache(cache_key)
        if cached is not None:
            return cached

        try:
            if extension in ('.heic', '.heif'):
                image = heif_to_image(source_path)
            else:
                image = Image.open(source_path)
            if image is None:
                return self._thumb_placeholder

            image = ImageOps.exif_transpose(image)
            if image.mode not in ("RGB", "RGBA"):
                image = image.convert("RGB")
            elif image.mode == "RGBA":
                background = Image.new("RGB", image.size, (28, 28, 30))
                background.paste(image, mask=image.split()[-1])
                image = background
            image.thumbnail(QUEUE_THUMB_SIZE, THUMB_RESAMPLE)
            buf = io.BytesIO()
            image.save(buf, format="JPEG", quality=72, optimize=True)
            thumb_bytes = buf.getvalue()
        except Exception:
            self._logger.warning("Failed to generate queue thumbnail for %s", source_path, exc_info=True)
            return self._thumb_placeholder

        self._write_thumb_cache(cache_key, thumb_bytes)
        return thumb_bytes

    def stop(self):
        t = threading.Thread(target=self.shutdown, daemon=True)
        t.start()
