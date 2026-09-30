#!/usr/bin/env python3
"""Local WebDAV front for E2E runs against the user's real NAS.

    nas_relay_proxy.py serve  --port 18991 --run e2e-20260930-170000 [--log F]
    nas_relay_proxy.py mirror --run e2e-... --dest DIR
    nas_relay_proxy.py remove --run e2e-...

The simulator adds an anonymous `http://127.0.0.1:<port>/` connection, exactly
as with the local WsgiDAV, so no NAS host or credential ever reaches the
simulator, the UI test or xcodebuild logs. Every request is forwarded (with its
concurrency preserved) to `<upstream>/<run>/`, where upstream is the writable
NAS folder. The proxy only changes what a different hostname requires:

* request path and `Destination` are re-rooted under the run folder,
* `Authorization: Basic` is injected,
* `href`s in 207 bodies and `Location` headers are mapped back.

Status codes, headers and bodies are otherwise passed through untouched, so
the relay's spurious 401s still reach the app's own retry logic.

Configuration comes from the environment (source the gitignored
nas_webdav.local.env): WEBDAV_RELAY_URL (or WEBDAV_URL), WEBDAV_USER,
WEBDAV_PASSWORD. The log never contains the upstream host or credentials.
"""
import argparse
import base64
import http.client
import os
import re
import signal
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

HOP_BY_HOP = {
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'authorization',
    'content-length',
}
HREF = re.compile(rb'(<(?:[A-Za-z0-9_-]+:)?href(?:\s[^>]*)?>)([^<]*)(</(?:[A-Za-z0-9_-]+:)?href>)')
RUN_NAME = re.compile(r'^[A-Za-z0-9._-]{1,80}$')


class Upstream:
    def __init__(self, run):
        url = os.environ.get('WEBDAV_RELAY_URL') or os.environ.get('WEBDAV_URL')
        user, password = os.environ.get('WEBDAV_USER'), os.environ.get('WEBDAV_PASSWORD')
        if not url or user is None or password is None:
            sys.exit('Source tool/local_webdav/nas_webdav.local.env first')
        if not RUN_NAME.match(run):
            sys.exit(f'Bad run folder name: {run!r}')
        parts = urlsplit(url)
        self.scheme, self.netloc = parts.scheme, parts.netloc
        # Raw (percent-encoded) base path of the run folder, with trailing '/'.
        self.base = parts.path.rstrip('/') + '/' + quote(run) + '/'
        self.parent = parts.path.rstrip('/') + '/'
        self.auth = 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()
        self._local = threading.local()

    def connection(self, fresh=False):
        conn = getattr(self._local, 'conn', None)
        if conn is None or fresh:
            if conn is not None:
                conn.close()
            cls = http.client.HTTPSConnection if self.scheme == 'https' else http.client.HTTPConnection
            kwargs = {'context': ssl.create_default_context()} if self.scheme == 'https' else {}
            conn = cls(self.netloc, timeout=300, **kwargs)
            self._local.conn = conn
        return conn

    def request(self, method, raw_path, headers=None, body=None):
        """One upstream request on a pooled connection; retries a stale socket once."""
        headers = dict(headers or {})
        headers['Authorization'] = self.auth
        headers['Host'] = self.netloc
        for attempt in (0, 1):
            conn = self.connection(fresh=attempt == 1)
            try:
                conn.request(method, raw_path, body=body, headers=headers)
                return conn.getresponse()
            except (http.client.RemoteDisconnected, BrokenPipeError, ConnectionResetError):
                # Only a request whose body is not a consumed stream can be resent.
                if attempt == 1 or (body is not None and not isinstance(body, (bytes, bytearray))):
                    raise

    def to_upstream(self, client_raw_path):
        path = client_raw_path.split('?', 1)[0]
        return self.base + path.lstrip('/')

    def to_client(self, upstream_ref):
        """Maps an upstream href/URL back under '/', or None when out of scope."""
        path = urlsplit(upstream_ref).path if '://' in upstream_ref else upstream_ref
        decoded, base = unquote(path), unquote(self.base)
        if decoded + '/' == base:
            decoded = base
        if not decoded.startswith(base):
            return None
        return quote('/' + decoded[len(base):], safe="/-._~!$&'()*+,;=:@")

    def ensure_run_folder(self):
        response = self.request('MKCOL', self.base)
        response.read()
        if response.status not in (201, 405):
            sys.exit(f'MKCOL run folder failed: HTTP {response.status}')


