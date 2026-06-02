# twin-server

Twin protocol server implementation. Based on reverse-engineered nowhere protocol ? optimized for high-throughput, low-QoS proxy over UDP.

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh)
```

This will:
- Download the latest binary for your architecture
- Create `twin` user
- Generate a self-signed TLS certificate
- Generate a random auth password
- Write config to `/etc/twin-server/config.conf`
- Install systemd service

After install, start the service:

```bash
systemctl start twin-server
systemctl enable twin-server
systemctl status twin-server -l
journalctl -u twin-server -f
```

## Manual Setup

If you want to customize everything manually:

### 1. Generate certificate

```bash
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 36500 -keyout /etc/twin-server/server.key \
  -out /etc/twin-server/server.crt \
  -subj "/CN=bing.com" && \
  chown twin /etc/twin-server/server.key && \
  chown twin /etc/twin-server/server.crt
```

### 2. Create config

`/etc/twin-server/config.conf`:

```ini
listen = :8443
password = your-password
cert = /etc/twin-server/server.crt
key = /etc/twin-server/server.key
```

### 3. Start

```bash
twin-server -conf /etc/twin-server/config.conf
```

Or using the command-line flags directly:

```bash
twin-server -listen :8443 -password your-password -cert server.crt -key server.key
```

## Systemd Service

The install script creates a systemd service. Manage it with:

```bash
systemctl start twin-server       # Start
systemctl stop twin-server        # Stop
systemctl enable twin-server      # Enable on boot
systemctl restart twin-server     # Restart
systemctl status twin-server -l   # Status + logs
journalctl -u twin-server -f      # Follow logs
```

## Remove

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh) --remove
```

Or manually:

```bash
systemctl stop twin-server
systemctl disable twin-server
rm /usr/local/bin/twin-server
rm /etc/systemd/system/twin-server.service
systemctl daemon-reload
rm -rf /etc/twin-server
userdel -r twin
```

## Clash Client Config

```yaml
- name: "twin"
  type: twin
  server: your-server.com
  port: 8443
  password: your-password
  sni: bing.com
  skip-cert-verify: true
  up: "100 Mbps"
  down: "200 Mbps"
  side-channel: true
  side-strategy: auto
```

## Build from Source

```bash
git clone https://github.com/condercx/twin-server.git
cd twin-server
go build -o twin-server .
```

## Version

```bash
twin-server -version
```
