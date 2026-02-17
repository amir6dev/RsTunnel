<p align="center">
  <img src="https://img.shields.io/badge/PicoTun-v2.4.0-blue?style=for-the-badge" alt="Version"/>
  <img src="https://img.shields.io/badge/Go-1.21+-00ADD8?style=for-the-badge&logo=go" alt="Go"/>
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License"/>
  <img src="https://img.shields.io/badge/Platform-Linux-FCC624?style=for-the-badge&logo=linux" alt="Linux"/>
</p>

# 🔒 PicoTun

**High-performance encrypted reverse tunnel with DPI bypass, multi-IP failover, and HTTP mimicry.**

PicoTun creates secure tunnels between servers, forwarding TCP and UDP traffic through encrypted channels that are disguised as normal HTTP/HTTPS traffic. It is specifically designed to bypass Deep Packet Inspection (DPI) firewalls.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| **DPI Bypass** | HTTP/HTTPS mimicry with realistic headers, cookies, and chunked encoding |
| **Multi-IP Failover** | If the primary IP is blocked, automatically switches to backup IPs |
| **AES-256-GCM Encryption** | Military-grade encryption with per-session key derivation |
| **Multiplexed Connections** | smux-based session multiplexing over a single TCP connection |
| **TLS Fingerprint** | uTLS Chrome 120 fingerprint to avoid TLS-based detection |
| **ClientHello Fragmentation** | Splits TLS handshake to evade SNI-based blocking |
| **Traffic Obfuscation** | Random padding and timing to prevent traffic analysis |
| **Connection Pool** | Maintains multiple parallel sessions for reliability and speed |
| **TCP + UDP Forwarding** | Forward any TCP or UDP port through the tunnel |
| **Performance Profiles** | 5 built-in profiles optimized for different use cases |
| **Auto-Reconnect** | Automatic reconnection with exponential backoff |
| **Decoy Server** | Responds with realistic nginx pages to non-tunnel requests |

---

## 🏗️ Architecture

```
┌──────────────────┐         ┌──────────────────┐
│   Iran Server    │         │  Kharej Client   │
│   (picotun)      │◄────────│  (picotun)       │
│                  │  smux   │                  │
│  :2020 tunnel    │  over   │  connects to     │
│  :2222 → SSH     │  HTTP   │  Iran:2020       │
│  :3389 → RDP     │  mimic  │                  │
└──────────────────┘         └──────────────────┘
         │                            │
    Accepts local                Dials local
    connections on               targets for
    mapped ports                 reverse streams
```

**How it works:**
1. **Client (Kharej)** connects to **Server (Iran)** over an HTTP-mimicked tunnel
2. The connection looks like a normal WebSocket upgrade to DPI systems
3. All data is encrypted with AES-256-GCM and multiplexed with smux
4. The server opens local ports and forwards traffic through the tunnel to the client
5. The client dials local targets (e.g., localhost:22) and relays data back

---

## 📦 Quick Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

The interactive setup wizard will guide you through:
- Choosing server or client mode
- Setting the PSK (pre-shared key)
- Selecting transport (httpmux, httpsmux, tcpmux)
- Configuring port mappings
- Choosing a performance profile
- Setting up backup IPs (optional)

---

## 🔧 Manual Configuration

### Server (Iran)

```yaml
mode: "server"
listen: "0.0.0.0:2020"
transport: "httpmux"
psk: "your-secret-key"
profile: "speed"
verbose: true
heartbeat: 2

maps:
  - type: tcp
    bind: "0.0.0.0:2222"
    target: "127.0.0.1:22"
  - type: tcp
    bind: "0.0.0.0:3389"
    target: "127.0.0.1:3389"
  - type: udp
    bind: "0.0.0.0:1194"
    target: "127.0.0.1:1194"

smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  cleanup_interval: 1
  connection_timeout: 20
  stream_timeout: 45
  max_connections: 300

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
```

### Client (Kharej)

```yaml
mode: "client"
psk: "your-secret-key"
transport: "httpmux"
profile: "speed"
verbose: true
heartbeat: 2

paths:
  - transport: "httpmux"
    addr: "IRAN_SERVER_IP:2020"
    connection_pool: 4
    retry_interval: 2
    dial_timeout: 10

smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  connection_timeout: 20

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
```

---

## 🔄 Multi-IP Failover

If the primary server IP gets blocked, PicoTun automatically switches to backup IPs.

### Client config with backup IPs:

```yaml
paths:
  - transport: "httpmux"
    addr: "1.2.3.4:2020"          # Primary server
    connection_pool: 4
    retry_interval: 2
    dial_timeout: 10

  - transport: "httpmux"
    addr: "5.6.7.8:2020"          # Backup server 1
    connection_pool: 4
    retry_interval: 3
    dial_timeout: 10

  - transport: "httpmux"
    addr: "9.10.11.12:2020"       # Backup server 2
    connection_pool: 4
    retry_interval: 3
    dial_timeout: 10
```

**How failover works:**
- Each connection pool worker starts on path[0]
- After **3 consecutive short-lived failures** (<30s), it switches to the next path
- If a connection lived >30s before dying, it retries the same path (normal lifecycle)
- After all paths are exhausted, it backs off for 10 seconds and starts over

---

## ⚡ Performance Profiles

Choose a profile based on your use case:

