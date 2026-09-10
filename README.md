# Tor and Privoxy Proxy Container

[![Build Status](https://github.com/ays7/torproxy/actions/workflows/image.yaml/badge.svg)](https://github.com/ays7/torproxy/actions/workflows/image.yaml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Container Registry](https://img.shields.io/badge/ghcr.io-ays7%2Ftorproxy-blue?logo=github)](https://ghcr.io/ays7/torproxy)

A modernized, lightweight Docker container running **Tor** (SOCKS5 and DNS proxy) and **Privoxy** (HTTP/HTTPS proxy routing into Tor).

> [!NOTE]
> This repository is a modernized and actively maintained fork by **[ays7](https://github.com/ays7/torproxy)**, originally created by [David Personette (dperson)](https://github.com/dperson/torproxy).

---

## Key Features & Modernizations

* **Alpine 3.21 Base**: Minimal footprint, security updates, and modern OpenSSL 3.x stack.
* **Tor 0.4.8+ LTS**: Native support for modern Tor features, congestion control, and v3 Onion services.
* **Dual-Process Supervision**: Privoxy and Tor run under a native process supervisor with graceful signal handling (`SIGTERM`/`SIGINT`) and fail-fast crash monitoring via `wait -n`.
* **Local, Privacy-Preserving Healthcheck**: Periodically verifies local listeners (HTTP `8118` and SOCKS5 `9050`) rather than leaking exit traffic or hitting third-party websites.
* **Hardened Security**:
  * Safe argument and hidden service parsing (eliminated shell `eval` injection risks).
  * Specification-compliant Tor Control cookie authentication using 64-character hexadecimal encoding.
  * Direct data directory permission enforcement (`0700` on `/var/lib/tor`).
* **Multi-Architecture**: Built natively for `linux/amd64` and `linux/arm64` via Docker Buildx and GitHub Container Registry (`ghcr.io/ays7/torproxy`).

---

## Exposed Ports

| Port | Protocol | Service | Description |
| :--- | :--- | :--- | :--- |
| `8118` | TCP | Privoxy HTTP | HTTP/HTTPS web proxy that routes all non-local traffic through Tor |
| `9050` | TCP | Tor SOCKS5 | SOCKS5 proxy (`IsolateDestAddr` enabled for stream isolation) |
| `9051` | TCP | Tor Control | Tor control port (accessible with password or cookie auth) |

---

## Quick Start

### Running with Docker CLI

```bash
docker run -d \
  --name torproxy \
  -p 8118:8118 \
  -p 9050:9050 \
  --restart unless-stopped \
  ghcr.io/ays7/torproxy:latest
```

### Testing the Proxy

**Test Privoxy (HTTP Proxy):**
```bash
curl -x http://localhost:8118 https://check.torproject.org/api/ip
```

**Test Tor (SOCKS5 Proxy):**
```bash
curl --socks5-hostname localhost:9050 https://check.torproject.org/api/ip
```

Both commands should return:
```json
{"IsTor":true,"IP":"..."}
```

---

## Docker Compose Example

```yaml
services:
  torproxy:
    image: ghcr.io/ays7/torproxy:latest
    container_name: torproxy
    restart: unless-stopped
    ports:
      - "8118:8118"
      - "9050:9050"
    environment:
      - LOCATION=CH          # Exit in Switzerland (optional)
      - PASSWORD=mysecret    # Enable Tor control port password (optional)
    volumes:
      - tor-data:/var/lib/tor

volumes:
  tor-data:
```

---

## Configuration

### Command-Line Options

You can pass CLI arguments to `torproxy.sh` directly via `docker run`:

```bash
docker run -it --rm ghcr.io/ays7/torproxy:latest -h
```

| Flag | Argument | Description |
| :--- | :--- | :--- |
| `-h` | None | Display usage and help text |
| `-b` | `<kbs>` | Configure Tor relay bandwidth limit in KB/s (burst set to 2x) |
| `-e` | None | Allow exit node traffic (clears `ExitPolicy reject *:*`) |
| `-l` | `<country>` | Restrict Tor exit traffic to specified 2-letter country code (e.g. `US`, `DE`, `CH`) |
| `-n` | None | Request new circuits (`SIGNAL NEWNYM`) via Tor control port and exit |
| `-p` | `<password>` | Set Tor `HashedControlPassword` and expose control port on `0.0.0.0:9051` |
| `-s` | `<port>;<target:port>` | Configure a Tor hidden service (v3 onion service) |

### Environment Variables

| Variable | Example | Description |
| :--- | :--- | :--- |
| `BW` | `100` | Tor relay bandwidth limit in KB/s |
| `EXITNODE` | `1` or `true` | Allow exit node traffic |
| `LOCATION` | `DE` | Force Tor exit nodes in the specified ISO country code |
| `PASSWORD` | `secret123` | Sets `HashedControlPassword` and binds control port to `0.0.0.0:9051` |
| `SERVICE` | `80;web:80` | Forward onion service traffic. Multiple mappings can be comma-separated |
| `TORUSER` | `tor` | Run Tor process as the specified username (default: `tor`) |
| `USERID` | `1000` | Map UID for the `tor` user inside the container |
| `GROUPID` | `1000` | Map GID for the `tor` group inside the container |
| `TZ` | `UTC` | Set the system timezone (e.g. `America/New_York`) |
| `TOR_<Option>` | `TOR_NewCircuitPeriod=400` | Directly inject or override any directive in `torrc` |

---

## Common Use Cases

### 1. Requesting a New Circuit (New Identity)
To request new Tor circuits without restarting the container:
```bash
docker exec torproxy torproxy.sh -n
```

### 2. Restricting Exit Nodes by Country
To force exit traffic through specific countries (e.g., Switzerland or Iceland):
```bash
docker run -d \
  -p 8118:8118 -p 9050:9050 \
  -e LOCATION=CH \
  ghcr.io/ays7/torproxy:latest
```

### 3. Exposing a V3 Onion Service
To route `.onion` requests to an internal web service:
```bash
docker run -d \
  -p 8118:8118 -p 9050:9050 \
  -e SERVICE="80;web-container:8080" \
  -v tor-data:/var/lib/tor \
  ghcr.io/ays7/torproxy:latest
```
On startup, the container automatically generates the ed25519 key and displays your hostname in the logs:
```
==================================================
Tor Hidden Service Hostname: <random56chars>.onion
==================================================
```

### 4. Custom Configuration Files
If you need custom configurations, you can bind-mount your own config files:
```bash
docker run -d \
  -p 8118:8118 -p 9050:9050 \
  -v /path/to/custom-torrc:/etc/tor/torrc:ro \
  -v /path/to/custom-privoxy.conf:/etc/privoxy/config:ro \
  ghcr.io/ays7/torproxy:latest
```

---

## Building Locally

```bash
git clone https://github.com/ays7/torproxy.git
cd torproxy
docker build -t torproxy:local .
```

To build for multiple architectures:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t torproxy:local .
```

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE) for details.