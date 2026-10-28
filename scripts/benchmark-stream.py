#!/usr/bin/env python3
"""Read-only JPEG transport benchmark; never stores frames or controls device UI.

Run a separate host with --demo to provide changing synthetic frames. Examples:
  BOOX_SIDECAR_TOKEN=... python3 scripts/benchmark-stream.py --duration 10
  BOOX_SIDECAR_TOKEN=... python3 scripts/benchmark-stream.py \
      --url https://MAC_IP:8788 --pin CERT_SHA256 --duration 10
  BOOX_SIDECAR_TOKEN=... python3 scripts/benchmark-stream.py \
      --url https://MAC_IP:8788 --pin CERT_SHA256 --adb-serial SERIAL --requests 120

The default probe runs on this Mac. --adb-serial runs one native curl session on
an already connected Android device, reusing connections across requests. It
does not create USB reverse mappings, launch apps, or change device settings.
--allow-live explicitly permits reading the active desktop stream. Even then,
only counts/timing are printed; image bytes are discarded without disk writes.
Transport throughput excludes bitmap decoding, Canvas drawing and panel scanout.
"""
import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import shutil
import ssl
import statistics
import subprocess
import sys
import time
from urllib.parse import urlsplit

MAX_JPEG = 12 * 1024 * 1024
MAX_JSON = 64 * 1024


def validate_url(value):
    uri = urlsplit(value)
    if (uri.scheme not in ('http', 'https') or not uri.hostname or uri.username
            or uri.password or uri.query or uri.fragment or uri.path not in ('', '/')):
        raise ValueError('Use an HTTP(S) host endpoint without a path, credentials or query.')
    if uri.scheme == 'http' and uri.hostname not in ('127.0.0.1', 'localhost'):
        raise ValueError('Plain HTTP is restricted to USB/localhost. Use pinned HTTPS for LAN.')
    if uri.port is None:
        raise ValueError('Specify the host port (normally USB 8787 or Wi-Fi 8788).')
    return uri


def normalize_pin(value):
    result = re.sub(r'[:\s]', '', value or '').lower()
    if not re.fullmatch(r'[0-9a-f]{64}', result):
        raise ValueError('HTTPS requires the exact 64-hex certificate SHA-256 --pin.')
    return result


def peer_matches(connection, pin):
    der = connection.sock.getpeercert(binary_form=True)
    if not hmac.compare_digest(hashlib.sha256(der).hexdigest(), pin):
        connection.close()
        raise ValueError('Certificate pin mismatch; no authenticated request was sent.')
    return der


def prepare_tls(uri, pin):
    # First handshake has no credentials or HTTP request. Authenticate the leaf
    # by its provisioned fingerprint, then use it as a temporary in-memory CA.
    probe = http.client.HTTPSConnection(uri.hostname, uri.port,
                                       context=ssl._create_unverified_context(), timeout=4)
    try:
        probe.connect()
        der = peer_matches(probe, pin)
    finally:
        probe.close()
    context = ssl.create_default_context(cadata=ssl.DER_cert_to_PEM_cert(der))
    context.check_hostname = False  # Exact provisioned leaf pin is the identity.
    check = http.client.HTTPSConnection(uri.hostname, uri.port, context=context, timeout=4)
    try:
        check.connect()  # Checks certificate dates and signature before any token.
        peer_matches(check, pin)
    finally:
        check.close()
    return context, der


class Client:
    def __init__(self, uri, token, pin, context):
        self.uri, self.token, self.pin, self.context = uri, token, pin, context
        self.connection = None

    def close(self):
        if self.connection:
            self.connection.close()
        self.connection = None

    def get(self, path, capture=False):
        if self.connection is None:
            cls = http.client.HTTPSConnection if self.context else http.client.HTTPConnection
            kwargs = {'context': self.context} if self.context else {}
            self.connection = cls(self.uri.hostname, self.uri.port, timeout=4, **kwargs)
        if self.connection.sock is None:
            self.connection.connect()
            if self.context:
                peer_matches(self.connection, self.pin)
        started = time.perf_counter()
        self.connection.request('GET', path, headers={
            'Authorization': 'Bearer ' + self.token, 'Connection': 'keep-alive'})
        response = self.connection.getresponse()
        headers = {key.lower(): value for key, value in response.getheaders()}
        count, parts = 0, []
        limit = MAX_JSON if capture else MAX_JPEG
        while True:
            block = response.read(min(65536, limit + 1 - count))
            if not block:
                break
            count += len(block)
            if count > limit:
                self.close()
                raise ValueError('Response exceeds the benchmark size limit.')
            if capture:
                parts.append(block)
        elapsed = time.perf_counter() - started
        if response.status != 200:
            raise ValueError('Host returned HTTP ' + str(response.status))
        if not capture and headers.get('content-type', '').lower() != 'image/jpeg':
            raise ValueError('Expected a JPEG response.')
        return headers, count, elapsed, b''.join(parts)


def curl_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'


def spki_pin(der):
    # Only the public certificate enters these subprocesses. No files created.
    pem = subprocess.run(['openssl', 'x509', '-inform', 'DER', '-pubkey', '-noout'],
                         input=der, capture_output=True, check=True).stdout
    spki = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'],
                          input=pem, capture_output=True, check=True).stdout
    return 'sha256//' + base64.b64encode(hashlib.sha256(spki).digest()).decode()


