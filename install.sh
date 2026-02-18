#!/bin/bash
#===============================================================================
#  SMTP Tunnel Installer
#  client -> v2ray/xray on Server A -> SMTP tunnel -> Server B xray inbound
#===============================================================================

set -e

INSTALLER_VERSION="1.0.0"
INSTALL_DIR="/opt/smtp-tunnel"
INSTALLER_CMD="/usr/local/bin/smtp-tunnel"
GITHUB_REPO="g3ntrix/smtp-tunnel"

# Donations
DONATE_TON="UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx"
DONATE_USDT_BEP20="0x71F41696c60C4693305e67eE3Baa650a4E3dA796"

SERVER_CONFIG="$INSTALL_DIR/server.yaml"
USERS_FILE="$INSTALL_DIR/users.yaml"
CERT_FILE="$INSTALL_DIR/server.crt"
KEY_FILE="$INSTALL_DIR/server.key"
SERVER_SERVICE="smtp-tunnel-server"

DEFAULT_SERVER_PORT="587"
DEFAULT_HOSTNAME="mail.example.com"
DEFAULT_XRAY_PORTS="8080"
DEFAULT_CLIENT_PORTS="8080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_banner_line() {
    printf "║ %-45s ║\n" "$1"
}

print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════╗"
    print_banner_line ""
    print_banner_line "███████╗███╗   ███╗████████╗██████╗          "
    print_banner_line "██╔════╝████╗ ████║╚══██╔══╝██╔══██╗         "
    print_banner_line "███████╗██╔████╔██║   ██║   ██████╔╝         "
    print_banner_line "╚════██║██║╚██╔╝██║   ██║   ██╔═══╝          "
    print_banner_line "███████║██║ ╚═╝ ██║   ██║   ██║              "
    print_banner_line "╚══════╝╚═╝     ╚═╝   ╚═╝   ╚═╝              "
    print_banner_line ""
    print_banner_line "SMTP Tunnel Relay"
    print_banner_line "Version: v${INSTALLER_VERSION}"
    print_banner_line "by g3ntrix | github.com/g3ntrix"
    print_banner_line ""
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_donate_info() {
    print_banner
    echo -e "${YELLOW}Support smtp-tunnel${NC}"
    echo -e "${CYAN}If this project helps your setup, donations are appreciated.${NC}"
    echo ""
    echo -e "${GREEN}TON:${NC}"
    echo -e "  ${CYAN}${DONATE_TON}${NC}"
    echo ""
    echo -e "${GREEN}USDT (BEP20):${NC}"
    echo -e "  ${CYAN}${DONATE_USDT_BEP20}${NC}"
    echo ""
    print_info "Send only TON to TON address and USDT on BEP20 network to the BEP20 address."
}

print_step()    { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${CYAN}[i]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        uname -s | tr '[:upper:]' '[:lower:]'
    fi
}

read_required() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -p "> " value < /dev/tty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        if [ -n "$value" ]; then
            eval "$varname='$value'"
            return 0
        fi
        print_error "Value is required."
    done
}

read_optional() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    if [ -n "$default" ]; then
        echo -e "${YELLOW}${prompt} [${default}]:${NC}"
    else
        echo -e "${YELLOW}${prompt} (optional):${NC}"
    fi
    read -p "> " value < /dev/tty
    if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
    fi
    eval "$varname='$value'"
}

read_confirm() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    while true; do
        if [ "$default" = "y" ]; then
            echo -e "${YELLOW}${prompt} (Y/n):${NC}"
        elif [ "$default" = "n" ]; then
            echo -e "${YELLOW}${prompt} (y/N):${NC}"
        else
            echo -e "${YELLOW}${prompt} (y/n):${NC}"
        fi
        read -p "> " value < /dev/tty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        case "$value" in
            [Yy]|[Yy][Ee][Ss]) eval "$varname=true"; return 0 ;;
            [Nn]|[Nn][Oo]) eval "$varname=false"; return 0 ;;
            *) print_error "Enter y or n." ;;
        esac
    done
}

read_ip_or_domain() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -p "> " value < /dev/tty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        if [ -n "$value" ]; then
            eval "$varname='$value'"
            return 0
        fi
        print_error "Value is required."
    done
}

read_port() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -p "> " value < /dev/tty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            print_error "Port must be numeric."
            continue
        fi
        if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
            print_error "Port must be between 1 and 65535."
            continue
        fi
        eval "$varname='$value'"
        return 0
    done
}

read_ports() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -p "> " value < /dev/tty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        if [ -z "$value" ]; then
            print_error "At least one port is required."
            continue
        fi
        local valid=true
        IFS=',' read -ra ports <<< "$value"
        for p in "${ports[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                print_error "Invalid port: $p"
                valid=false
                break
            fi
        done
        if [ "$valid" = true ]; then
            eval "$varname='$value'"
            return 0
        fi
    done
}

