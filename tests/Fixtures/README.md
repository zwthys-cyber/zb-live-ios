The UI fixtures are local and do not contact livestream platforms.

`page.html` is a plain text test page. `sample.mp4` is a generated eight-second solid-color H.264/AAC clip with silent audio, created using:

```bash
ffmpeg -f lavfi -i color=c=0x247B85:s=320x180:r=24 -f lavfi -i anullsrc=r=44100:cl=stereo -t 8 -c:v libx264 -preset fast -pix_fmt yuv420p -c:a aac -b:a 32k -movflags +faststart sample.mp4
```

The server binds only to `127.0.0.1`. It supports range requests required by AVPlayer. The iOS simulator reaches this local server at `http://127.0.0.1:8765/`.
