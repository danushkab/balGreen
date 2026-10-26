#!/usr/bin/env bash
# =============================================================================
# deploy_edge.sh
# 
# Deploys the compiled ARM64 Ballerina native binary from ./release/
# to an Orange Pi Zero 3 (or any ARM64 headless Linux edge device),
# installs a systemd unit file, and restarts the service.
# =============================================================================

set -euo pipefail

# Text formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${WORKSPACE_DIR}/release"

# -----------------------------------------------------------------------------
# Default Configuration (Override via CLI flags or Environment Variables)
# -----------------------------------------------------------------------------
TARGET_IP="${TARGET_IP:-}"
TARGET_USER="${TARGET_USER:-orangepi}"
TARGET_PORT="${TARGET_PORT:-22}"
TARGET_DIR="${TARGET_DIR:-/opt/ballerina-edge}"
SSH_KEY="${SSH_KEY:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
BINARY_NAME="${BINARY_NAME:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [TARGET_IP]

Deploys the compiled Ballerina binary from ./release/ to an ARM64 edge device.

Arguments:
  TARGET_IP                 IP address or hostname of the Orange Pi Zero 3

Options:
  -h, --host <ip/host>      Target IP address or hostname
  -u, --user <username>     SSH username (default: \${TARGET_USER:-orangepi})
  -p, --port <port>         SSH port (default: \${TARGET_PORT:-22})
  -i, --identity <path>     SSH private key path (optional)
  -d, --dir <remote_path>   Remote destination directory (default: /opt/ballerina-edge)
  -s, --service <name>      Systemd service unit name (default: <binary_name>.service)
  -b, --binary <name>       Specific binary name in ./release/ to deploy
  --help                    Show this help message and exit

Examples:
  ./deploy_edge.sh 192.168.1.150
  ./deploy_edge.sh -h 192.168.1.150 -u root -d /opt/my-app
  TARGET_IP=192.168.1.150 TARGET_USER=orangepi ./deploy_edge.sh
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Parse Command-Line Arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)
            TARGET_IP="$2"
            shift 2
            ;;
        -u|--user)
            TARGET_USER="$2"
            shift 2
            ;;
        -p|--port)
            TARGET_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        -d|--dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE_NAME="$2"
            shift 2
            ;;
        -b|--binary)
            BINARY_NAME="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "${TARGET_IP}" ]; then
                TARGET_IP="$1"
                shift
            else
                log_error "Unexpected argument: $1"
                usage
            fi
            ;;
    esac
done

# Ensure Target IP is provided
if [ -z "${TARGET_IP}" ]; then
    log_error "Target IP address is required."
    echo ""
    usage
fi

# -----------------------------------------------------------------------------
# 1. Locate Native Binary in ./release/
# -----------------------------------------------------------------------------
if [ ! -d "${RELEASE_DIR}" ]; then
    log_error "Release directory not found at: ${RELEASE_DIR}"
    log_error "Please build your project first by executing: ./build_edge.sh"
    exit 1
fi