class Stats:
    def __init__(self, log_path):
        self.lock = threading.Lock()
        self.log = open(log_path, 'a', buffering=1) if log_path else sys.stderr
        self.counts = {}
        self.in_flight = 0
        self.max_in_flight = 0

    def begin(self):
        with self.lock:
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
            return self.in_flight

    def end(self, method, path, status, ms, concurrent):
        with self.lock:
            self.in_flight -= 1
            key = f'{method} {status}'
            self.counts[key] = self.counts.get(key, 0) + 1
            self.log.write(f'{time.strftime("%H:%M:%S")} {method} {status} {ms}ms c={concurrent} {path}\n')

    def summary(self):
        with self.lock:
            return dict(self.counts), self.max_in_flight


def make_handler(upstream, stats):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def _body(self):
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                data = bytearray()
                while True:
                    size = int(self.rfile.readline().split(b';')[0].strip(), 16)
                    if size == 0:
                        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                            pass
                        return bytes(data)
                    data += self.rfile.read(size)
                    self.rfile.readline()
            length = int(self.headers.get('Content-Length') or 0)
            if length == 0:
                return None
            if length <= 1 << 20:
                return self.rfile.read(length)
            return _LimitedReader(self.rfile, length)

        def _forward(self):
            started = time.monotonic()
            concurrent = stats.begin()
            method = self.command
            status = 502
            try:
                # Header names are case-insensitive (Dio sends them lowercase):
                # drop the client's Destination so only the remapped one is sent.
                headers = {k: v for k, v in self.headers.items()
                           if k.lower() not in HOP_BY_HOP and k.lower() != 'destination'}
                body = self._body()
                if isinstance(body, _LimitedReader):
                    headers['Content-Length'] = str(body.remaining)
                elif body is not None:
                    headers['Content-Length'] = str(len(body))
                elif method in ('PUT', 'POST'):
                    headers['Content-Length'] = '0'
                destination = self.headers.get('Destination')
                if destination:
                    headers['Destination'] = upstream.to_upstream(urlsplit(destination).path)
                response = upstream.request(method, upstream.to_upstream(self.path), headers, body)
                status = response.status
                self._relay(response)
            except Exception as error:  # upstream unreachable etc.
                message = f'relay error: {type(error).__name__}'.encode()
                status = f'502({type(error).__name__})'
                try:
                    self.send_response(502)
                    self.send_header('Content-Length', str(len(message)))
                    self.end_headers()
                    self.wfile.write(message)
                except OSError:
                    pass
                self.close_connection = True
            finally:
                stats.end(method, self.path.split('?', 1)[0], status,
                          int((time.monotonic() - started) * 1000), concurrent)

        def _relay(self, response):
            content_type = response.getheader('Content-Type', '')
            rewrite = response.status == 207 or 'xml' in content_type
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP or lower in ('server', 'date'):
                    continue  # send_response already wrote Server and Date
                if lower in ('location', 'content-location'):
                    mapped = upstream.to_client(value)
                    if mapped is None:
                        continue
                    value = mapped
                self.send_header(key, value)
            if self.command == 'HEAD':
                response.read()
                self.send_header('Content-Length', response.getheader('Content-Length') or '0')
                self.end_headers()
                return
            if response.status in (204, 304) or response.status < 200:
                # No message body allowed: a chunked terminator here would be
                # read by the client as the start of the next response.
                response.read()
                self.end_headers()
                return
            if rewrite:
                data = HREF.sub(self._map_href, response.read())
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            length = response.getheader('Content-Length')
            if length is not None:
                self.send_header('Content-Length', length)
                self.end_headers()
                while chunk := response.read(64 * 1024):
                    self.wfile.write(chunk)
                return
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            while chunk := response.read(64 * 1024):
                self.wfile.write(b'%x\r\n%s\r\n' % (len(chunk), chunk))
            self.wfile.write(b'0\r\n\r\n')

        @staticmethod
        def _map_href(match):
            href = match.group(2).decode('utf-8', 'replace').strip()
            mapped = upstream.to_client(unescape_xml(href))
            if mapped is None:
                return match.group(0)
            return match.group(1) + escape_xml(mapped).encode() + match.group(3)

        do_GET = do_HEAD = do_PUT = do_DELETE = do_OPTIONS = _forward
        do_PROPFIND = do_PROPPATCH = do_MKCOL = do_MOVE = do_COPY = _forward
        do_LOCK = do_UNLOCK = do_POST = _forward

    return Handler