def adb_probe(args, token, der):
    adb = shutil.which('adb')
    if not adb:
        raise ValueError('adb is not on PATH.')
    lines = ['silent', 'show-error', 'connect-timeout = 3', 'max-time = 4',
             'header = ' + curl_quote('Authorization: Bearer ' + token)]
    if der:
        # curl cannot consume an inline custom CA without a remote file. Pin the
        # derived public key instead; the exact leaf/dates were verified above.
        # --insecure accepts the self-signed chain, NEVER disables this key pin.
        lines += ['insecure', 'pinnedpubkey = ' + curl_quote(spki_pin(der))]
    base = '\n'.join(lines) + '\n'
    command = [adb, '-s', args.adb_serial, 'exec-out', '/system/bin/curl', '--config', '-']
    endpoint = args.url.rstrip('/')
    config = base + 'url = ' + curl_quote(endpoint + '/api/status') + '\n'
    result = subprocess.run(command, input=config, text=True, capture_output=True, timeout=15)
    if result.returncode:
        raise ValueError('Tablet status request failed: ' + result.stderr.strip())
    status = json.loads(result.stdout)
    check_status(status, args.allow_live)
    config = base + 'dump-header = "-"\nwrite-out = "BOOX_METRIC %{http_code} %{size_download} %{time_total}\\n"\n'
    for _ in range(args.requests):
        config += 'url = ' + curl_quote(endpoint + '/api/frame?after=-1') + '\noutput = "/dev/null"\n'
    started = time.perf_counter()
    result = subprocess.run(command, input=config, text=True, capture_output=True,
                            timeout=min(300, max(30, args.requests * 4.5)))
    elapsed = time.perf_counter() - started
    if result.returncode:
        raise ValueError('Tablet transfer failed: ' + result.stderr.strip())
    samples, frame_id = [], None
    for line in result.stdout.splitlines():
        if line.lower().startswith('x-frame-id:'):
            frame_id = int(line.split(':', 1)[1].strip())
        elif line.startswith('BOOX_METRIC '):
            _, code, size, seconds = line.split()
            if code != '200' or frame_id is None:
                raise ValueError('Tablet received an invalid frame response: HTTP ' + code)
            samples.append((frame_id, int(size), float(seconds)))
            frame_id = None
    if len(samples) != args.requests:
        raise ValueError('Tablet curl did not produce the expected number of measurements.')
    return status, samples, elapsed


def check_status(status, allow_live):
    if status.get('protocol') != 1:
        raise ValueError('Unsupported host protocol.')
    if not status.get('demo') and not allow_live:
        raise ValueError('Use a synthetic --demo host, or explicitly permit live reads with --allow-live.')
    if not status.get('permission') or not status.get('capturing'):
        raise ValueError('Host is not capturing. Start the synthetic host or current capture manually.')


def summarize(status, samples, elapsed, source):
    ids = [item[0] for item in samples]
    times = sorted(item[2] * 1000 for item in samples)
    unique = len(set(ids))
    return {
        'source': source, 'demo': bool(status.get('demo')),
        'frame_size': [status.get('width'), status.get('height')],
        'requested_host_fps': status.get('fps'), 'grayscale': status.get('grayscale'),
        'elapsed_seconds': round(elapsed, 3), 'requests': len(samples), 'unique_frames': unique,
        'unique_frames_per_second': round(unique / elapsed, 2),
        'duplicate_frames': len(samples) - unique,
        'megabits_per_second': round(sum(item[1] for item in samples) * 8 / elapsed / 1_000_000, 2),
        'mean_jpeg_bytes': round(statistics.mean(item[1] for item in samples)),
        'request_ms_median': round(statistics.median(times), 2),
        'request_ms_p95': round(times[min(len(times) - 1, int(len(times) * .95))], 2),
        'host_frame_id_span': max(ids) - min(ids),
        'scope': 'JPEG transport only; excludes decode, Canvas and physical panel refresh',
        'note': 'Repeated latest-frame requests expose duplicate traffic; idle screens are not motion benchmarks.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--url', default='http://127.0.0.1:8787')
    parser.add_argument('--pin', help='Exact Mac certificate SHA-256 fingerprint for HTTPS')
    parser.add_argument('--token-env', default='BOOX_SIDECAR_TOKEN', help='Environment variable holding the token; never printed')
    parser.add_argument('--duration', type=float, default=10, help='Mac probe duration in seconds (1–120)')
    parser.add_argument('--adb-serial', help='Probe from an existing authorized device with native curl; no device changes')
    parser.add_argument('--requests', type=int, default=120, help='Tablet probe sequential requests (1–1000); --duration applies only to Mac')
    parser.add_argument('--allow-live', action='store_true', help='Permit reading active desktop frames; image bytes are never persisted')
    args = parser.parse_args()
    if not 1 <= args.duration <= 120 or not 1 <= args.requests <= 1000:
        parser.error('Duration must be 1–120 seconds; requests must be 1–1000.')
    token = os.environ.get(args.token_env, '')
    if not re.fullmatch(r'[0-9a-fA-F]{64}', token):
        parser.error('Set ' + args.token_env + ' to the current 64-hex host token.')
    uri = validate_url(args.url)
    pin = normalize_pin(args.pin) if uri.scheme == 'https' else None
    context, der = prepare_tls(uri, pin) if pin else (None, None)
    if args.adb_serial:
        status, samples, elapsed = adb_probe(args, token, der)
        source = 'Android native curl; persistent transfer session; no bitmap decode'
    else:
        client = Client(uri, token, pin, context)
        try:
            status = json.loads(client.get('/api/status', capture=True)[3])
            check_status(status, args.allow_live)
            samples, started = [], time.perf_counter()
            while time.perf_counter() - started < args.duration:
                headers, size, seconds, _ = client.get('/api/frame?after=-1')
                samples.append((int(headers['x-frame-id']), size, seconds))
            elapsed = time.perf_counter() - started
        finally:
            client.close()
        source = 'Mac Python persistent HTTP client; not tablet throughput'
    print(json.dumps(summarize(status, samples, elapsed, source), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print('Benchmark failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
