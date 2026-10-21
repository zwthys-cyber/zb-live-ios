The UI fixtures are local and do not contact livestream platforms.

`page.html` is a plain text test page. `sample.mp4` is a generated eight-second solid-color H.264/AAC clip with silent audio, created using:

```bash
ffmpeg -f lavfi -i color=c=0x247B85:s=320x180:r=24 -f lavfi -i anullsrc=r=44100:cl=stereo -t 8 -c:v libx264 -preset fast -pix_fmt yuv420p -c:a aac -b:a 32k -movflags +faststart sample.mp4
```

`sample.m3u8` and its four MPEG-TS segments contain the same generated solid-color / silent content, encoded with two-second keyframes using FFmpeg's HLS VOD muxer. `channels.m3u` is a subscription with a relative link to that local HLS fixture.

The server binds only to `127.0.0.1`. It supports range requests required by AVPlayer. The iOS simulator reaches this local server at `http://127.0.0.1:8765/`. An optional `LIVE_FIXTURE_PORT` environment variable changes the port for local development.

协议服务使用 api-test-private.pem（专门生成的公开测试密钥，与生产密钥无关），验证 HMAC、32 位设备 ID、RSA-OAEP-SHA256、票据、会话续期、AES-CBC enc=1 / enc=2。协议测试仅播放本地纯色视频。

`fixture_sc.py` 模拟 SC 主清单、独立测试描述符和 MOUFLON v2 混淆分片地址。低档线路及未解码的 `media.mp4` 固定拒绝；只有选择主清单中的 source 档、正确协商并还原地址后才返回上面的纯色 TS。主清单声明的画质只用于选择逻辑，夹具视频仍是 320×180。90002 测试房间故意让旧描述符返回 HTTP-200 占位清单，验证客户端重新读取主清单并切换新描述符。