| Profile | Pool | Retry | Timeout | Buffers | Best For |
|---------|------|-------|---------|---------|----------|
| **speed** | 4 | 2s | 10s | 512KB | Downloads, general high-speed |
| **balanced** | 3 | 3s | 10s | 512KB | Mixed usage (default) |
| **gaming** | 4 | 1s | 5s | 512KB | Online games, low latency |
| **streaming** | 3 | 2s | 10s | 1MB | Video/audio streaming |
| **lowcpu** | 2 | 5s | 15s | 256KB | Low-end servers, VPS |

> **Note:** All profiles maintain DPI-safe settings (frame_size=2KB, small TCP buffers). Profiles only vary pool size, retry intervals, and memory buffers.

---

## 🛡️ Transport Modes

| Transport | Description | DPI Bypass | TLS |
|-----------|-------------|------------|-----|
| `httpmux` | HTTP mimicry + smux multiplexing | ✅ | ❌ |
| `httpsmux` | HTTPS mimicry + smux + uTLS | ✅✅ | ✅ |
| `wsmux` | WebSocket + smux | ✅ | ❌ |
| `wssmux` | WebSocket + smux + uTLS | ✅✅ | ✅ |
| `tcpmux` | Raw TCP + smux | ❌ | ❌ |

**Recommended:** `httpmux` for most cases. Use `httpsmux` if your ISP does deep TLS inspection.

---

## 🛠️ Service Management

```bash
# Start/Stop/Restart
systemctl start picotun-server
systemctl stop picotun-client
systemctl restart picotun-server

# View logs
journalctl -u picotun-server -f
journalctl -u picotun-client -f

# Check status
systemctl status picotun-server
systemctl status picotun-client

# Edit config
nano /etc/picotun/server.yaml
nano /etc/picotun/client.yaml
```

---

## 📊 Monitoring

PicoTun logs provide real-time insight into connection status:

```
[SERVER] listening on 0.0.0.0:2020  tunnel=/search  profile=speed
[SESSION] new from 185.x.x.x:54321 (pool: 4)
[RTCP] 0.0.0.0:2222 → client → 127.0.0.1:22
[HEALTH] pool: 8 alive, 0 removed
```

```
[CLIENT] pool=4 paths=2 profile=speed
[CLIENT]   path[0]: 37.x.x.x:2020 (httpmux)
[CLIENT]   path[1]: 185.x.x.x:2020 (httpmux)
[POOL#0] connected to 37.x.x.x:2020 (pool: 4)
[POOL#1] connected to 37.x.x.x:2020 (pool: 4)
```

---

## 🔐 Security

- **Encryption:** AES-256-GCM with HKDF key derivation from PSK
- **Authentication:** PSK-based — only clients with the correct key can connect
- **Traffic Obfuscation:** Random padding (8-32 bytes) added to every packet
- **TLS Fingerprint:** uTLS mimics Chrome 120 ClientHello
- **Decoy Server:** Non-tunnel requests receive realistic nginx responses
- **No Plaintext:** PSK is never transmitted — only used for key derivation

---

## 📋 Requirements

- **OS:** Linux (Ubuntu 20.04+, Debian 11+, CentOS 8+)
- **Architecture:** amd64, arm64
- **Ports:** One open port on the server (default: 2020)
- **Memory:** ~20MB per connection pool
- **CPU:** Minimal (AES-NI hardware acceleration supported)

---

## 🔨 Build from Source

```bash
git clone https://github.com/amir6dev/PicoTun.git
cd PicoTun

# Generate go.sum
go mod tidy

# Build
CGO_ENABLED=0 go build -ldflags="-s -w" -o picotun ./cmd/picotun/

# Run
./picotun -c /etc/picotun/server.yaml
```

---

## 📝 Configuration Reference

### Top-Level Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mode` | string | - | `server` or `client` |
| `listen` | string | `0.0.0.0:2020` | Server listen address |
| `transport` | string | `httpmux` | Transport protocol |
| `psk` | string | - | Pre-shared key (must match) |
| `profile` | string | `balanced` | Performance profile |
| `verbose` | bool | `false` | Enable verbose logging |
| `heartbeat` | int | `2` | Heartbeat interval (seconds) |

### Path Options (Client)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `addr` | string | - | Server address (IP:Port) |
| `connection_pool` | int | `4` | Number of parallel sessions |
| `retry_interval` | int | `3` | Reconnect interval (seconds) |
| `dial_timeout` | int | `10` | Connection timeout (seconds) |

### SMUX Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `keepalive` | int | `1` | Keepalive interval (seconds) |
| `max_recv` | int | `524288` | Max receive buffer (bytes) |
| `frame_size` | int | `2048` | Max frame size (bytes) ⚠️ |

> ⚠️ **Warning:** Do NOT increase `frame_size` above 2048. Larger frames trigger DPI detection. The default 2KB mimics normal HTTP chunk sizes.

---

## ❓ Troubleshooting

**Connection dies after ~4 minutes:**
- Ensure `frame_size: 2048` (not 32768)
- Ensure `keepalive: 1` (not 10)
- These are the most critical DPI-bypass settings

**"all N sessions failed" errors:**
- Check that PSK matches on both sides
- Check that transport matches on both sides
- Verify server is reachable: `curl -I http://SERVER_IP:PORT`

**High EOF count with multiple clients:**
- This is normal when multiple kharej servers connect simultaneously
- PicoTun v2.4 handles this gracefully without log spam
- Ensure all clients use the same PSK and transport

**IP blocked but ping works:**
- This means DPI is blocking the tunnel protocol, not the IP
- Try changing the transport (httpmux → httpsmux)
- Add a backup IP in the client config

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <b>PicoTun</b> — Tunneling done right.
</p>
