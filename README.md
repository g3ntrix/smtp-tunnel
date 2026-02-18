# smtp-tunnel

Easy installer for tunneling VPN traffic through a middle server using an SMTP-like covert tunnel. Traffic between servers is disguised as a legitimate SMTP email session to bypass Deep Packet Inspection (DPI).

**Current Version:** v1.0.0

## Features

- **Interactive Setup** - Guided installation for both Server A (Iran) and Server B (Abroad)
- **Multi-Tunnel Support** - Connect one Server A to multiple Server Bs with named tunnels
- **Install as Command** - Run `smtp-tunnel` after installing
- **Automatic Reset** - Scheduled service restarts for reliability (configurable interval)
- **Connection Test Tool** - Built-in diagnostics to verify tunnel connectivity
- **DPI Evasion** - Traffic looks like a real SMTP session (EHLO, STARTTLS, AUTH, TLS)
- **Binary Multiplexing** - Multiple TCP connections multiplexed over a single SMTP tunnel
- **Auto-Reconnect** - Relay automatically reconnects on connection loss
- **Firewall Management** - Automatically opens required ports during setup
- **Smart Defaults** - Sensible defaults with easy customization

## Architecture

```text
┌─────────────┐                              ┌─────────────┐
│   Clients   │                              │  Server B   │
│ (v2ray/xray)│                              │  (ABROAD)   │
└──────┬──────┘                              │  xray VPN   │
       │                                     └──────┬──────┘
       │ Connect to                                │
       │ Server A IP                               │ 127.0.0.1:PORT
       ▼                                           ▼
┌──────────────┐      SMTP tunnel (587)      ┌──────────────┐
│  Server A    │◄───────────────────────────►│ SMTP Tunnel  │
│  (IRAN)      │   EHLO/STARTTLS/AUTH/TLS    │   Server     │
│ Entry Point  │                             │  (Server B)  │
└──────────────┘                             └──────────────┘
```

**Servers:**

- **Server A (Iran)**: Entry point server located in Iran - clients connect here
- **Server B (Abroad)**: Your VPN server abroad running xray/V2Ray

**Traffic Flow:**

1. Client connects to Server A on the xray port
2. Server A tunnels traffic through the SMTP tunnel to Server B
3. Server B forwards to local xray (`127.0.0.1:PORT`)
4. Response flows back through the tunnel

## Quick Start

```bash
# Run on both servers (as root)
bash <(curl -fsSL https://raw.githubusercontent.com/g3ntrix/smtp-tunnel/main/install.sh)
```

### Install as Command (Optional)

After running the script, select option **i** to install `smtp-tunnel` as a system command:

```bash
# After installation, you can simply run:
smtp-tunnel
```

## Installation Steps

### Step 1: Setup Server B (Abroad – xray backend)

```bash
ssh root@<SERVER_B_IP>
bash <(curl -fsSL https://raw.githubusercontent.com/g3ntrix/smtp-tunnel/main/install.sh)
```

1. Select option **1** (Setup Server B)
2. Choose SMTP tunnel port (default: `587`)
3. Enter SMTP hostname (any realistic value, e.g. `mail.example.com`)
4. Enter your xray inbound ports
5. Choose a relay username and accept or override the generated secret
6. **Save the username and secret for Server A!**

### Step 2: Setup Server A (Iran – middle relay)

```bash
ssh root@<SERVER_A_IP>
bash <(curl -fsSL https://raw.githubusercontent.com/g3ntrix/smtp-tunnel/main/install.sh)
```

1. Select option **2** (Setup Server A)
2. Enter a **tunnel name** (e.g. `uk1`, `usa`, `france`)
3. Enter **Server B IP/domain** and SMTP tunnel port
4. Enter the **username** and **secret** from Step 1
5. Optionally set TLS server name (leave empty for default)
6. Enter client-facing ports on Server A (comma-separated)
7. For each port, confirm the target xray port on Server B

### Typical Setup Example

For a simple setup where xray runs on port `8080` on Server B:

| Prompt | Value |
|--------|-------|
| Tunnel name | `<TUNNEL_NAME>` |
| Server B IP | `<SERVER_B_IP>` |
| Server B SMTP tunnel port | `587` |
| Username | `<USERNAME>` |
| Secret | *(paste from Server B)* |
| TLS server name | *(leave empty)* |
| Client-facing ports on A | `8080` |
| Target xray port on B for 8080 | `8080` |

After setup, clients connect to **Server A** on port `8080` with their normal xray config.

### Step 3: Point Clients to Server A