read_tunnel_name() {
    local prompt="$1"
    local varname="$2"
    local value=""
    local name_regex='^[a-z0-9][a-z0-9-]*$'
    while true; do
        echo -e "${YELLOW}${prompt}:${NC}"
        echo -e "${CYAN}(lowercase letters/numbers/hyphens)${NC}"
        read -p "> " value < /dev/tty
        if [ -z "$value" ]; then
            print_error "Tunnel name is required."
            continue
        fi
        if ! [[ "$value" =~ $name_regex ]]; then
            print_error "Invalid name format."
            continue
        fi
        if [ -f "$INSTALL_DIR/client-${value}.yaml" ]; then
            print_error "Tunnel '$value' already exists."
            continue
        fi
        eval "$varname='$value'"
        return 0
    done
}

check_port_conflict() {
    local port="$1"
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        print_warning "Port $port is already in use."
        local pid
        pid=$(lsof -t -i:"$port" 2>/dev/null | head -1 || true)
        if [ -n "$pid" ]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || true)
            print_info "Used by: $pname (PID $pid)"
        fi
        read_confirm "Continue anyway?" cont "n"
        [ "$cont" = true ] || return 1
    fi
    return 0
}

open_firewall_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 && print_success "Opened ${port}/tcp in ufw"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        print_success "Opened ${port}/tcp in firewalld"
    else
        print_info "No local firewall tool detected. Open port ${port}/tcp manually if needed."
    fi
}

install_dependencies() {
    print_step "Installing dependencies..."
    local os
    os=$(detect_os)
    case "$os" in
        ubuntu|debian)
            timeout 30 apt update -qq >/dev/null 2>&1 || true
            apt install -y -qq python3 python3-pip openssl curl lsof >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y -q python3 python3-pip openssl curl lsof >/dev/null 2>&1
            ;;
        *)
            print_warning "Unknown OS ($os). Install python3, pip, openssl, curl manually."
            ;;
    esac
    print_success "Dependencies installed."
}

install_runtime_files() {
    mkdir -p "$INSTALL_DIR"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local files=("smtp_server.py" "smtp_relay.py" "common.py" "requirements.txt")
    local missing=0

    for f in "${files[@]}"; do
        if [ -f "$script_dir/$f" ]; then
            cp "$script_dir/$f" "$INSTALL_DIR/$f"
        else
            missing=1
        fi
    done

    if [ "$missing" -eq 1 ]; then
        print_step "Downloading runtime files from GitHub..."
        for f in "${files[@]}"; do
            curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/${f}" -o "$INSTALL_DIR/$f"
        done
    fi

    chmod +x "$INSTALL_DIR/smtp_server.py" "$INSTALL_DIR/smtp_relay.py"

    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        pip3 install -q -r "$INSTALL_DIR/requirements.txt" 2>/dev/null || true
    fi

    print_success "Runtime files installed in $INSTALL_DIR"
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        date +%s%N | sha256sum | cut -c1-48
    fi
}

generate_cert() {
    local cn="$1"
    print_step "Generating TLS certificate..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE" >/dev/null 2>&1
    openssl req -new -x509 -key "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=${cn}" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    print_success "Certificate generated: $CERT_FILE (CN=$cn)"
}