if [ -z "${BINARY_NAME}" ]; then
    # Auto-detect binary in release folder
    BINARIES=()
    for f in "${RELEASE_DIR}"/*; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            BINARIES+=("$(basename "$f")")
        fi
    done

    if [ ${#BINARIES[@]} -eq 0 ]; then
        log_error "No executable binaries found in ${RELEASE_DIR}."
        log_error "Please run './build_edge.sh' to compile the native image first."
        exit 1
    elif [ ${#BINARIES[@]} -eq 1 ]; then
        BINARY_NAME="${BINARIES[0]}"
        log_info "Auto-detected binary: ${BINARY_NAME}"
    else
        BINARY_NAME="${BINARIES[0]}"
        log_warn "Multiple binaries found in ./release/. Defaulting to '${BINARY_NAME}'."
        log_warn "You can specify another binary using: -b <binary_name>"
    fi
else
    if [ ! -f "${RELEASE_DIR}/${BINARY_NAME}" ]; then
        log_error "Specified binary '${BINARY_NAME}' was not found in ${RELEASE_DIR}."
        exit 1
    fi
fi

# Default service name to binary name if not explicitly set
if [ -z "${SERVICE_NAME}" ]; then
    SERVICE_NAME="${BINARY_NAME}"
fi
# Strip .service suffix if user provided it to keep naming uniform
SERVICE_NAME="${SERVICE_NAME%.service}"

LOCAL_BINARY_PATH="${RELEASE_DIR}/${BINARY_NAME}"
REMOTE_BINARY_PATH="${TARGET_DIR}/${BINARY_NAME}"
SERVICE_FILE_NAME="${SERVICE_NAME}.service"

# Build SSH / SCP option flags
SSH_OPTS=(-p "${TARGET_PORT}" -o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")
SCP_OPTS=(-P "${TARGET_PORT}" -o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")

if [ -n "${SSH_KEY}" ]; then
    SSH_OPTS+=(-i "${SSH_KEY}")
    SCP_OPTS+=(-i "${SSH_KEY}")
fi

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}  Deploying Ballerina Native Service to Edge Device ${NC}"
echo -e "${BOLD}====================================================${NC}"
log_info "Target Device:     ${TARGET_USER}@${TARGET_IP}:${TARGET_PORT}"
log_info "Local Binary:      ${LOCAL_BINARY_PATH}"
log_info "Remote Directory:  ${TARGET_DIR}"
log_info "Remote Binary:     ${REMOTE_BINARY_PATH}"
log_info "Systemd Service:   ${SERVICE_FILE_NAME}"

# -----------------------------------------------------------------------------
# 2. Test SSH Connection
# -----------------------------------------------------------------------------
log_info "Verifying SSH connection to ${TARGET_USER}@${TARGET_IP}..."
if ! ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" "echo 'SSH connection successful.'" >/dev/null 2>&1; then
    log_error "Failed to connect to ${TARGET_USER}@${TARGET_IP} via SSH."
    log_error "Please check the IP address, username, SSH key/password, and network connectivity."
    exit 1
fi
log_success "SSH connection established."

# -----------------------------------------------------------------------------
# 3. Prepare Remote Target Directory & Stop Existing Service (if active)
# -----------------------------------------------------------------------------
log_info "Preparing remote target directory: ${TARGET_DIR}..."
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" bash -c "'
    # Stop existing service if it is currently running to prevent 'text file busy' error
    if sudo systemctl is-active --quiet ${SERVICE_FILE_NAME} 2>/dev/null; then
        echo \"Stopping active ${SERVICE_FILE_NAME} before deployment...\"
        sudo systemctl stop ${SERVICE_FILE_NAME}
    fi
    
    # Create installation directory and assign proper permissions
    sudo mkdir -p \"${TARGET_DIR}\"
    sudo chown -R \"${TARGET_USER}:${TARGET_USER}\" \"${TARGET_DIR}\"
'"

# -----------------------------------------------------------------------------
# 4. Copy Binary to Target Device via SCP
# -----------------------------------------------------------------------------
log_info "Copying '${BINARY_NAME}' to ${TARGET_USER}@${TARGET_IP}:${TARGET_DIR}/..."
scp "${SCP_OPTS[@]}" "${LOCAL_BINARY_PATH}" "${TARGET_USER}@${TARGET_IP}:${REMOTE_BINARY_PATH}.tmp"

# Atomically move the binary into place and ensure executable permissions
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" bash -c "'
    mv -f \"${REMOTE_BINARY_PATH}.tmp\" \"${REMOTE_BINARY_PATH}\"
    chmod +x \"${REMOTE_BINARY_PATH}\"
'"
log_success "Binary deployed successfully."

# -----------------------------------------------------------------------------
# 5. Generate and Install Systemd Service File on Edge Device
# -----------------------------------------------------------------------------
log_info "Generating and installing systemd service (/etc/systemd/system/${SERVICE_FILE_NAME})..."

# Stream systemd service configuration directly to remote host with sudo tee
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" "sudo tee /etc/systemd/system/${SERVICE_FILE_NAME} > /dev/null" <<EOF
[Unit]
Description=Ballerina Native Edge Service (${BINARY_NAME})
Documentation=https://ballerina.io
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
WorkingDirectory=${TARGET_DIR}
ExecStart=${REMOTE_BINARY_PATH}
Restart=always
RestartSec=5s
KillMode=process
LimitNOFILE=65536
Environment=BALLERINA_ENV=production

# Standard logging to journald
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log_success "Systemd service file installed."

# -----------------------------------------------------------------------------
# 6. Reload Systemd, Enable & Restart the Service
# -----------------------------------------------------------------------------
log_info "Reloading systemd daemon, enabling and restarting service..."

ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" bash -c "'
    sudo systemctl daemon-reload
    sudo systemctl enable ${SERVICE_FILE_NAME}
    sudo systemctl restart ${SERVICE_FILE_NAME}
    sleep 1
    echo \"---------------- Service Status ----------------\"
    sudo systemctl status ${SERVICE_FILE_NAME} --no-pager
    echo \"------------------------------------------------\"
'"

echo -e "${BOLD}====================================================${NC}"
log_success "Deployment completed successfully!"
echo -e "Useful commands on target device (${TARGET_IP}):"
echo -e "  View live logs:   ${BOLD}ssh ${TARGET_USER}@${TARGET_IP} \"journalctl -u ${SERVICE_FILE_NAME} -f\"${NC}"
echo -e "  Check status:     ${BOLD}ssh ${TARGET_USER}@${TARGET_IP} \"sudo systemctl status ${SERVICE_FILE_NAME}\"${NC}"
echo -e "  Stop service:     ${BOLD}ssh ${TARGET_USER}@${TARGET_IP} \"sudo systemctl stop ${SERVICE_FILE_NAME}\"${NC}"
echo -e "  Restart service:  ${BOLD}ssh ${TARGET_USER}@${TARGET_IP} \"sudo systemctl restart ${SERVICE_FILE_NAME}\"${NC}"
echo -e "${BOLD}====================================================${NC}"