```text
# Before (direct abroad):
vless://uuid@<SERVER_B_IP>:8080?type=tcp&encryption=none&security=none#vpn

# After (through Server A):
vless://uuid@<SERVER_A_IP>:8080?type=tcp&encryption=none&security=none#vpn
```

Only the IP changes; everything else stays the same.

## Important: xray Inbound Configuration

On **Server B**, your xray inbound **MUST** listen on `0.0.0.0` (all interfaces), not just the public IP.

In X-UI Panel:

1. Go to **Inbounds** → Edit your inbound
2. Set **Listen IP** to: `0.0.0.0`
3. Save and restart xray

This is required because the tunnel forwards traffic to `127.0.0.1:PORT`.

## Menu Options

```text
── Setup ──
1) Setup Server B (abroad backend)
2) Setup Server A (iran middle relay)
a) Show architecture

── Management ──
3) Check status
4) View configuration
5) Edit configuration
6) Manage tunnels (add/remove/restart)
7) Test connection

── Maintenance ──
8) Check for updates
9) Automatic reset (scheduled restart)
u) Uninstall

── Script ──
i) Install as command
r) Remove command
h) Donate / Support project
0) Exit
```

### Test Connection (Option 7)

Built-in diagnostics that automatically detect your server role and run appropriate tests:

**Server B tests:**
- Service status check
- SMTP tunnel port listening verification
- TLS certificate validity
- Recent activity logs
- External connectivity

**Server A tests:**
- Service status check
- TCP connectivity to Server B SMTP port
- Client-facing port listening verification
- Recent tunnel activity logs
- End-to-end tunnel test

### Automatic Reset (Option 9)

Periodically restart tunnel services for reliability:

- Configurable interval: 1/3/6/12 hours, 1 day, or 7 days
- Enable/disable toggle
- Manual reset (restart all tunnels immediately)
- Uses systemd timers for reliable scheduling

### Manage Tunnels (Option 6)

- Add new relay tunnels on Server A (multiple Server B backends)
- Remove a selected tunnel (stops service + removes config)
- Restart a selected tunnel
- View logs for a selected tunnel

## Commands

```bash
# Server B
systemctl status smtp-tunnel-server
journalctl -u smtp-tunnel-server -f
cat /opt/smtp-tunnel/server.yaml

# Server A (replace <name> with tunnel name)
systemctl status smtp-tunnel-relay-<name>
journalctl -u smtp-tunnel-relay-<name> -f
cat /opt/smtp-tunnel/client-<name>.yaml
```

## Requirements

- Linux server (Ubuntu, Debian, CentOS, etc.)
- Root access
- Python 3.8+ (auto-installed)
- `openssl`, `curl`, `lsof`

## How the SMTP Tunnel Works

| Feature | Description |
|---------|-------------|
| **SMTP Handshake** | Mimics real Postfix SMTP (EHLO, 250-STARTTLS, AUTH) |
| **STARTTLS** | Upgrades to TLS 1.2+ — all subsequent data encrypted |
| **Authentication** | HMAC-SHA256 with timestamp, per-user secrets |
| **Binary Multiplexing** | After AUTH, switches to compact binary framing (5-byte overhead per frame) |
| **Auto-Reconnect** | Relay reconnects automatically with exponential backoff |

## Troubleshooting

**Client timeout:**
- Verify Server A firewall allows client-facing ports (`ufw status`)
- Verify Server A cloud firewall allows the same ports
- Check relay service: `journalctl -u smtp-tunnel-relay-<name> -f`

**Authentication failed:**
- Verify username and secret match between Server A config and Server B users.yaml
- Check server time is accurate (within 5 minutes)

**Service not starting:**
- Check logs: `journalctl -u smtp-tunnel-server -n 50` or `journalctl -u smtp-tunnel-relay-<name> -n 50`
- Verify config: `cat /opt/smtp-tunnel/server.yaml` or `cat /opt/smtp-tunnel/client-<name>.yaml`

**Clients can't connect:**
- Verify xray inbound listens on `0.0.0.0`
- Verify both servers' firewalls allow the required ports
- Use **Test Connection** (option 7) to diagnose

## Credits

- SMTP tunnel protocol and multiplexing based on [`smtp-tunnel-proxy`](https://github.com/x011/smtp-tunnel-proxy) by **x011**
- Created by [g3ntrix](https://github.com/g3ntrix)

## License

MIT License

## Donations

If this project helps your setup, donations are appreciated:

- **TON**: `UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx`
- **USDT (BEP20)**: `0x71F41696c60C4693305e67eE3Baa650a4E3dA796`

Send only TON to the TON address, and USDT on BEP20 network to the BEP20 address.
