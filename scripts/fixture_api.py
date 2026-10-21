"""Local test implementation of the recovered wire protocol, with its own RSA key."""
import base64
import hashlib
import hmac
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

SIGN = b'HtxDnCtl7ePUvZU9SE0tfDSjR'
KEY, IV = b'Dn7kQp2mXw9sL4aR', b'u8hE3nBqK1zT6cYf'
ROOT = Path(__file__).resolve().parent.parent / 'tests/Fixtures'
PRIVATE_KEY = serialization.load_pem_private_key((ROOT / 'api-test-private.pem').read_bytes(), password=None)
SESSIONS, RETRIED, PLAYBACK_CALLS = {}, set(), {}

def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()

def respond(handler, code, data, session_key=None, ticket=None):
    inner = {'msg': 'ok' if code == 0 else data.get('error', 'error'), 'data': data,
             'sign': base64.b64encode(hmac.new(SIGN, compact(data), hashlib.sha256).digest()).decode()}
    iv = os.urandom(16) if session_key else IV
    cipher = Cipher(algorithms.AES(session_key or KEY), modes.CBC(iv)).encryptor()
    pad = PKCS7(128).padder()
    encrypted = cipher.update(pad.update(compact(inner)) + pad.finalize()) + cipher.finalize()
    payload = base64.urlsafe_b64encode((iv if session_key else b'') + encrypted).decode().rstrip('=')
    body = compact({'code': code, 'enc': 2 if session_key else 1, 'payload': payload})
    handler.send_response(200)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.send_header('Content-Length', str(len(body)))
    if ticket:
        handler.send_header('X-Access-Ticket', ticket)
        handler.send_header('X-Access-Ticket-Exp', str(int(time.time()) + 3600))
    handler.end_headers()
    handler.wfile.write(body)

def serve(handler):
    parsed = urlsplit(handler.path)
    if parsed.path != '/api.php':
        return False
    params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
    route = params.get('r', '')
    try:
        timestamp, nonce = handler.headers['X-Timestamp'], handler.headers['X-Nonce']
        device = handler.headers['X-Device-Id']
        expected = base64.b64encode(hmac.new(SIGN, f'dongni\n{route}\n{timestamp}\n{nonce}'.encode(), hashlib.sha256).digest()).decode()
        assert abs(int(timestamp) - time.time()) < 120
        assert re.fullmatch('[a-f0-9]{32}', nonce) and re.fullmatch('[a-f0-9]{32}', device)
        assert handler.headers['X-App-Id'] == 'dongni' and hmac.compare_digest(expected, handler.headers['X-Sign'])
        key = PRIVATE_KEY.decrypt(base64.b64decode(handler.headers['X-Session-PubEnc']), padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        assert len(key) == 16
        ticket = hmac.new(b'fixture-ticket', device.encode(), hashlib.sha256).hexdigest()
        origin = 'http://127.0.0.1:' + str(handler.server.server_port)
        room = {'id': '38_fixture', 'name': '测试直播间', 'platform_id': 38, 'platform_code': 'fixture', 'watched': 12, 'cdn_hls_url': origin + '/sample.m3u8'}
        sc_room = {'id': '11_90001', 'name': 'SC 原画测试', 'platform_id': 11, 'platform_code': 'sc_fixture', 'chat_room_id': 90001,
                   'cdn_hls_url': origin + '/sc/low.m3u8'}
        if route == 'app_version':
            respond(handler, 0, {'latest_version': '1.1.13', 'latest_build': 123}, ticket=ticket)
        elif route == 'live/session':
            assert params.get('device_id') == device
            assert handler.headers.get('X-Access-Ticket') == ticket
            token = os.urandom(24).hex()
            SESSIONS[device] = token
            respond(handler, 0, {'token': token, 'device_id': device, 'expire': int(time.time()) + 3600, 'required': True})
        else:
            assert handler.headers.get('X-Access-Ticket') == ticket
            assert handler.headers.get('X-Live-Session') == SESSIONS.get(device)
            if route == 'live/platforms':
                respond(handler, 0, {'platforms': [{'id': 38, 'name': '测试直播平台', 'platform_code': 'fixture', 'online_num': 1},
                                                 {'id': 11, 'name': 'SC 测试平台', 'platform_code': 'sc_fixture', 'online_num': 1}], 'count': 2})
            elif route == 'live/rooms':
                assert params.get('platform_id') in ['38', '11']
                respond(handler, 0, {'rooms': [sc_room if params['platform_id'] == '11' else room], 'count': 1})
            elif route == 'live/play':
                if params.get('id') == sc_room['id']:
                    respond(handler, 0, {**sc_room, 'user_agent': 'Live-SC-Fixture'}, session_key=key)
                    return True
                assert params.get('id') == '38_fixture'
                if device not in RETRIED:
                    # Prove that an expired session is renewed once, without a loop.
                    RETRIED.add(device)
                    respond(handler, 401, {'error': 'session expired'})
                else:
                    count = PLAYBACK_CALLS.get(device, 0) + 1
                    PLAYBACK_CALLS[device] = count
                    # A failed media URL must cause a new live/play request.
                    media = origin + ('/expired.m3u8' if count == 1 else '/sample.m3u8')
                    respond(handler, 0, {**room, 'cdn_hls_url': media, 'user_agent': 'Live-Protocol-Fixture'}, session_key=key)
            else:
                respond(handler, 404, {'error': 'unknown fixture route'})
    except Exception as error:
        print('Protocol fixture rejected request:', route, type(error).__name__, flush=True)
        respond(handler, 403, {'error': 'protocol fixture validation failed'})
    return True
