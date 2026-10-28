#!/usr/bin/env python3
"""Exercise the packaged native server with synthetic frames, never desktop capture."""
import http.client
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'dist/BOOX Sidecar.app/Contents/MacOS/BooxSidecar'

class HostSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError('Build the app first: ./scripts/build-mac.sh')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        cls.process = subprocess.Popen([str(BINARY), '--demo', '--port', str(cls.port)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True)
        cls.addClassCleanup(cls.shutdown)
        output = queue.Queue()
        def read_output():
            for line in cls.process.stdout:
                output.put(line)
        threading.Thread(target=read_output, daemon=True).start()
        deadline = time.monotonic() + 20
        cls.token = None
        while time.monotonic() < deadline:
            try:
                line = output.get(timeout=0.2)
                match = re.search(r'#token=([a-f0-9]{64})', line)
                if match:
                    cls.token = match.group(1)
                    break
            except queue.Empty:
                if cls.process.poll() is not None:
                    raise RuntimeError('Demo host exited before startup')
        if not cls.token:
            raise RuntimeError('Demo host did not report its session token')
        while time.monotonic() < deadline:
            try:
                connection = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=1)
                connection.request('GET', '/health')
                response = connection.getresponse()
                response.read()
                connection.close()
                if response.status == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError('Demo host did not start listening')

    @classmethod
    def shutdown(cls):
        if hasattr(cls, 'process'):
            cls.process.terminate()
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait()
            cls.process.stdout.close()

    def request(self, path, method='GET', body=None, auth=True, headers=None):
        merged = {'Authorization': 'Bearer ' + self.token} if auth else {}
        if body is not None:
            body = json.dumps(body)
            merged['Content-Type'] = 'application/json'
        merged.update(headers or {})
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=merged)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def test_public_assets_and_health(self):
        for path in ('/', '/index.html', '/app.js', '/style.css', '/health'):
            code, headers, data = self.request(path, auth=False)
            self.assertEqual(code, 200, path)
            self.assertTrue(data)
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertNotIn('Access-Control-Allow-Origin', headers)

    def test_authentication(self):
        for path in ('/api/status', '/api/displays', '/api/frame'):
            self.assertEqual(self.request(path, auth=False)[0], 401)
            self.assertEqual(self.request(path, headers={'Authorization': 'Bearer wrong'})[0], 401)
        code, _, body = self.request('/api/status')
        self.assertEqual(code, 200)
        status = json.loads(body)
        self.assertTrue(status['capturing'])
        self.assertFalse(status['inputEnabled'])
        self.assertIn('DEMO', status['message'])

    def test_latest_frame(self):
        code, headers, jpeg = self.request('/api/frame?after=-1')
        self.assertEqual(code, 200)
        self.assertEqual(headers['Content-Type'], 'image/jpeg')
        self.assertTrue(jpeg.startswith(b'\xff\xd8'))
        self.assertTrue(jpeg.endswith(b'\xff\xd9'))
        self.assertGreater(int(headers['X-Frame-ID']), 0)
        self.assertGreater(int(headers['X-Frame-Width']), 0)
        self.assertEqual(self.request('/api/frame?after=9223372036854775807')[0], 204)
        self.assertEqual(self.request('/api/frame?after=oops')[0], 400)

    def test_keep_alive_authentication_is_checked_per_request(self):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            for authenticated, expected in ((True, 200), (False, 401), (True, 200)):
                headers = {'Authorization': 'Bearer ' + self.token} if authenticated else {}
                connection.request('GET', '/api/status', headers=headers)
                response = connection.getresponse()
                response.read()
                self.assertEqual(response.status, expected)
                self.assertEqual(response.getheader('Connection'), 'keep-alive')
        finally:
            connection.close()

    def test_settings_validation_and_update(self):
        for body in ({'fps': 0}, {'fps': 61}, {'fps': True}, {'fps': 1.5},
                     {'maxWidth': 3000}, {'grayscale': 1}, {'unknown': 1},
                     {'jpegQuality': 0.39}, {'jpegQuality': 0.96}, {'jpegQuality': True}):
            self.assertEqual(self.request('/api/settings', 'POST', body)[0], 400, body)
        code, _, body = self.request('/api/settings', 'POST', {'fps': 3, 'maxWidth': 930, 'grayscale': False, 'jpegQuality': 0.6})
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['fps'], 3)
        self.assertFalse(json.loads(body)['grayscale'])
        self.assertEqual(json.loads(body)['jpegQuality'], 0.6)
        self.assertEqual(self.request('/api/settings', 'POST', {'fps': 60, 'maxWidth': 1240, 'grayscale': False})[0], 200)

    def test_remote_display_selection_is_rejected_atomically(self):
        code, _, body = self.request('/api/status')
        self.assertEqual(code, 200)
        before = json.loads(body)
        fields = ('displayID', 'capturing', 'fps', 'maxWidth', 'grayscale', 'jpegQuality')
        changed_fps = 3 if before['fps'] != 3 else 15
        for display in (before['displayID'], -1, None, '1'):
            code, _, _ = self.request('/api/settings', 'POST', {'displayID': display, 'fps': changed_fps})
            self.assertEqual(code, 403)
            code, _, body = self.request('/api/status')
            self.assertEqual(code, 200)
            after = json.loads(body)
            self.assertEqual({key: before[key] for key in fields}, {key: after[key] for key in fields})

    def test_input_requires_local_consent(self):
        self.assertEqual(self.request('/api/input', 'POST', {'type': 'tap', 'x': 0.5, 'y': 0.5})[0], 403)

    def test_origin_methods_and_paths(self):
        self.assertEqual(self.request('/api/settings', 'POST', {'fps': 3}, headers={'Origin': 'https://evil.example'})[0], 403)
        self.assertEqual(self.request('/api/settings', 'POST', {'fps': 3}, headers={'Sec-Fetch-Site': 'cross-site'})[0], 403)
        self.assertEqual(self.request('/health', headers={'Host': 'evil.example'})[0], 403)
        self.assertEqual(self.request('/api/settings')[0], 405)
        self.assertEqual(self.request('/api/status', 'POST', {})[0], 405)
        for path in ('/../README.md', '/%2e%2e/README.md', '/.git/config', '/api/unknown'):
            self.assertEqual(self.request(path)[0], 404, path)

    def test_http_parser_rejects_ambiguous_or_oversized_requests(self):
        prefix = f'POST /api/settings HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n'
        for extra in ('Content-Length: 999999\r\n',
                      'Content-Length: 0\r\nContent-Length: 0\r\n',
                      'Transfer-Encoding: chunked\r\n'):
            with socket.create_connection(('127.0.0.1', self.port), timeout=5) as sock:
                sock.sendall((prefix + extra + '\r\n').encode())
                reply = sock.recv(4096)
                self.assertRegex(reply, rb'^HTTP/1.1 (400|413) ')

if __name__ == '__main__':
    unittest.main(verbosity=2)