create_server_service() {
    cat > "/etc/systemd/system/${SERVER_SERVICE}.service" << EOF
[Unit]
Description=SMTP Tunnel Server (Server B)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/smtp_server.py --config ${SERVER_CONFIG} --users ${USERS_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

create_relay_service() {
    local tunnel_name="$1"
    local config_file="$2"
    local service_name="smtp-tunnel-relay-${tunnel_name}"
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=SMTP Tunnel Relay ${tunnel_name} - Server A
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/smtp_relay.py --config ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

setup_server_b() {
    print_banner
    echo -e "${GREEN}Setup Server B (Outside Iran)${NC}"
    echo -e "${CYAN}This runs SMTP tunnel server and forwards to local xray ports.${NC}"
    echo ""

    install_dependencies
    install_runtime_files

    local tunnel_port
    local hostname
    local xray_ports
    local username
    local secret

    read_port "SMTP tunnel listen port on Server B" tunnel_port "$DEFAULT_SERVER_PORT"
    check_port_conflict "$tunnel_port" || return 0
    read_required "SMTP advertised hostname (any value)" hostname "$DEFAULT_HOSTNAME"
    read_ports "Local xray inbound ports on Server B (comma-separated)" xray_ports "$DEFAULT_XRAY_PORTS"
    read_required "Relay username for Server A" username "relay-a"

    secret=$(generate_secret)
    echo -e "${CYAN}Generated secret:${NC} ${YELLOW}${secret}${NC}"
    read_required "Relay secret (enter to keep generated)" secret "$secret"

    mkdir -p "$INSTALL_DIR"
    generate_cert "$hostname"

    cat > "$SERVER_CONFIG" << EOF
server:
  host: "0.0.0.0"
  port: ${tunnel_port}
  hostname: "${hostname}"
  cert_file: "${CERT_FILE}"
  key_file: "${KEY_FILE}"
  users_file: "${USERS_FILE}"
EOF

    cat > "$USERS_FILE" << EOF
users:
  ${username}:
    secret: "${secret}"
    logging: true
EOF

    create_server_service
    systemctl enable --now "$SERVER_SERVICE"

    read_confirm "Open tunnel port ${tunnel_port}/tcp in local firewall?" open_fw "y"
    if [ "$open_fw" = true ]; then
        open_firewall_port "$tunnel_port"
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                 Server B Ready                             ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}Tunnel Port:${NC}    ${CYAN}${tunnel_port}${NC}"
    echo -e "  ${YELLOW}Hostname:${NC}       ${CYAN}${hostname}${NC}"
    echo -e "  ${YELLOW}xray Ports:${NC}     ${CYAN}${xray_ports}${NC}"
    echo ""
    echo -e "${YELLOW}Use these on Server A:${NC}"
    echo -e "  Username: ${CYAN}${username}${NC}"
    echo -e "  Secret:   ${CYAN}${secret}${NC}"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  Status:  ${CYAN}systemctl status ${SERVER_SERVICE}${NC}"
    echo -e "  Logs:    ${CYAN}journalctl -u ${SERVER_SERVICE} -f${NC}"
}

setup_server_a() {
    print_banner
    echo -e "${GREEN}Setup Server A (Iran)${NC}"
    echo -e "${CYAN}Clients connect to A, A relays to B over SMTP tunnel.${NC}"
    echo ""

    install_dependencies
    install_runtime_files

    local tunnel_name
    local server_b_host
    local server_b_port
    local username
    local secret
    local tls_server_name
    local client_ports

    read_tunnel_name "Tunnel name" tunnel_name
    read_ip_or_domain "Server B IP/domain" server_b_host
    read_port "Server B SMTP tunnel port" server_b_port "$DEFAULT_SERVER_PORT"
    read_required "Relay username (from Server B)" username
    read_required "Relay secret (from Server B)" secret
    read_optional "TLS server name/SNI (optional)" tls_server_name ""
    read_ports "Client-facing ports on Server A (comma-separated)" client_ports "$DEFAULT_CLIENT_PORTS"

    IFS=',' read -ra cports <<< "$client_ports"
    local forwards_yaml=""
    for cp in "${cports[@]}"; do
        cp=$(echo "$cp" | tr -d ' ')
        check_port_conflict "$cp" || return 0
        local target_port
        read_port "Target xray port on Server B for local port ${cp}" target_port "$cp"
        forwards_yaml="${forwards_yaml}
  - listen: \"0.0.0.0:${cp}\"
    target_host: \"127.0.0.1\"
    target_port: ${target_port}"
    done

    local config_file="$INSTALL_DIR/client-${tunnel_name}.yaml"
    cat > "$config_file" << EOF
client:
  server_host: "${server_b_host}"
  server_port: ${server_b_port}
  username: "${username}"
  secret: "${secret}"
  tls_server_name: "${tls_server_name}"
  ca_cert: ""
forwards:${forwards_yaml}
EOF

    create_relay_service "$tunnel_name" "$config_file"
    local service_name="smtp-tunnel-relay-${tunnel_name}"
    systemctl enable --now "$service_name"

    read_confirm "Open client-facing ports (${client_ports}) in local firewall?" open_fw "y"
    if [ "$open_fw" = true ]; then
        for cp in "${cports[@]}"; do
            cp=$(echo "$cp" | tr -d ' ')
            open_firewall_port "$cp"
        done
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}             Server A Tunnel '${tunnel_name}' Ready         ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}Server B:${NC}       ${CYAN}${server_b_host}:${server_b_port}${NC}"
    echo -e "  ${YELLOW}Client Ports:${NC}   ${CYAN}${client_ports}${NC}"
    echo ""
    echo -e "${YELLOW}v2ray clients should connect to Server A on:${NC} ${CYAN}${client_ports}${NC}"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  Status:  ${CYAN}systemctl status ${service_name}${NC}"
    echo -e "  Logs:    ${CYAN}journalctl -u ${service_name} -f${NC}"
}

get_all_configs() {
    if [ -f "$SERVER_CONFIG" ]; then
        echo "$SERVER_CONFIG"
    fi
    for f in "$INSTALL_DIR"/client-*.yaml; do
        [ -f "$f" ] && echo "$f"
    done
}

get_tunnel_name() {
    local file
    file=$(basename "$1")
    if [ "$file" = "server.yaml" ]; then
        echo "server"
    else
        echo "$file" | sed 's/^client-//; s/\.yaml$//'
    fi
}

get_service_name() {
    local name
    name=$(get_tunnel_name "$1")
    if [ "$name" = "server" ]; then
        echo "$SERVER_SERVICE"
    else
        echo "smtp-tunnel-relay-${name}"
    fi
}

