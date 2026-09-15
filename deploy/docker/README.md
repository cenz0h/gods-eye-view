# God's Eye View — Docker / Unraid

Unofficial container packaging of [bilawalsidhu/gods-eye-view](https://github.com/bilawalsidhu/gods-eye-view).

This lives on the `docker` branch of the fork. The `main` branch is a pure mirror of upstream and
never carries local changes; `docker` is `main` plus this `deploy/` directory and two workflow files.
A scheduled action fast-forwards the mirror daily, merges it here, and publishes a new image.

**Image:** `ghcr.io/cenz0h/gods-eye-view`

| Tag | Meaning |
| --- | --- |
| `latest` | newest successful build of the `docker` branch |
| `upstream-<sha>` | pinned to a specific upstream commit |
| `sha-<sha>` | pinned to a specific `docker` branch commit |
| `YYYY-MM-DD` | the build published that day |

Pin a dated or `upstream-` tag if you want to control when the app changes under you.

## How it runs

Upstream has no standalone server. The provider APIs (`/api/*` for aircraft, vessels, satellites,
CCTV, traffic, fires, radio, voice) are Vite plugins, so the container runs `vite preview`, which
serves the built client *and* those routes. A static `dist/` behind nginx would lose every live layer.

Two keys are compiled into the browser bundle rather than read at request time, so the container
**builds the bundle on start**:

- first start, or an empty `dist` volume
- after an image update
- when `GOOGLE_MAPS_API_KEY` or `CESIUM_ION_TOKEN` changes
- when `GEV_FORCE_REBUILD=1`

Otherwise it reuses what is in the volume and starts in seconds. Cesium is copied rather than
bundled, so the build is quicker than its size suggests: measured at about 5 seconds on a 20-core
desktop and 10 seconds on a GitHub runner. Allow a minute or two on a modest NAS CPU. Watch it with
`docker logs -f gods-eye-view` and look for `[gev] building client bundle: ...` followed by
`[gev] build complete in Ns`. The health check allows 15 minutes before reporting a problem, so a
container sitting in `health: starting` during the first build is expected.

| Volume | Purpose | Safe to delete? |
| --- | --- | --- |
| `/app/.gev-cache` | provider caches: terrain heights (30 day TTL), satellite TLEs, Overpass results, and the TomTom daily tile budget counter | yes, but you lose the tile budget counter for that day and re-fetch expensive terrain |
| `/app/.gev-logs` | voice conversation debug log, written only when voice is used, grows unbounded | yes |
| `/app/dist` | the built client bundle, about 100 MB | yes, rebuilt on next start |

Runs as `PUID:PGID` (default `1000:1000`; the compose file and Unraid template set Unraid's
`99:100`). The container starts as root only to fix volume ownership, then drops privileges with
`setpriv`. Memory: the build peaks around 1.5-2 GB, steady state is about 300 MB, so the supplied
3 GB limit is comfortable.

## Quick start with compose

```bash
cd deploy/docker
cp gev.env.example gev.env       # then edit gev.env and add whichever keys you have
docker compose up -d
docker compose logs -f           # watch the first build
```

Open `http://<host>:4173`. Every key is optional: with none set the globe still boots on keyless
Esri World Imagery.

## Unraid

Two ways to install the template:

1. **Reliable:** copy `deploy/unraid/gods-eye-view.xml` to the flash drive at
   `/boot/config/plugins/dockerMan/templates-user/my-gods-eye-view.xml`, then go to
   Docker, Add Container, and pick it from the template dropdown under "User templates".
2. Docker tab, Template Repositories, add
   `https://github.com/cenz0h/gods-eye-view/tree/docker/deploy/unraid`.

Or use the compose file with the Compose Manager plugin. Paths default to
`/mnt/user/appdata/gods-eye-view/{cache,logs,dist}`.

Serving roughly 600 small Cesium asset files over Unraid's `/mnt/user` FUSE share can make the first
page load sluggish. If you notice it, point the `dist` path at `/mnt/cache/appdata/...` instead, or
switch to a named volume.

## Reverse proxy

**HTTPS is required for voice control.** The microphone and WebRTC only work in a secure context, so
over plain `http://<ip>:4173` the browser silently withholds microphone access and the voice feature
is unavailable. Everything else works fine over plain HTTP.

`HOST=0.0.0.0` is baked into the image. That is what flips Vite's `allowedHosts` to accept any
hostname. If you override `HOST`, requests arriving with your domain in the `Host` header are
rejected with `403 Blocked request. This host is not allowed`.

No WebSocket support is needed between browser and server. The AIS stream is an outbound connection
from the container, and voice connects the browser directly to OpenAI over WebRTC. Enabling
websocket support in your proxy is harmless.

The CCTV media proxy streams upstream MJPEG, HLS and JPEG bodies and forwards `Range` headers, so
turn proxy buffering off and allow long reads.

Nginx or Nginx Proxy Manager "Advanced" tab:

```nginx
location / {
  proxy_pass http://<unraid-ip>:4173;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_buffering off;
  proxy_request_buffering off;
  proxy_read_timeout 300s;
  proxy_send_timeout 300s;
  client_max_body_size 16m;
}
```

Caddy: `reverse_proxy <ip>:4173 { flush_interval -1 }`. Traefik defaults are fine.

The app sends `X-Frame-Options: DENY` and `Content-Security-Policy: frame-ancestors 'none'`, so it
cannot be embedded in a dashboard iframe such as Homepage or Organizr. Do not strip those headers.

### Google billing

**Read this before you set `GOOGLE_MAPS_API_KEY`.** Google Maps Platform is pay-as-you-go. The
free allowance is granted per SKU per month, and three of the four SKUs this app can reach are
requested by the **browser talking straight to Google**. Nothing in this container sits in that
path, so no environment variable here can cap them.

| What the app uses | Free per month | Then | Who calls Google | Cappable here? |
| --- | --- | --- | --- | --- |
| Photorealistic 3D Tiles | 1,000 | $6.00 / 1,000 | browser | no |
| Geocoding (search, voice, HUD) | 10,000 | $5.00 / 1,000 | browser | no |
| Places Nearby + Text Search | 5,000 each | $32.00 / 1,000 | this container | burst guard only |
| Street View Static (CCTV fallback) | 10,000 | $7.00 / 1,000 | this container | no |

Two things to understand about the shape of the spend:

- **3D tiles are cheaper than they look.** Only the root tileset request bills; the thousands of
  tiles the renderer streams while you fly around are free and unmetered. One root request covers
  roughly three hours of rendering, and the app opens one per page load. About 30 page loads a day
  stays inside the free tier.
- **Idle time is not free.** The heads-up display refreshes every 15 seconds, and each refresh can
  reverse-geocode the view centre and, below 25 km, ask Places what is nearby. Results are cached
  in the page for positions within about 11 metres, so a stationary view settles down, but a moving
  camera or a left-open dashboard keeps billing. Places is the expensive one at $32 per 1,000 with
  only 5,000 free, so sustained low-altitude browsing is what actually costs money.

#### Set daily quotas, because they are the only hard stop

Budget alerts only email you; they do not stop requests. Per-API daily quotas do. In the
[Google Cloud console](https://console.cloud.google.com/google/maps-apis/quotas), pick your
project, then for each API below open **Quotas**, filter for the per-day limit, and set it. Over
quota, Google refuses the request instead of billing it, and the app degrades: the globe falls
back to Esri imagery, search stops resolving, the traffic and CCTV layers show their error state.

| API | Suggested requests/day | Why |
| --- | --- | --- |
| Map Tiles API | 30 | 1,000/month free ÷ 31 |
| Geocoding API | 300 | 10,000/month free ÷ 31 |
| Places API (New) | 150 | 5,000/month free ÷ 31 |
| Street View Static API | 300 | 10,000/month free ÷ 31 |

Also restrict the key itself (APIs & Services, Credentials): an HTTP referrer restriction limited
to your own hostname, and an API restriction listing only the four APIs above. The key ships inside
the JavaScript bundle and is visible in devtools by design, so the referrer restriction is what
stops someone else spending it.

#### The zero-cost configuration

If you would rather not enable Google billing at all, leave `GOOGLE_MAPS_API_KEY` empty and set
only `CESIUM_ION_TOKEN`. The app then loads the same Google Photorealistic 3D tiles through Cesium
ion instead, which is free within an eligible ion Community account, and no Google SKU is touched.
You lose place search, the HUD's place context, and voice commands that resolve a named location.
With neither key the globe still works on keyless Esri World Imagery.

`GEV_RATELIMIT_GOOGLE_PER_MIN` (default 10 here) guards only the two server-side Places routes. It
is a burst guard against a runaway loop, not a budget: a per-minute ceiling cannot bound a day.

### Security

**There is no authentication on `/api/*`.** Anyone who can reach the port can drive the proxies and
spend your OpenAI, Google, TomTom, AISStream and OpenSky quota. Upstream's `SECURITY.md` is explicit
that this is a development-grade server. So:

- Put it behind your proxy's access control: Nginx Proxy Manager access lists, Authelia,
  Cloudflare Access, or a VPN such as Tailscale.
- Never port-forward 4173 to the internet directly.
- Set `GEV_RATELIMIT_OPENAI_PER_MIN` and `GEV_RATELIMIT_GOOGLE_PER_MIN`. Unset means unlimited.
  Note the limiter keys on the socket address and ignores `X-Forwarded-For`, so behind a proxy every
  browser shares one bucket and these act as whole-site caps rather than per-user ones.
- Configure real budgets and alerts at each provider. The in-app throttles are not billing caps.
- Restrict the two browser-visible keys at the provider: HTTP referrer restriction for the Google
  Maps key, and a public `assets:read` token for Cesium ion.

The in-app "Provider Settings" key panel does not exist in this image. Upstream gates it to
development mode and loopback callers only, so all keys must come from the environment.

## Configuration

Copy `gev.env.example` to `gev.env`. Upstream's `.env.example` at the repo root documents every
variable in detail, including the CCTV feed toggles not listed here.

Environment variables always win over a `.env` file, so you can also mount a full
`/app/.env:ro` if you prefer; its contents are included in the rebuild stamp.

`OPENSKY_CREDENTIALS_FILE` is not supported in the container; it is handled by a development shell
script only. Use `OPENSKY_CLIENT_ID` and `OPENSKY_CLIENT_SECRET`.

## Operations

- **Update:** `docker compose pull && docker compose up -d`. The bundle rebuilds once on the next
  start because the image build id changed.
- **Force a rebuild:** set `GEV_FORCE_REBUILD=1`, start, then remove it again.
- **Upstream syncing** is automatic and daily. A merge conflict opens an issue labelled
  `upstream-sync` on the fork; a broken build opens one labelled `image-build-failed` and leaves
  `:latest` pointing at the last good image. Run `deploy/scripts/sync-upstream.sh` to sync by hand.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `403 Blocked request. This host is not allowed` | `HOST` was overridden; it must stay `0.0.0.0` |
| `EACCES` writing `/app/dist` or `.gev-cache` | wrong `PUID`/`PGID` for your appdata paths, or the container was started with an explicit `user:` that cannot write them |
| Build killed part way, container restarts | out of memory: raise `mem_limit` or lower `GEV_BUILD_NODE_OPTIONS` |
| Health check stuck in `starting` for minutes | normal on first start, the bundle is building; check the log |
| Voice button does nothing | not served over HTTPS, or `OPENAI_API_KEY` unset |
| Vessels layer stays empty | `AISSTREAM_API_KEY` unset; look for the `[AISStream]` line in the log |
| Slow first page load on Unraid | `/mnt/user` FUSE overhead, point `dist` at `/mnt/cache/appdata/...` |

## Licensing

Upstream code is MIT and `LICENSE` ships inside the image. The bundled datasets are not MIT: the
TeleGeography submarine cable data is CC BY-NC-SA 3.0, which makes this image **non-commercial**.
OpenStreetMap-derived datacentre and dam extracts are ODbL, and the 3D models under `public/models/`
are CC BY 4.0 with attribution in `public/models/README.md`. See `DATA_SOURCES.md` in the image for
the full per-source summary. Live data you fetch with your own keys is subject to each provider's
terms; several, including OpenSky and Google, restrict commercial use.
