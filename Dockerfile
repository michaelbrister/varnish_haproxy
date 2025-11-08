# ------------------------------------------------------------------------------
# Stage 1: Build VMODs (varnish-modules -> includes bodyaccess, header, cookie)
# ------------------------------------------------------------------------------

ARG DEBIAN_CODENAME=bookworm
ARG VARNISH_MAJOR=7
ARG VARNISH_VERSION=7.5
ARG VARNISH_MODULES_TAG=0.20.0   # pick a tag compatible with your Varnish version

FROM debian:${DEBIAN_CODENAME} AS vmods-builder

ARG VARNISH_MAJOR
ARG VARNISH_VERSION
ARG VARNISH_MODULES_TAG

ENV DEBIAN_FRONTEND=noninteractive

# Add Varnish Cache official repo (packagecloud)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg && \
    curl -s https://packagecloud.io/install/repositories/varnishcache/varnish${VARNISH_MAJOR}/script.deb.sh | bash

# Build deps + varnish-dev
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential automake autoconf libtool pkg-config git \
      python3 python3-docutils \
      varnish=${VARNISH_VERSION}* varnish-dev=${VARNISH_VERSION}* \
      libpcre2-dev libjemalloc-dev && \
    rm -rf /var/lib/apt/lists/*

# Build varnish-modules (provides bodyaccess, header, cookie, tcp, saintmode, etc.)
WORKDIR /src
RUN git clone --depth=1 --branch v${VARNISH_MODULES_TAG} https://github.com/varnish/varnish-modules.git
WORKDIR /src/varnish-modules
RUN ./bootstrap && ./configure && make -j"$(nproc)" && make install

# Stage export: collect VMOD .so files (and vcc/metadata) into /out
RUN mkdir -p /out/usr/lib/varnish/vmods /out/usr/share/varnish/vmods && \
    cp -a /usr/lib/varnish/vmods/*.so /out/usr/lib/varnish/vmods/ && \
    cp -a /usr/share/varnish/vmods/*  /out/usr/share/varnish/vmods/ || true


# ------------------------------------------------------------------------------
# Stage 2: Runtime (slim) - Varnish + HAProxy + our built VMODs
# ------------------------------------------------------------------------------

FROM debian:${DEBIAN_CODENAME}-slim AS runtime

ARG VARNISH_MAJOR
ARG VARNISH_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    VARNISH_LISTEN_ADDRESS=0.0.0.0 \
    VARNISH_LISTEN_PORT=80 \
    VARNISH_STORAGE="malloc,512m" \
    VARNISH_USER=varnish \
    VARNISH_GROUP=varnish \
    HAPROXY_LISTEN_ADDRESS=127.0.0.1 \
    HAPROXY_LISTEN_PORT=8081

# Add Varnish Cache repo
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg && \
    curl -s https://packagecloud.io/install/repositories/varnishcache/varnish${VARNISH_MAJOR}/script.deb.sh | bash

# Install runtime bits only
RUN apt-get update && apt-get install -y --no-install-recommends \
      varnish=${VARNISH_VERSION}* \
      haproxy \
      gettext-base  # for envsubst to render templates
    && rm -rf /var/lib/apt/lists/*

# Copy VMODs from builder
COPY --from=vmods-builder /out/ /

# Layout for configs & templates
RUN mkdir -p /etc/varnish /etc/haproxy /templates /var/lib/varnish /var/log/varnish /var/log/haproxy

# Copy your template configs (provided at build context root)
#   - /templates/default.vcl.tmpl
#   - /templates/haproxy.cfg.tmpl
COPY default.vcl.tmpl /templates/default.vcl.tmpl
COPY haproxy.cfg.tmpl  /templates/haproxy.cfg.tmpl

# Minimal entrypoint to render templates and run both daemons (no supervisord)
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80
# (Optional) expose HAProxy stats/admin if your haproxy.cfg.tmpl uses it:
# EXPOSE 8404

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${VARNISH_LISTEN_PORT}/" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