list_tunnels() {
    local cfgs
    cfgs=$(get_all_configs)
    if [ -z "$cfgs" ]; then
        print_info "No setup found."
        return 1
    fi
    local idx=0
    while IFS= read -r cf; do
        idx=$((idx + 1))
        local name svc status role
        name=$(get_tunnel_name "$cf")
        svc=$(get_service_name "$cf")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="${GREEN}Running${NC}"
        else
            status="${RED}Stopped${NC}"
        fi
        if [ "$name" = "server" ]; then
            role="Server B (Outside Iran)"
        else
            role="Server A (Iran)"
        fi
        echo -e "  ${CYAN}${idx})${NC} ${YELLOW}${name}${NC} [${status}] (${role})"
    done <<< "$cfgs"
}

select_tunnel() {
    local cfgs count choice
    cfgs=$(get_all_configs)
    if [ -z "$cfgs" ]; then
        print_error "No tunnels configured."
        return 1
    fi
    count=$(echo "$cfgs" | wc -l)
    if [ "$count" -eq 1 ]; then
        SELECTED_CONFIG=$(echo "$cfgs" | head -1)
        SELECTED_SERVICE=$(get_service_name "$SELECTED_CONFIG")
        return 0
    fi
    list_tunnels
    echo ""
    read -p "Choice: " choice < /dev/tty
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        print_error "Invalid choice."
        return 1
    fi
    SELECTED_CONFIG=$(echo "$cfgs" | sed -n "${choice}p")
    SELECTED_SERVICE=$(get_service_name "$SELECTED_CONFIG")
    return 0
}

check_status() {
    print_banner
    echo -e "${GREEN}Tunnel Status${NC}"
    echo ""
    list_tunnels || return
    echo ""
    while IFS= read -r cf; do
        local svc name
        svc=$(get_service_name "$cf")
        name=$(get_tunnel_name "$cf")
        echo -e "${YELLOW}── ${name} ──${NC}"
        systemctl status "$svc" --no-pager -l 2>/dev/null | sed -n '1,12p'
        echo ""
    done <<< "$(get_all_configs)"
}

view_config() {
    print_banner
    echo -e "${GREEN}View Configuration${NC}"
    echo ""
    local cfgs
    cfgs=$(get_all_configs)
    if [ -z "$cfgs" ]; then
        print_info "No configuration found."
        return
    fi
    while IFS= read -r cf; do
        local name
        name=$(get_tunnel_name "$cf")
        echo -e "${YELLOW}── ${name} (${cf}) ──${NC}"
        echo ""
        cat "$cf"
        echo ""
    done <<< "$cfgs"
}

edit_config() {
    print_banner
    echo -e "${GREEN}Edit Configuration${NC}"
    echo ""
    select_tunnel || return
    local editor
    editor="${EDITOR:-nano}"
    command -v "$editor" >/dev/null 2>&1 || editor="vi"
    "$editor" "$SELECTED_CONFIG" < /dev/tty
    read_confirm "Restart service now?" do_restart "y"
    if [ "$do_restart" = true ]; then
        systemctl restart "$SELECTED_SERVICE"
        sleep 1
        if systemctl is-active --quiet "$SELECTED_SERVICE"; then
            print_success "Restarted."
        else
            print_error "Failed to restart. Check logs."
        fi
    fi
}

test_connection() {
    print_banner
    echo -e "${GREEN}Connection Test Tool${NC}"
    echo ""

    select_tunnel || return
    local name
    name=$(get_tunnel_name "$SELECTED_CONFIG")

    echo -e "Tunnel: ${CYAN}$name${NC}"
    echo ""

    print_step "Test 1: Checking service status..."
    if systemctl is-active --quiet "$SELECTED_SERVICE" 2>/dev/null; then
        print_success "$SELECTED_SERVICE is running"
    else
        print_error "$SELECTED_SERVICE is NOT running"
        echo ""
        read_confirm "Would you like to start it?" start_svc "y"
        if [ "$start_svc" = true ]; then
            systemctl start "$SELECTED_SERVICE"
            sleep 2
            if systemctl is-active --quiet "$SELECTED_SERVICE"; then
                print_success "Service started"
            else
                print_error "Failed to start. Check: journalctl -u $SELECTED_SERVICE -n 20"
                return 1
            fi
        else
            return 1
        fi
    fi
    echo ""

    if [ "$name" = "server" ]; then
        test_server_b
    else
        test_server_a "$name"
    fi
}

