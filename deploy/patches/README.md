# Local patches

Fixes this deployment carries that are not in upstream yet.

The `docker` branch deliberately keeps its source tree byte-identical to
upstream, which is what lets the daily sync merge run unattended: the guard in
`.github/workflows/sync-upstream.yml` refuses any merge where something outside
`deploy/` differs. Committing a fix into `src/` or `server/` would break that
and turn every sync into a manual conflict.

So fixes live here as unified diffs and are applied inside the image build,
after the source is copied and before anything runs. The built container has
them; the branch does not.

## What is carried

| Patch | Fixes |
| --- | --- |
| `0001-select-dropdown-contrast.patch` | Dropdown menus rendered near-white text on the browser's white popup, making options unreadable until hovered. Declares `color-scheme: dark` on `:root` so the browser paints native popups and scrollbars dark, plus explicit `option` colours as a fallback. |
| `0002-google-daily-budget-and-streetview-cache.patch` | Two uncapped Google spend paths. Adds a persistent per-UTC-day budget shared by `/api/google/nearby-places` and `/api/google/text-search` (default 150/day, `GEV_GOOGLE_PLACES_DAILY_BUDGET=0` opts out), and a disk cache for the CCTV Street View fallback, which previously re-billed on every frame refresh for as long as a camera stayed down. |

## When a patch stops applying

Upstream changing the same lines is expected, not an emergency. The image build
fails with `[patch] FAILED: <file> no longer applies`, `latest` stays on the
last good image, and an issue labelled `image-build-failed` opens. Nothing
deployed changes until it is fixed.

To refresh one:

```bash
# from the repo root, on the docker branch
patch -p1 --input=deploy/patches/0001-select-dropdown-contrast.patch   # apply by hand
# ...resolve whatever moved, edit the files until correct...
git diff -- src/ > deploy/patches/0001-select-dropdown-contrast.patch  # regenerate
git checkout -- src/ server/                                           # restore the tree
```

Always restore the source tree afterwards. `git status` must show changes only
under `deploy/`, or the next sync will refuse to push.

## Retiring a patch

These are workarounds, not a fork. If a fix lands upstream, delete the patch
file; the next build picks up upstream's version. Check by reading the diff
against current upstream before assuming a patch is still needed.
