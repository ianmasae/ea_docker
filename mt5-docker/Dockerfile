# =============================================================================
# MT5 Headless on ARM64 (Apple Silicon) using Hangover Wine
# Hangover runs Wine natively on ARM64, emulating only Windows app code via FEX
# =============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:99
ENV WINEDEBUG=-all
# Disable Mono/.NET prompt (MT5 doesn't need it)
ENV WINEDLLOVERRIDES="mscoree=d"

# Install ca-certificates first (over HTTP), then switch to HTTPS
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g' /etc/apt/sources.list && \
    sed -i 's|http://security.ubuntu.com|https://security.ubuntu.com|g' /etc/apt/sources.list && \
    rm -rf /var/lib/apt/lists/*

# Install runtime dependencies + noVNC for browser-based GUI access
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    xvfb wget xauth procps openbox xdotool \
    x11vnc novnc python3 python3-websockify \
    && rm -rf /var/lib/apt/lists/*

# Install Hangover Wine (ARM64-native Wine with FEX x86_64 emulation)
# This avoids raw box64 emulation issues — Wine runs natively, only app code is emulated
RUN mkdir -p /tmp/hangover && cd /tmp/hangover && \
    wget -q "https://github.com/AndreRH/hangover/releases/download/hangover-11.0/hangover_11.0_ubuntu2204_jammy_arm64.tar" \
        -O hangover.tar && \
    tar xf hangover.tar && \
    apt-get update && \
    apt-get install -y -f ./hangover*.deb && \
    rm -rf /tmp/hangover /var/lib/apt/lists/* && \
    echo "Hangover Wine installed: $(wine --version)"

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

WORKDIR /opt/mt5

ENTRYPOINT ["/entrypoint.sh"]