test_server_b() {
    echo -e "${GREEN}Running Server B (Outside Iran) tests...${NC}"
    echo ""

    local port
    port=$(grep 'port:' "$SERVER_CONFIG" 2>/dev/null | head -1 | awk '{print $2}')

    print_step "Test 2: Checking SMTP tunnel port $port..."
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        print_success "SMTP tunnel listening on port $port"
    else
        print_error "Port $port is NOT listening"
        print_info "Check: journalctl -u $SERVER_SERVICE -n 20"
    fi
    echo ""

    print_step "Test 3: Checking TLS certificate..."
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        local expiry
        expiry=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [ -n "$expiry" ]; then
            print_success "Certificate valid until: $expiry"
        else
            print_warning "Could not read certificate expiry"
        fi
    else
        print_error "Certificate files missing"
    fi
    echo ""

    print_step "Test 4: Checking recent activity..."
    local recent_logs
    recent_logs=$(journalctl -u "$SERVER_SERVICE" --since "5 minutes ago" 2>/dev/null | tail -5)
    if [ -n "$recent_logs" ]; then
        echo "$recent_logs"
    else
        print_info "No recent activity in logs"
    fi
    echo ""

    print_step "Test 5: External connectivity..."
    if curl -s --max-time 5 ifconfig.me >/dev/null 2>&1; then
        local public_ip
        public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
        print_success "External connectivity OK (Public IP: $public_ip)"
    else
        print_warning "Cannot reach external services"
    fi
    echo ""

    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Server B Checklist:${NC}"
    echo -e "  • Ensure SMTP port ${CYAN}$port${NC} is open in cloud firewall"
    echo -e "  • Ensure xray inbounds listen on ${CYAN}0.0.0.0${NC} (not just public IP)"
    echo -e "  • Share the username + secret with Server A"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

test_server_a() {
    local tunnel_name="$1"
    local config_file="$INSTALL_DIR/client-${tunnel_name}.yaml"

    echo -e "${GREEN}Running Server A (Iran) tests...${NC}"
    echo ""

    local server_host server_port
    server_host=$(grep 'server_host:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
    server_port=$(grep 'server_port:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')

    echo -e "Target Server B: ${CYAN}${server_host}:${server_port}${NC}"
    echo ""

    print_step "Test 2: ICMP ping to Server B..."
    if ping -c 1 -W 3 "$server_host" >/dev/null 2>&1; then
        print_success "Server B is reachable via ICMP"
    else
        print_warning "ICMP blocked (this may be normal)"
    fi
    echo ""

    print_step "Test 3: TCP connectivity to Server B port $server_port..."
    local tcp_ok=false
    if timeout 5 bash -c "echo >/dev/tcp/$server_host/$server_port" 2>/dev/null; then
        tcp_ok=true
    elif command -v nc >/dev/null 2>&1; then
        if nc -z -w 5 "$server_host" "$server_port" 2>/dev/null; then
            tcp_ok=true
        fi
    fi
    if [ "$tcp_ok" = true ]; then
        print_success "Port $server_port on Server B responds to TCP"
    else
        print_error "Cannot reach Server B on port $server_port"
        print_info "Check: Server B firewall, cloud security group, ISP blocking"
    fi
    echo ""

    print_step "Test 4: Checking client-facing ports..."
    local listen_ports
    listen_ports=$(grep -A5 'forwards:' "$config_file" 2>/dev/null | grep 'listen:' | grep -oE '[0-9]+$' | tr '\n' ' ')
    for lp in $listen_ports; do
        if ss -tlnp 2>/dev/null | grep -q ":${lp} "; then
            print_success "Client-facing port $lp is listening"
        else
            print_warning "Port $lp is NOT listening"
        fi
    done
    echo ""

    print_step "Test 5: Recent tunnel activity..."
    local svc_name="smtp-tunnel-relay-${tunnel_name}"
    local recent_logs
    recent_logs=$(journalctl -u "$svc_name" --since "5 minutes ago" 2>/dev/null | grep -iE "connect|tunnel|forward|auth|error" | tail -5)
    if [ -n "$recent_logs" ]; then
        echo "$recent_logs"
    else
        print_info "No recent tunnel activity"
    fi
    echo ""

    print_step "Test 6: End-to-end TLS handshake test..."
    if command -v openssl >/dev/null 2>&1; then
        local tls_result
        tls_result=$(echo "" | timeout 10 openssl s_client -connect "${server_host}:${server_port}" -brief 2>&1 | head -5)
        if echo "$tls_result" | grep -qi "CONNECTION ESTABLISHED\|Protocol.*TLS\|Verification"; then
            print_success "TLS handshake to Server B succeeded"
        else
            print_warning "TLS handshake inconclusive"
            echo "$tls_result" | head -3
        fi
    else
        print_info "openssl not available, skipping TLS test"
    fi
    echo ""

    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Server A Checklist:${NC}"
    echo -e "  • Ensure client-facing ports (${CYAN}$listen_ports${NC}) are open in cloud firewall"
    echo -e "  • Ensure username + secret match Server B users.yaml"
    echo -e "  • Check relay logs: ${CYAN}journalctl -u $svc_name -f${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

#===============================================================================
# Check for Updates
#===============================================================================

check_for_updates() {
    print_banner
    echo -e "${YELLOW}Checking for Updates${NC}"
    echo ""

    local current_ver="$INSTALLER_VERSION"
    echo -e "Current version: ${CYAN}v${current_ver}${NC}"
    echo ""

    print_step "Fetching latest version from GitHub..."
    local remote_script
    remote_script=$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh" 2>/dev/null) || {
        print_error "Failed to fetch from GitHub. Check your internet connection."
        return 1
    }

    local remote_ver
    remote_ver=$(echo "$remote_script" | grep '^INSTALLER_VERSION=' | head -1 | cut -d'"' -f2)

    if [ -z "$remote_ver" ]; then
        print_error "Could not parse remote version."
        return 1
    fi

    echo -e "Latest version:  ${CYAN}v${remote_ver}${NC}"
    echo ""

    if [ "$current_ver" = "$remote_ver" ]; then
        print_success "You are running the latest version."
        return 0
    fi

    print_info "Update available: v${current_ver} -> v${remote_ver}"
    echo ""
    read_confirm "Update now?" do_update "y"
    [ "$do_update" = true ] || return 0

    local target
    if is_command_installed; then
        target="$INSTALLER_CMD"
    else
        target="${BASH_SOURCE[0]}"
    fi

    echo "$remote_script" > "$target"
    chmod +x "$target"
    print_success "Updated to v${remote_ver}."
    print_info "Restart the script to use the new version."

    # Also update runtime Python files
    print_step "Updating Python runtime files..."
    for pyfile in common.py smtp_server.py smtp_relay.py; do
        local py_url="https://raw.githubusercontent.com/${GITHUB_REPO}/main/${pyfile}"
        local py_dest="$INSTALL_DIR/$pyfile"
        if curl -fsSL --max-time 10 "$py_url" -o "$py_dest" 2>/dev/null; then
            print_success "Updated $pyfile"
        else
            print_warning "Could not update $pyfile (may not exist upstream)"
        fi
    done
    echo ""
    print_info "Restart tunnel services for changes to take effect."
}

#===============================================================================
# Auto-Reset (Scheduled Restart)
#===============================================================================

AUTO_RESET_CONF="$INSTALL_DIR/auto-reset.conf"
AUTO_RESET_SCRIPT="$INSTALL_DIR/auto-reset.sh"
AUTO_RESET_SERVICE="smtp-tunnel-auto-reset"
AUTO_RESET_TIMER="smtp-tunnel-auto-reset"

read_auto_reset_config() {
    ENABLED="false"
    INTERVAL="6"
    UNIT="hour"
    [ -f "$AUTO_RESET_CONF" ] && . "$AUTO_RESET_CONF"
}

write_auto_reset_config() {
    local enabled="$1" interval="$2" unit="$3"
    mkdir -p "$INSTALL_DIR"
    cat > "$AUTO_RESET_CONF" << EOF
ENABLED="$enabled"
INTERVAL="$interval"
UNIT="$unit"
EOF
}

create_auto_reset_script() {
    cat > "$AUTO_RESET_SCRIPT" << 'RESET_SCRIPT'
#!/bin/bash
CONF="/opt/smtp-tunnel/auto-reset.conf"
[ -f "$CONF" ] && . "$CONF"
[ "$ENABLED" != "true" ] && exit 0

for svc in /etc/systemd/system/smtp-tunnel*.service; do
    [ -f "$svc" ] || continue
    name=$(basename "$svc" .service)
    [ "$name" = "smtp-tunnel-auto-reset" ] && continue
    systemctl restart "$name" 2>/dev/null || true
done
RESET_SCRIPT
    chmod +x "$AUTO_RESET_SCRIPT"
}

create_auto_reset_timer() {
    local interval="$1" unit="$2"
    local period="${interval}${unit}"

    create_auto_reset_script

    cat > /etc/systemd/system/${AUTO_RESET_SERVICE}.service << EOF
[Unit]
Description=smtp-tunnel Auto-Reset (periodic restart for reliability)
After=network.target

[Service]
Type=oneshot
ExecStart=$AUTO_RESET_SCRIPT
EOF

    cat > /etc/systemd/system/${AUTO_RESET_TIMER}.timer << EOF
[Unit]
Description=smtp-tunnel Auto-Reset Timer
Requires=${AUTO_RESET_SERVICE}.service

[Timer]
OnBootSec=10min
OnUnitActiveSec=${period}
Persistent=yes

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${AUTO_RESET_TIMER}.timer 2>/dev/null || true
    print_success "Auto-reset timer enabled (every $interval $unit(s))"
}

remove_auto_reset_timer() {
    systemctl stop ${AUTO_RESET_TIMER}.timer 2>/dev/null || true
    systemctl disable ${AUTO_RESET_TIMER}.timer 2>/dev/null || true
    rm -f "/etc/systemd/system/${AUTO_RESET_TIMER}.timer"
    rm -f "/etc/systemd/system/${AUTO_RESET_SERVICE}.service"
    systemctl daemon-reload
    print_success "Auto-reset timer disabled"
}

manual_reset_all() {
    echo ""
    print_step "Restarting all smtp-tunnel services..."
    local count=0
    local cfgs
    cfgs=$(get_all_configs)
    if [ -z "$cfgs" ]; then
        print_error "No tunnels configured"
        return 1
    fi
    while IFS= read -r cf; do
        local svc name
        svc=$(get_service_name "$cf")
        name=$(get_tunnel_name "$cf")
        if systemctl restart "$svc" 2>/dev/null; then
            print_success "Restarted: $name ($svc)"
            count=$((count + 1))
        else
            print_warning "Could not restart: $name"
        fi
    done <<< "$cfgs"
    if [ $count -gt 0 ]; then
        print_success "Manual reset complete ($count service(s) restarted)"
    fi
    echo ""
}

auto_reset_menu() {
    # Disable errexit inside this interactive menu to avoid exiting
    # the whole script if any systemctl or read command fails.
    set +e
    while true; do
        print_banner
        echo -e "${YELLOW}Automatic Reset${NC}"
        echo -e "${CYAN}Periodically restart tunnel services for reliability${NC}"
        echo ""

        read_auto_reset_config

        echo -e "${YELLOW}Current settings:${NC}"
        if [ "$ENABLED" = "true" ]; then
            echo -e "  Status:   ${GREEN}Enabled${NC}"
            echo -e "  Interval: ${CYAN}Every $INTERVAL $UNIT(s)${NC}"
            if systemctl is-active --quiet ${AUTO_RESET_TIMER}.timer 2>/dev/null; then
                echo -e "  Timer:    ${GREEN}Active${NC}"
            else
                echo -e "  Timer:    ${RED}Inactive${NC}"
            fi
        else
            echo -e "  Status:   ${RED}Disabled${NC}"
        fi
        echo ""

        echo -e "${YELLOW}Options:${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} Enable automatic reset"
        echo -e "  ${CYAN}2)${NC} Disable automatic reset"
        echo -e "  ${CYAN}3)${NC} Set reset interval"
        echo -e "  ${CYAN}4)${NC} Manual reset now (restart all tunnels)"
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        echo ""

        read -p "Choice: " reset_choice < /dev/tty

        case $reset_choice in
            1)
                echo ""
                if [ "$ENABLED" = "true" ]; then
                    print_info "Automatic reset is already enabled"
                else
                    read_auto_reset_config
                    write_auto_reset_config "true" "${INTERVAL:-6}" "${UNIT:-hour}"
                    create_auto_reset_timer "${INTERVAL:-6}" "${UNIT:-hour}"
                fi
                ;;
            2)
                echo ""
                if [ "$ENABLED" != "true" ]; then
                    print_info "Automatic reset is already disabled"
                else
                    write_auto_reset_config "false" "$INTERVAL" "$UNIT"
                    remove_auto_reset_timer
                fi
                ;;
            3)
                echo ""
                echo -e "${CYAN}Set reset interval${NC}"
                echo ""
                echo -e "  ${YELLOW}1)${NC} Every 1 hour"
                echo -e "  ${YELLOW}2)${NC} Every 3 hours"
                echo -e "  ${YELLOW}3)${NC} Every 6 hours"
                echo -e "  ${YELLOW}4)${NC} Every 12 hours"
                echo -e "  ${YELLOW}5)${NC} Every 24 hours (1 day)"
                echo -e "  ${YELLOW}6)${NC} Every 7 days"
                echo ""
                read -p "Choice: " interval_choice < /dev/tty

                local new_interval="" new_unit=""
                case $interval_choice in
                    1) new_interval=1; new_unit=hour ;;
                    2) new_interval=3; new_unit=hour ;;
                    3) new_interval=6; new_unit=hour ;;
                    4) new_interval=12; new_unit=hour ;;
                    5) new_interval=1; new_unit=day ;;
                    6) new_interval=7; new_unit=day ;;
                    *) print_error "Invalid choice" ;;
                esac

                if [ -n "$new_interval" ]; then
                    write_auto_reset_config "$ENABLED" "$new_interval" "$new_unit"
                    if [ "$ENABLED" = "true" ]; then
                        create_auto_reset_timer "$new_interval" "$new_unit"
                    fi
                    print_success "Interval set to every $new_interval $new_unit(s)"
                fi
                ;;
            4) manual_reset_all ;;
            0)
                # Re-enable errexit before returning to main menu
                set -e
                return 0
                ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read < /dev/tty
    done
}

