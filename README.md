# faster-whisper-fastapi

A small speech-to-text HTTP API: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) behind FastAPI, running on CPU, protected by an API key, meant to sit behind a TLS reverse proxy.

It is deliberately boring. One endpoint, one model held in memory, one request at a time, a systemd unit, and an install script. No GPU, no queue, no database.

> Based on [cucumberian/faster-whisper-fastapi](https://github.com/cucumberian/faster-whisper-fastapi) (MIT). See [Credits](#credits).

---

## Contents

- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Quick install](#quick-install)
- [Manual install](#manual-install)
- [Configuration](#configuration)
- [API](#api)
- [Putting it on the internet with Caddy](#putting-it-on-the-internet-with-caddy)
- [Managing the service](#managing-the-service)
- [Performance and resources](#performance-and-resources)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)
- [License](#license)

## What you get

- `POST /v2/transcribe` — send an audio file, get text back
- `GET /health` — unauthenticated liveness check for monitoring
- API key authentication via the `X-API-Key` header
- The model is loaded once at startup, not on the first request
- Requests are serialised, so a small box does not thrash
- A systemd unit and an idempotent install script

Tested with: fastapi 0.141.1, uvicorn 0.53.0, faster-whisper 1.2.1, ctranslate2 4.8.2, python-multipart 0.0.32, python-dotenv 1.2.3.

## Requirements

| | |
|---|---|
| OS | Debian 13 (Trixie) — the only target that has been worked through |
| Python | 3.13 (Debian 13's default); 3.10 is the floor |
| CPU | 2 cores is enough for the default settings |
| RAM | ~2.6 GB resident with `large-v3-turbo`, less with smaller models |
| Disk | ~1.6 GB for the default model |
| Network | Outbound HTTPS on first start to download the model from Hugging Face |

Debian 12 (Bookworm) also works — pass `--python-bin python3.11`, or just use its default `python3`, which is 3.11. It is simply not the version this was verified against.

`ffmpeg` is installed as part of the setup. faster-whisper itself decodes through the PyAV wheel, which ships its own codecs, so the common formats would work without it — but having ffmpeg on the box means odd containers and codecs decode too, and you can convert or inspect files on the server when something does not transcribe.

## Quick install

```bash
git clone https://github.com/mogeldev/faster-whisper-setup.git /opt/faster-whisper-fastapi
cd /opt/faster-whisper-fastapi
sudo ./install.sh
```

The script installs system packages, creates the virtualenv, installs pinned dependencies, generates an API key, writes `.env` with mode 600, installs and starts the systemd unit, then waits for `/health` to answer. First start downloads the model, so expect several minutes.

When it finishes it prints the API key and a ready-to-paste Caddy site block.

It is safe to run again. An existing `.env` is never overwritten, so your API key survives.

### Options

```bash
sudo ./install.sh --help
```

| Option | Default | |
|---|---|---|
| `--install-dir PATH` | `/opt/faster-whisper-fastapi` | where everything lands |
| `--service-name NAME` | `faster-whisper` | systemd unit name |
| `--user NAME` | `root` | user the service runs as; a system user is created if missing |
| `--model NAME` | `large-v3-turbo` | any faster-whisper model name or a local path |
| `--compute-type TYPE` | `int8` | `int8`, `int8_float32`, `float32` |
| `--threads N` | `2` | CPU threads |
| `--port N` | `8000` | port uvicorn listens on |
| `--bind-host ADDR` | `127.0.0.1` | bind address |
| `--python-bin NAME` | `python3` | interpreter to build the venv from |
| `--no-start` | off | install but do not start |

Every option can also be an environment variable:

```bash
sudo MODEL_SIZE=small CPU_THREADS=4 ./install.sh
```

> **Running as root is the default** because it is the fewest moving parts. If you would rather not, `--user whisper` creates a locked-down system account and hands it ownership of the install directory.

## Manual install

If you want to see every step, or the script's assumptions do not fit.

**1. System packages**

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-dev git curl openssl ffmpeg
```

**2. Project and virtualenv**

```bash
sudo mkdir -p /opt/faster-whisper-fastapi
cd /opt/faster-whisper-fastapi
git clone https://github.com/mogeldev/faster-whisper-setup.git .

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
pip install -r requirements.txt
```

Versions in `requirements.txt` are pinned on purpose. Unpinned installs break in two ways: faster-whisper below 1.1.0 does not know the `large-v3-turbo` alias, and a future FastAPI release may drop APIs this code uses.

**3. Configuration**

```bash
cp .env.example .env
chmod 600 .env
openssl rand -hex 32     # paste the result into API_KEY=
```

**4. Run it**

```bash
set -a; . ./.env; set +a
python -m uvicorn src.app:app --host 127.0.0.1 --port "$PORT" --workers 1
```

Expected output:

```
INFO:src.state:Loading model=large-v3-turbo (cpu, int8, 2 threads)
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:8000
```

The first start downloads ~1.6 GB into `whisper_models/`.

**5. systemd**

```bash
sudo cp faster-whisper.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now faster-whisper
```

Adjust the paths in the unit if you did not install to `/opt/faster-whisper-fastapi`.

## Configuration

Everything lives in `.env`, which is read both by the application (via python-dotenv) and by systemd (as `EnvironmentFile`). Use plain `KEY=VALUE` lines — no quotes, no `export`, no shell expansion.

| Variable | Default | Meaning |
|---|---|---|
| `API_KEY` | — | **Required.** The service refuses to start without it. |
| `MODEL_SIZE` | `large-v3-turbo` | Model name or local path |
| `COMPUTE_TYPE` | `int8` | `int8` is the sensible choice on CPU |
| `CPU_THREADS` | `2` | Threads for CTranslate2 |
| `OMP_NUM_THREADS` | `2` | Keep equal to `CPU_THREADS` |
| `PORT` | `8000` | Read by the start command, not by Python |
| `MODELS_DIR` | `whisper_models` | Use an **absolute** path; the model cache lives here |

`.env` is in `.gitignore` and must never be committed.

`MODELS_DIR` is a Hugging Face cache. Its contents sit under `models--<org>--<repo>/` with `blobs/` and `snapshots/`, not as one flat model file. `MODEL_SIZE=large-v3-turbo` resolves to `mobiuslabsgmbh/faster-whisper-large-v3-turbo` with faster-whisper 1.2.1.

### Transcription parameters

These are fixed in `src/router/v2/transcribe_router.py`:

| | | |
|---|---|---|
| `beam_size` | `1` | Greedy decoding; larger values are slower for little gain here |
| `vad_filter` | `True` | Skips silence, which is most of the speedup on real recordings |
| `condition_on_previous_text` | `False` | Avoids repetition loops on long audio |

## API

### `GET /health`

No authentication. Returns `{"status":"ok"}`.

### `POST /v2/transcribe`

| | |
|---|---|
| Auth | `X-API-Key: <key>` |
| Body | `multipart/form-data` with an `audio` file field |
| Formats | Anything PyAV decodes: wav, ogg/opus, mp3, m4a, flac, … |

```bash
curl -X POST https://your.domain.example/v2/transcribe \
  -H "X-API-Key: $API_KEY" \
  -F "audio=@recording.ogg"
```

```json
{"status": "ok", "response": " Hello, this is a test."}
```

| Situation | Status | Body |
|---|---|---|
| Success | 200 | `{"status":"ok","response":"..."}` |
| Missing or wrong key | 401 | `{"detail":"invalid api key"}` |
| No `audio` field | 422 | FastAPI validation error |
| Undecodable audio | 500 | `{"status":"error","response":"transcription failed"}` |
| Upload over the proxy limit | 413 or 502 | from the proxy, not the app; Caddy surfaced 502 in testing |

`/docs`, `/redoc` and `/openapi.json` return 404 by design.

Requests are serialised: a second request waits for the first to finish. Size your client timeouts accordingly — transcription takes minutes on longer audio.

## Putting it on the internet with Caddy

**Caddy is not installed or configured by the install script.** You set it up; this repo only gives you the site block.

The service binds to `127.0.0.1`, so it is not reachable from outside until you put a proxy in front of it.

**If Caddy runs on a different host**, loopback is the wrong target. Install with `--bind-host <lan-ip>` and point `reverse_proxy` at that same address and port, then restrict the port to the proxy host with a firewall rule — the API key is the only thing protecting it on the LAN.

1. Point a DNS A/AAAA record at the host, and make sure ports 80 and 443 are reachable. Caddy needs both to get a certificate.
2. Edit [`Caddyfile`](Caddyfile) and replace `your.domain.example`.
3. Install and reload:

```bash
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

```caddyfile
your.domain.example {
	request_body {
		max_size 25MB
	}

	reverse_proxy 127.0.0.1:8000 {
		transport http {
			read_timeout 30m
			write_timeout 30m
		}
	}

	log {
		output file /var/log/caddy/whisper.log
	}
}
```

Two settings that are not cosmetic:

- **`max_size 25MB`** — requests are serialised, so one very long file blocks everyone else. 25 MB is roughly 1–3 hours of compressed speech.
- **30 minute timeouts** — the defaults in some proxy setups are far too short for CPU transcription and will cut off legitimate requests.

Verify:

```bash
curl https://your.domain.example/health
sudo ss -tlnp | grep 8000   # must show 127.0.0.1:8000, not 0.0.0.0:8000
```

## Managing the service

| | |
|---|---|
| Status | `systemctl status faster-whisper` |
| Restart | `systemctl restart faster-whisper` |
| Follow logs | `journalctl -u faster-whisper -f` |
| Last 100 lines | `journalctl -u faster-whisper -n 100` |
| Model cache size | `du -sh /opt/faster-whisper-fastapi/whisper_models` |

Restart after editing `.env` or any source file. Rotating the API key means editing `.env` and restarting.

## Performance and resources

| | |
|---|---|
| Disk (default model) | ~1.6 GB |
| RAM at runtime | ~2.6 GB |
| Fixed cost per request | ~23 s, independent of audio length |
| Marginal cost | ~0.42 s per second of audio (~2.4x realtime) |

Measured on a 2-core Debian 13 container with `large-v3-turbo` at `int8`, over HTTPS through a reverse proxy:

| Audio | Wall clock |
|---|---|
| 3.9 s | 24.1 s |
| 31.5 s | 36.3 s |
| 90.6 s | 61.0 s |

**There is a large fixed cost per request — about 23 seconds here — on top of roughly 0.42 seconds per second of audio.** A four-second clip therefore costs almost as much as a thirty-second one. If your workload is many short clips, batch them into longer files; the per-second rate is about six times better than the short-clip average. The cause of the fixed cost has not been isolated.

The first start additionally spends about 16 minutes downloading and loading the model; subsequent restarts load it from cache in about 5 seconds.

More cores help close to linearly up to a point; `--threads 4` on a 4-core box is a reasonable first move.

If that is too slow, trade accuracy for speed by changing `MODEL_SIZE`:

| Model | Disk | Relative speed |
|---|---|---|
| `large-v3-turbo` | ~1.6 GB | baseline |
| `distil-large-v3` | ~1.5 GB | ~1.5–2x faster |
| `small` | ~0.5 GB | ~3–4x faster |
| `base` | ~0.15 GB | ~6–8x faster |
| `tiny` | ~0.08 GB | ~10x faster, noticeably worse |

Change it in `.env` and restart. The new model downloads on next start.

## Security model

```
Internet ──TLS──> Caddy :443 ──HTTP──> 127.0.0.1:8000 (uvicorn)
                                        └─ X-API-Key checked here
```

| Decision | Why |
|---|---|
| Key checked in FastAPI, not in Caddy | The key stays in a gitignored `.env` instead of the Caddyfile, the check also applies to anything reaching the port directly, and `secrets.compare_digest` compares in constant time. Caddy's `header` matcher does not. |
| Binds to `127.0.0.1` | On `0.0.0.0` the service would be reachable unprotected at `http://<host>:8000` no matter what the proxy does. |
| `/docs`, `/redoc`, `/openapi.json` disabled | No schema disclosure to unauthenticated callers. |
| Generic error bodies | The router and the exception handler log the real error and return `transcription failed` / `internal server error`. Decoder exceptions contain file paths. |
| Missing key and wrong key both 401 | The response does not distinguish the two cases. |
| `/health` unauthenticated | It discloses nothing, and monitoring should not need the key. |
| `.env` is mode 600 | It holds the key and is read by systemd. |

**Known limits.** A single shared API key means no per-client revocation and no rate limiting. There is no request quota and no concurrency cap beyond the serialising lock, so an authenticated client can monopolise the service.

If your clients are known systems rather than arbitrary users, consider stronger options:

- **mTLS** — Caddy supports client certificates natively (`client_auth`). Much stronger than a shared secret, at the cost of distributing certificates.
- **A private network** — WireGuard or Tailscale, in which case you do not need the public proxy at all.
- **Rate limiting** — not built into Caddy; it needs the [`caddy-ratelimit`](https://github.com/mholt/caddy-ratelimit) plugin and an `xcaddy` build.

Please report security issues privately via a GitHub security advisory rather than a public issue.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `RuntimeError: API_KEY is not set` | Generate one (`openssl rand -hex 32`) and put it in `.env` |
| Everything returns 401 | Header must be `X-API-Key`. Check `.env` for stray quotes or whitespace, then restart |
| `ModuleNotFoundError: No module named 'src'` | uvicorn must start from the project root, and `src/__init__.py` must exist. `python src/app.py` never works — the imports are absolute. |
| `transcription failed` on valid audio | The real error is in the log: `journalctl -u faster-whisper -n 50` |
| Service restarts in a loop | `journalctl -u faster-whisper -n 50`. Usually a wrong `WorkingDirectory`, a missing `API_KEY`, or `PORT` not resolving from `EnvironmentFile`. |
| `Unknown model size` | faster-whisper below 1.1.0. `pip install -U -r requirements.txt` |
| Model re-downloads on every start | `MODELS_DIR` is relative; make it absolute |
| Killed / OOM | Use a smaller `MODEL_SIZE` |
| 502 from Caddy | The service is not running or listens elsewhere: `ss -tlnp \| grep 8000` |
| 413 or an immediate 502 from Caddy | File exceeds `request_body max_size`. A 502 within a second of starting the upload is this, not a dead backend. Raise the limit or compress the audio. |
| `Permission denied` on ExecStart | `chmod -R u+rx /opt/faster-whisper-fastapi/.venv` |
| Port already in use | Change `PORT` in `.env`, update the Caddyfile, restart both |

## Credits

The idea and the original `/v2/transcribe` shape come from [cucumberian/faster-whisper-fastapi](https://github.com/cucumberian/faster-whisper-fastapi) (MIT).

This repository is not a GitHub fork but a separate project. What differs:

- CPU-first configuration: `int8`, configurable thread count, `large-v3-turbo` by default
- Model and lock moved into `src/state.py`, loaded during `lifespan` instead of on the first request
- API key authentication (`src/auth.py`)
- Docs and schema endpoints disabled, generic error responses
- systemd and Caddy deployment instead of Docker
- Pinned dependencies and an install script

Transcription itself is [faster-whisper](https://github.com/SYSTRAN/faster-whisper) on [CTranslate2](https://github.com/OpenNMT/CTranslate2). The heavy lifting is theirs.

## License

MIT — see [LICENSE](LICENSE). The original copyright notice is retained as the license requires.
