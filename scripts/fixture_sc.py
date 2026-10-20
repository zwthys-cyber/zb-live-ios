"""Synthetic SC original-quality/MOUFLON fixtures; never contact a live platform."""
import base64
import hashlib
import re
from urllib.parse import parse_qs, urlsplit

KEY_ID = 'fixture-key'
DECODE_KEY = 'fixture-public-decode-key'
ROTATED_KEY_ID = 'fixture-rotated-key'
ROTATED_DECODE_KEY = 'fixture-rotated-decode-key'
ROTATION = {'retired': False, 'old_reads': 0, 'new_reads': 0}


def send(handler, status, body, content_type='application/vnd.apple.mpegurl'):
    if isinstance(body, str):
        body = body.encode()
    handler.send_response(status)
    handler.send_header('Content-Type', content_type)
    handler.send_header('Content-Length', str(len(body)))
    handler.send_header('Cache-Control', 'no-store')
    handler.end_headers()
    handler.wfile.write(body)


def token(value, key=DECODE_KEY):
    digest = hashlib.sha256(key.encode()).digest()
    raw = bytes(value ^ digest[i % len(digest)] for i, value in enumerate(value.encode()))
    return base64.b64encode(raw).decode().rstrip('=')[::-1]


def serve(handler, fixture_root):
    parsed = urlsplit(handler.path)
    if not parsed.path.startswith('/sc/'):
        return False
    origin = 'http://127.0.0.1:' + str(handler.server.server_port)
    rotating_master = parsed.path == '/sc/hls/90002/master/90002_auto.m3u8'
    if parsed.path == '/sc/hls/90001/master/90001_auto.m3u8' or rotating_master:
        key_id = ROTATED_KEY_ID if rotating_master and ROTATION['retired'] else KEY_ID
        media_path = '/sc/rotation/source.m3u8' if rotating_master else '/sc/source.m3u8'
        send(handler, 200, f'''#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MOUFLON:PSCH:v2:unknown-retired-key
#EXT-X-MOUFLON:PSCH:v2:{key_id}
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=180x240,NAME="240p"
{origin}/sc/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=720x960,NAME="source"
{origin}{media_path}?playlistType=standard
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=360x480,NAME="480p"
{origin}/sc/low.m3u8
''')
    elif parsed.path == '/sc/rotation/state':
        import json
        send(handler, 200, json.dumps(ROTATION), 'application/json')
    elif parsed.path in ['/sc/source.m3u8', '/sc/rotation/source.m3u8']:
        params = parse_qs(parsed.query)
        rotating = parsed.path == '/sc/rotation/source.m3u8'
        if rotating and params.get('pkey') == [KEY_ID]:
            ROTATION['old_reads'] += 1
            if ROTATION['old_reads'] >= 2:
                ROTATION['retired'] = True
        key_id = ROTATED_KEY_ID if rotating and ROTATION['retired'] else KEY_ID
        decode_key = ROTATED_DECODE_KEY if key_id == ROTATED_KEY_ID else DECODE_KEY
        if params.get('psch') != ['v2'] or params.get('pkey') != [key_id]:
            send(handler, 200, '#EXTM3U\n#EXT-X-MOUFLON-ADVERT\n#EXT-X-ENDLIST\n')
        elif handler.headers.get('Origin') != 'https://stripchat.com':
            send(handler, 403, 'missing playback headers', 'text/plain')
        else:
            if rotating and key_id == ROTATED_KEY_ID:
                ROTATION['new_reads'] += 1
            lines = ['#EXTM3U', '#EXT-X-VERSION:6', f'#EXT-X-MOUFLON:PSCH:v2:{key_id}',
                     '#EXT-X-TARGETDURATION:2', '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD']
            for index in range(4):
                uri = f'{origin}/sc/media/90001_{index}_{token("fixtureSegment", decode_key)}_12345.ts'
                lines += ['#EXTINF:2.0,', '#EXT-X-MOUFLON:URI:' + uri, origin + '/sc/media/media.mp4']
            lines += ['#EXT-X-ENDLIST', '']
            send(handler, 200, '\n'.join(lines))
    else:
        match = re.fullmatch(r'/sc/media/90001_([0-3])_fixtureSegment_12345.ts', parsed.path)
        if match:
            send(handler, 200, (fixture_root / f'segment0{match[1]}.ts').read_bytes(), 'video/MP2T')
        else:
            # Choosing a low rendition or retaining media.mp4 must fail the UI test.
            send(handler, 403, 'wrong SC rendition or undecoded segment', 'text/plain')
    return True