manage_tunnels_menu() {
    while true; do
        print_banner
        echo -e "${GREEN}Manage Tunnels${NC}"
        echo ""
        list_tunnels 2>/dev/null || true
        echo ""
        echo -e "${YELLOW}Options:${NC}"
        echo -e "  ${CYAN}1)${NC} Add relay tunnel on Server A"
        echo -e "  ${CYAN}2)${NC} Remove selected tunnel"
        echo -e "  ${CYAN}3)${NC} Restart selected tunnel"
        echo -e "  ${CYAN}4)${NC} View selected tunnel logs"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -p "Choice: " choice < /dev/tty
        case "$choice" in
            1) setup_server_a ;;
            2)
                select_tunnel || continue
                local name
                name=$(get_tunnel_name "$SELECTED_CONFIG")
                read_confirm "Remove tunnel '${name}'?" ok "n"
                [ "$ok" = true ] || continue
                systemctl stop "$SELECTED_SERVICE" 2>/dev/null || true
                systemctl disable "$SELECTED_SERVICE" 2>/dev/null || true
                rm -f "/etc/systemd/system/${SELECTED_SERVICE}.service"
                rm -f "$SELECTED_CONFIG"
                if [ "$name" = "server" ]; then
                    rm -f "$USERS_FILE" "$CERT_FILE" "$KEY_FILE"
                fi
                systemctl daemon-reload
                print_success "Removed '${name}'."
                ;;
            3)
                select_tunnel || continue
                systemctl restart "$SELECTED_SERVICE"
                print_success "Restarted $SELECTED_SERVICE"
                ;;
            4)
                select_tunnel || continue
                journalctl -u "$SELECTED_SERVICE" -n 50 --no-pager || true
                ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read < /dev/tty
    done
}

