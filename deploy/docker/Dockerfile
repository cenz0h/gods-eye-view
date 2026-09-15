# syntax=docker/dockerfile:1.7
# God's Eye View — runtime image (unofficial packaging of bilawalsidhu/gods-eye-view).
#
# Builds the client bundle on first start (so GOOGLE_MAPS_API_KEY / CESIUM_ION_TOKEN can be
# frozen into dist/ from the container environment), then serves it with `vite preview`,
# whose plugins also provide every /api/* proxy. There is no standalone server upstream:
# server/providers/* are Vite plugins, so a static dist/ behind nginx would lose every layer.
FROM node:24-bookworm-slim

# Baked in by CI. GEV_BUILD_ID (docker-branch commit) is part of the dist build stamp:
# any new image triggers exactly one client rebuild on first start.
ARG GEV_BUILD_ID=dev
ARG GEV_SOURCE_REV=unknown
ARG GEV_UPSTREAM_SHA=unknown
ARG GEV_BUILD_DATE=unknown
ARG GEV_VERSION=0.0.0

# NOTE: never set NODE_ENV=production here — npm ci would omit devDependencies, and
# vite / vite-plugin-cesium / ws (all needed at runtime) live there.
ENV PUPPETEER_SKIP_DOWNLOAD=1 \
    GEV_BUILD_ID=${GEV_BUILD_ID} \
    GEV_UPSTREAM_SHA=${GEV_UPSTREAM_SHA} \
    HOST=0.0.0.0 \
    PORT=4173 \
    PUID=1000 \
    PGID=1000 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# WORKDIR creates /app owned by root; npm ci runs as `node` and must create /app/node_modules in it.
RUN chown node:node /app

# 1) Dependencies (only invalidates when the lockfile changes). Runs as `node` with an npm cache
#    mount, so no root-owned files and no cache in a layer. Puppeteer/sharp are QA-only: prune them
#    (tree-aware; keeps ws). Never use --omit=dev or --omit=optional (esbuild/rollup natives).
COPY --chown=node:node package.json package-lock.json ./
USER node
RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000,sharing=locked \
    npm ci --no-audit --no-fund \
 && npm uninstall --no-save puppeteer sharp \
 && node -e "require('ws'); import('vite').then(()=>import('vite-plugin-cesium')).then(()=>console.log('runtime deps OK'))"

# 2) Source tree. server/ imports src/ and scripts/; config/*.json and src/data/local_data are read
#    at runtime; build/ needs src/ui/templates. LICENSE, DATA_SOURCES.md, public/models/README.md
#    must remain in the image (redistribution notices).
USER root
COPY --chown=node:node . .

# 2b) Local fixes, carried as patches rather than commits. The docker branch
#     keeps its source tree byte-identical to upstream so the daily sync merge
#     stays automatic and conflict-free; the fixes live in deploy/patches and
#     are applied here instead. Each is described in deploy/patches/README.md.
#
#     A patch that no longer applies fails the build on purpose. The smoke test
#     never runs, no tag moves, and deployments keep pulling the last good image
#     until the patch is refreshed against upstream.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends patch \
 && rm -rf /var/lib/apt/lists/* \
 && for p in deploy/patches/*.patch; do \
      patch -p1 --batch --forward --dry-run --input="$p" >/dev/null \
        || { echo "[patch] FAILED: $(basename "$p") no longer applies to this upstream revision"; exit 1; }; \
    done \
 && for p in deploy/patches/*.patch; do \
      echo "[patch] applying $(basename "$p")"; \
      patch -p1 --batch --forward --input="$p" \
        || { echo "[patch] FAILED while applying $(basename "$p")"; exit 1; }; \
    done \
 && chown -R node:node /app/src /app/server

COPY --chmod=755 deploy/docker/entrypoint.sh /usr/local/bin/gev-entrypoint

# 3) Writable locations (volumes mount over the first three).
RUN mkdir -p /app/dist /app/.gev-cache /app/.gev-logs /app/node_modules/.vite \
 && chown -R node:node /app/dist /app/.gev-cache /app/.gev-logs /app/node_modules/.vite

LABEL org.opencontainers.image.title="God's Eye View" \
      org.opencontainers.image.description="Unofficial container packaging of bilawalsidhu/gods-eye-view. Code MIT; bundled third-party data under its own licenses (non-commercial: TeleGeography CC BY-NC-SA). See LICENSE and DATA_SOURCES.md in the image." \
      org.opencontainers.image.url="https://github.com/cenz0h/gods-eye-view/tree/docker/deploy/docker" \
      org.opencontainers.image.source="https://github.com/cenz0h/gods-eye-view" \
      org.opencontainers.image.documentation="https://github.com/cenz0h/gods-eye-view/blob/docker/deploy/docker/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${GEV_VERSION}" \
      org.opencontainers.image.revision="${GEV_SOURCE_REV}" \
      org.opencontainers.image.created="${GEV_BUILD_DATE}" \
      io.github.cenz0h.gev.upstream-sha="${GEV_UPSTREAM_SHA}" \
      io.github.cenz0h.gev.upstream-repo="https://github.com/bilawalsidhu/gods-eye-view"

EXPOSE 4173

# Long start period: the first start runs `vite build` (1-5 min). slim has no curl -> node fetch.
HEALTHCHECK --interval=30s --timeout=10s --start-period=900s --retries=3 \
  CMD ["node","-e","fetch('http://127.0.0.1:'+(process.env.PORT||4173)+'/').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]

# Starts as root only to fix volume ownership, then drops to PUID:PGID (see entrypoint).
USER root
ENTRYPOINT ["gev-entrypoint"]
