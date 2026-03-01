# =============================================================================
# MT5 Headless on x86_64 (Railway/VPS) using WineHQ Wine
# Standard Wine runs MT5 natively on x86_64 — no emulation needed
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
    x11vnc novnc python3 python3-pip python3-websockify \
    && rm -rf /var/lib/apt/lists/*

# Install WineHQ staging (includes patches to hide debug infrastructure from anti-tamper checks)
RUN dpkg --add-architecture i386 && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources && \
    apt-get update && \
    apt-get install -y --install-recommends winehq-staging && \
    rm -rf /var/lib/apt/lists/*

# Install Python API server dependencies
COPY server/requirements.txt /server/requirements.txt
RUN pip3 install --no-cache-dir -r /server/requirements.txt

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/healthcheck.sh /healthcheck.sh
COPY scripts/backtest.sh /scripts/backtest.sh
COPY scripts/parse_report.py /scripts/parse_report.py
COPY scripts/setup_bridge_chart.py /scripts/setup_bridge_chart.py
COPY scripts/start_bridge_service.sh /scripts/start_bridge_service.sh
COPY server/ /server/
COPY ea/BridgeEA.mq5 /opt/mt5/BridgeEA.mq5
COPY ea/BridgeService.mq5 /opt/mt5/BridgeService.mq5
RUN chmod +x /entrypoint.sh /healthcheck.sh /scripts/backtest.sh /scripts/parse_report.py /scripts/start_bridge_service.sh

EXPOSE 8000
EXPOSE 6080

WORKDIR /opt/mt5

ENTRYPOINT ["/entrypoint.sh"]