uninstall() {
    print_banner
    echo -e "${RED}Uninstall SMTP Tunnel${NC}"
    echo ""
    read_confirm "Remove all smtp tunnel services/configs?" ok "n"
    [ "$ok" = true ] || return

    # Stop auto-reset timer
    remove_auto_reset_timer 2>/dev/null || true

    local cfgs
    cfgs=$(get_all_configs)
    if [ -n "$cfgs" ]; then
        while IFS= read -r cf; do
            local svc
            svc=$(get_service_name "$cf")
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done <<< "$cfgs"
        systemctl daemon-reload
    fi
    rm -rf "$INSTALL_DIR"
    [ -f "$INSTALLER_CMD" ] && rm -f "$INSTALLER_CMD"
    print_success "Uninstalled."
}

is_command_installed() {
    [ -f "$INSTALLER_CMD" ] && [ -x "$INSTALLER_CMD" ]
}

install_command() {
    local running_script
    running_script="${BASH_SOURCE[0]}"
    [ -f "$running_script" ] || { print_error "Cannot locate script."; return 1; }
    cp "$running_script" "$INSTALLER_CMD"
    chmod +x "$INSTALLER_CMD"
    print_success "Installed command: smtp-tunnel"
}

uninstall_command() {
    if [ -f "$INSTALLER_CMD" ]; then
        rm -f "$INSTALLER_CMD"
        print_success "Command removed."
    else
        print_info "Command not installed."
    fi
}

