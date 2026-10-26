#!/usr/bin/env bash
# =============================================================================
# build_edge.sh
# 
# Cross-compiles the current Ballerina workspace into an ARM64 native binary
# using Docker (via QEMU/buildx emulation) and extracts it to ./release/
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

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_PLATFORM="linux/arm64"
IMAGE_NAME="${IMAGE_NAME:-ballerina-arm64-builder:latest}"
DOCKERFILE="${WORKSPACE_DIR}/Dockerfile.crosscompile"
RELEASE_DIR="${WORKSPACE_DIR}/release"
TARGET_BIN_DIR="${WORKSPACE_DIR}/target/bin"

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}  Ballerina ARM64 Edge Cross-Compiler for Orange Pi ${NC}"
echo -e "${BOLD}====================================================${NC}"
log_info "Workspace:       ${WORKSPACE_DIR}"
log_info "Target Platform: ${TARGET_PLATFORM}"
log_info "Builder Image:   ${IMAGE_NAME}"

# -----------------------------------------------------------------------------
# 1. Pre-flight Checks
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is required but not installed or not in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running. Please start Docker."
    exit 1
fi

if [ ! -f "${DOCKERFILE}" ]; then
    log_error "Dockerfile not found at: ${DOCKERFILE}"
    exit 1
fi

if [ ! -f "${WORKSPACE_DIR}/Ballerina.toml" ]; then
    log_warn "No Ballerina.toml detected in ${WORKSPACE_DIR}."
    log_warn "If this is a new project, run 'bal new <project_name>' or create Ballerina.toml before building."
fi

# Ensure multi-architecture support (binfmt) is registered if running on non-ARM64 host
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "aarch64" && "${HOST_ARCH}" != "arm64" ]]; then
    log_info "Host architecture is ${HOST_ARCH}. Ensuring QEMU ARM64 emulation is active..."
    # Attempt to register binfmt_misc handlers if buildx lacks emulation
    if ! docker run --rm --platform "${TARGET_PLATFORM}" alpine uname -m >/dev/null 2>&1; then
        log_warn "ARM64 emulation not registered. Setting up multiarch/qemu-user-static..."
        docker run --privileged --rm tonistiami/binfmt --install arm64 || true
    fi
fi

# -----------------------------------------------------------------------------
# 2. Build the ARM64 Cross-Compilation Container Image
# -----------------------------------------------------------------------------
log_info "Building ARM64 builder container image [${IMAGE_NAME}]..."

if docker buildx version >/dev/null 2>&1; then
    log_info "Using Docker Buildx for multi-platform build..."
    docker buildx build \
        --platform "${TARGET_PLATFORM}" \
        -t "${IMAGE_NAME}" \
        -f "${DOCKERFILE}" \
        --load \
        "${WORKSPACE_DIR}"
else
    log_info "Using standard Docker build..."
    docker build \
        --platform "${TARGET_PLATFORM}" \
        -t "${IMAGE_NAME}" \
        -f "${DOCKERFILE}" \
        "${WORKSPACE_DIR}"
fi

log_success "Builder image ready."

# -----------------------------------------------------------------------------
# 3. Compile Ballerina Project using GraalVM Native Image inside Container
# -----------------------------------------------------------------------------
log_info "Running 'bal build --graalvm' inside ARM64 container..."
log_info "Note: GraalVM AOT compilation in QEMU emulation requires sufficient RAM (4GB+ recommended)."

# Mount workspace and persistent Ballerina module cache
MSYS_NO_PATHCONV=1 docker run --rm -e JAVA_TOOL_OPTIONS="-Xshare:off" \
    --platform "${TARGET_PLATFORM}" \
    -v "${WORKSPACE_DIR}:/workspace" \
    -v ballerina-cache:/root/.ballerina \
    -w /workspace \
    "${IMAGE_NAME}" \
    bal build --graalvm "$@"

# -----------------------------------------------------------------------------
# 4. Extract Native Binary to ./release/
# -----------------------------------------------------------------------------
log_info "Extracting compiled ARM64 native binary to ./release/..."
mkdir -p "${RELEASE_DIR}"

if [ ! -d "${TARGET_BIN_DIR}" ]; then
    log_error "Directory ${TARGET_BIN_DIR} does not exist. Build may have failed."
    exit 1
fi

# Locate the compiled native binary (excluding .jar, .json, and directories)
FOUND_BINARY=0
for candidate in "${TARGET_BIN_DIR}"/*; do
    if [ -f "${candidate}" ]; then
        filename="$(basename "${candidate}")"
        # Skip Java JAR archives and auxiliary metadata files
        if [[ "${filename}" != *.jar && "${filename}" != *.json && "${filename}" != *.txt ]]; then
            cp -f "${candidate}" "${RELEASE_DIR}/${filename}"
            chmod +x "${RELEASE_DIR}/${filename}"
            log_success "Extracted native binary -> ${RELEASE_DIR}/${filename}"
            
            # Show file information if tools are available
            if command -v file >/dev/null 2>&1; then
                file "${RELEASE_DIR}/${filename}"
            fi
            ls -lh "${RELEASE_DIR}/${filename}"
            FOUND_BINARY=1
        fi
    fi
done

if [ "${FOUND_BINARY}" -eq 0 ]; then
    log_error "No native executable found in ${TARGET_BIN_DIR}."
    log_warn "Contents of target/bin:"
    ls -la "${TARGET_BIN_DIR}" || true
    exit 1
fi

echo -e "${BOLD}====================================================${NC}"
log_success "Native ARM64 build complete!"
echo -e "You can now deploy the binary to your Orange Pi Zero 3 using:"
echo -e "  ${BOLD}./deploy_edge.sh <ORANGE_PI_IP>${NC}"
echo -e "${BOLD}====================================================${NC}"

