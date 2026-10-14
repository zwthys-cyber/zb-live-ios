The UI fixtures are local and do not contact livestream platforms.

`page.html` is a plain text test page. `sample.mp4` is a generated eight-second solid-color H.264/AAC clip with silent audio, created using:

```bash
ffmpeg -f lavfi -i color=c=0x247B85:s=320x180:r=24 -f lavfi -i anullsrc=r=44100:cl=stereo -t 8 -c:v libx264 -preset fast -pix_fmt yuv420p -c:a aac -b:a 32k -movflags +faststart sample.mp4
```

`sample.m3u8` and its four MPEG-TS segments contain the same generated solid-color / silent content, encoded with two-second keyframes using FFmpeg's HLS VOD muxer. `channels.m3u` is a subscription with a relative link to that local HLS fixture.

The server binds only to `127.0.0.1`. It supports range requests required by AVPlayer. The iOS simulator reaches this local server at `http://127.0.0.1:8765/`. An optional `LIVE_FIXTURE_PORT` environment variable changes the port for local development.