show_architecture() {
    print_banner
    echo -e "${GREEN}Architecture${NC}"
    echo ""
    echo -e "${CYAN}client -> v2ray/xray config -> Server A (Iran) -> Server B (Outside Iran) -> xray inbound${NC}"
    echo ""
    echo -e "  - Server A runs ${YELLOW}smtp_relay.py${NC} and exposes client-facing ports"
    echo -e "  - Server B runs ${YELLOW}smtp_server.py${NC} on SMTP port (e.g., 587)"
    echo -e "  - A<->B uses SMTP handshake + STARTTLS + AUTH + binary multiplex stream"
    echo ""
}

main() {
    check_root
    while true; do
        print_banner
        if is_command_installed; then
            echo -e "${GREEN}[✓] smtp-tunnel command installed${NC}"
        else
            echo -e "${YELLOW}[i] Tip: install command with option 'i'${NC}"
        fi
        echo ""
        echo -e "${YELLOW}Select option:${NC}"
        echo ""
        echo -e "  ${GREEN}── Setup ──${NC}"
        echo -e "  ${CYAN}1)${NC} Setup Server B (Outside Iran)"
        echo -e "  ${CYAN}2)${NC} Setup Server A (Iran)"
        echo -e "  ${CYAN}a)${NC} Show architecture"
        echo ""
        echo -e "  ${GREEN}── Management ──${NC}"
        echo -e "  ${CYAN}3)${NC} Check status"
        echo -e "  ${CYAN}4)${NC} View configuration"
        echo -e "  ${CYAN}5)${NC} Edit configuration"
        echo -e "  ${CYAN}6)${NC} Manage tunnels"
        echo -e "  ${CYAN}7)${NC} Test connection"
        echo ""
        echo -e "  ${GREEN}── Maintenance ──${NC}"
        echo -e "  ${CYAN}8)${NC} Check for updates"
        echo -e "  ${CYAN}9)${NC} Automatic reset"
        echo -e "  ${CYAN}u)${NC} Uninstall"
        echo ""
        echo -e "  ${GREEN}── Script ──${NC}"
        if ! is_command_installed; then
            echo -e "  ${CYAN}i)${NC} Install as command"
        fi
        echo -e "  ${CYAN}r)${NC} Remove command"
        echo -e "  ${CYAN}h)${NC} Donate / Support project"
        echo -e "  ${CYAN}0)${NC} Exit"
        echo ""
        read -p "Choice: " choice < /dev/tty
        case "$choice" in
            1) setup_server_b ;;
            2) setup_server_a ;;
            3) check_status ;;
            4) view_config ;;
            5) edit_config ;;
            6) manage_tunnels_menu ;;
            7) test_connection ;;
            8) check_for_updates ;;
            9) auto_reset_menu ;;
            [Aa]) show_architecture ;;
            [Uu]) uninstall ;;
            [Ii]) install_command ;;
            [Rr]) uninstall_command ;;
            [Hh]) show_donate_info ;;
            0) exit 0 ;;
            *) print_error "Invalid choice" ;;
        esac
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read < /dev/tty
    done
}

main "$@"