class _LimitedReader:
    """Streams a request body of known length to http.client."""

    def __init__(self, stream, length):
        self.stream, self.remaining = stream, length
        self._left = length

    def read(self, size=-1):
        if self._left <= 0:
            return b''
        size = self._left if size < 0 else min(size, self._left)
        data = self.stream.read(size)
        self._left -= len(data)
        return data


def unescape_xml(text):
    return (text.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"')
            .replace('&apos;', "'").replace('&amp;', '&'))


def escape_xml(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def list_folder(upstream, raw_path):
    body = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            b'<d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>')
    for attempt in range(5):
        response = upstream.request('PROPFIND', raw_path,
                                    {'Depth': '1', 'Content-Type': 'application/xml'}, body)
        data = response.read()
        if response.status == 207:
            break
        if response.status != 401 or attempt == 4:
            raise RuntimeError(f'PROPFIND HTTP {response.status}')
        time.sleep(0.5 * (attempt + 1))
    entries = []
    for block in re.findall(rb'<(?:[A-Za-z0-9_-]+:)?response[\s>].*?</(?:[A-Za-z0-9_-]+:)?response>', data, re.S):
        href = HREF.search(block)
        if not href:
            continue
        ref = unescape_xml(href.group(2).decode().strip())
        is_dir = re.search(rb'<(?:[A-Za-z0-9_-]+:)?collection(?:\s[^>]*)?/?>', block) is not None
        entries.append((ref, is_dir))
    return entries


def mirror(upstream, dest):
    """Downloads the whole run folder, sequentially (no relay race)."""
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    files = total = 0
    pending = ['/']
    while pending:
        folder = pending.pop()
        for ref, is_dir in list_folder(upstream, upstream.to_upstream(folder)):
            client = upstream.to_client(ref)
            if client is None:
                raise RuntimeError('listing escaped the run folder')
            if client.rstrip('/') == folder.rstrip('/'):
                continue
            if is_dir:
                pending.append(client if client.endswith('/') else client + '/')
                continue
            relative = unquote(client).lstrip('/')
            if '..' in Path(relative).parts:
                raise RuntimeError('unsafe name in listing')
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            for attempt in range(5):
                response = upstream.request('GET', upstream.to_upstream(client))
                data = response.read()
                if response.status == 200:
                    break
                if response.status != 401 or attempt == 4:
                    raise RuntimeError(f'GET HTTP {response.status}')
                time.sleep(0.5 * (attempt + 1))
            target.write_bytes(data)
            files += 1
            total += len(data)
    print(f'MIRROR files={files} bytes={total}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['serve', 'mirror', 'remove'])
    parser.add_argument('--run', required=True)
    parser.add_argument('--port', type=int, default=18991)
    parser.add_argument('--log')
    parser.add_argument('--dest')
    args = parser.parse_args()
    upstream = Upstream(args.run)
    if args.command == 'mirror':
        mirror(upstream, args.dest or sys.exit('--dest required'))
        return
    if args.command == 'remove':
        response = upstream.request('DELETE', upstream.base)
        response.read()
        print(f'REMOVE HTTP {response.status}')
        return
    upstream.ensure_run_folder()
    stats = Stats(args.log)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), make_handler(upstream, stats))
    server.daemon_threads = True
    def stop(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    print(f'RELAY listening on 127.0.0.1:{args.port} run={args.run}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        counts, peak = stats.summary()
        stats.log.write(f'SUMMARY peak_concurrency={peak} {sorted(counts.items())}\n')


if __name__ == '__main__':
    main()
