#!/bin/bash
# ============================================================================
# Hermes Agent - Portable Launcher (macOS / Linux)
# ============================================================================
# Terminal:   ./launch.sh
# macOS Finder: rename this file to "launch.command" for double-click support.
# On first run, it downloads ~600MB of runtime files automatically.
# All data stays in the "data/" folder — nothing touches the host computer.
# ============================================================================

set -e

# Resolve portable root directory (directory containing this script)
PORTABLE_ROOT="$(cd "$(dirname "$0")" && pwd)"
# Define local paths for user data, cache, and source code
HERMES_HOME="$PORTABLE_ROOT/data"
CACHE_DIR="$PORTABLE_ROOT/.cache"
SRC_DIR="$PORTABLE_ROOT/src"

# ---------------------------------------------------------------------------
# Detect OS and architecture
# ---------------------------------------------------------------------------
OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

# Normalize operating system name
case "$OS_RAW" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
    *)
        echo "[ERROR] Unsupported operating system: $OS_RAW"
        exit 1
        ;;
esac

# Normalize CPU architecture name
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "[ERROR] Unsupported architecture: $ARCH_RAW"
        exit 1
        ;;
esac

RUNTIME_DIR="$CACHE_DIR/runtimes/${PLATFORM}-${ARCH}"

# Generates a stable, short 8-character unique identifier for a given string (typically a path).
# This is used to create unique names for things like virtual environments (venv) that
# need to exist on the host filesystem but stay tied to this specific portable directory.
#
# Fallback logic:
# - Uses `md5sum` (Linux standard) if available.
# - Falls back to `md5` (macOS standard) if `md5sum` is missing.
# - If neither is available, it strips non-alphanumeric characters from the directory's basename
#   and takes the first 8 characters.
#
# Globals:
#   None
# Arguments:
#   $1 - Path string to generate unique ID for
# Returns:
#   Outputs 8-character hex/alphanumeric string to stdout
portable_id() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 | cut -c1-8
    else
        basename "$1" | tr -cd '[:alnum:]' | cut -c1-8
    fi
}

# ---------------------------------------------------------------------------
# First-run setup check
# ---------------------------------------------------------------------------
# If ready.flag is missing, trigger setup-unix.sh to download and set up runtimes
if [ ! -f "$RUNTIME_DIR/ready.flag" ]; then
    echo ""
    echo "============================================"
    echo "    Hermes Portable - First Run Setup"
    echo "============================================"
    echo "  Platform: ${PLATFORM}-${ARCH}"
    echo "  This will download ~600MB of runtime files."
    echo "  Please be patient."
    echo "============================================"
    echo ""
    bash "$PORTABLE_ROOT/scripts/setup-unix.sh" "$PORTABLE_ROOT"
    if [ $? -ne 0 ]; then
        echo ""
        echo "[ERROR] Setup failed. Please check your internet connection and try again."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Environment isolation — keep everything inside the portable folder
# (except the venv, which must live on a local FS to avoid exFAT hardlink
# limitations — see scripts/setup-unix.sh for details)
# ---------------------------------------------------------------------------

# Read the venv path from the pointer file written during setup.
if [ -f "$RUNTIME_DIR/venv.path" ]; then
    VIRTUAL_ENV="$(cat "$RUNTIME_DIR/venv.path")"
else
    # Fallback for older setups that put the venv on the drive.
    VIRTUAL_ENV="$RUNTIME_DIR/venv"
fi

# If the venv is missing (e.g. after a reboot purged $TMPDIR), rebuild it dynamically.
if [ ! -x "$VIRTUAL_ENV/bin/python" ]; then
    echo ""
    echo "[INFO] Local venv not found (temp was likely cleared). Rebuilding ..."
    echo "       This is fast because packages are cached on the drive."
    UV_EXE="$RUNTIME_DIR/uv/uv"
    PYTHON_EXE="$RUNTIME_DIR/python/bin/python3"
    SRC_DIR="$PORTABLE_ROOT/src"

    if [ "$PLATFORM" = "macos" ]; then
        LOCAL_BASE="${TMPDIR:-/tmp}"
    else
        LOCAL_BASE="/tmp"
    fi

    DRIVE_ID="$(portable_id "$RUNTIME_DIR")"
    VIRTUAL_ENV="${LOCAL_BASE}/hermes-portable-venv-${DRIVE_ID}"
    export UV_CACHE_DIR="${LOCAL_BASE}/hermes-uv-cache-${DRIVE_ID}"
    mkdir -p "$UV_CACHE_DIR"

    # Save updated path
    echo "$VIRTUAL_ENV" > "$RUNTIME_DIR/venv.path"

    rm -rf "$VIRTUAL_ENV"
    if ! "$UV_EXE" venv "$VIRTUAL_ENV" --python "$PYTHON_EXE" --seed 2>/dev/null; then
        "$UV_EXE" venv "$VIRTUAL_ENV" --python "$PYTHON_EXE"
    fi
    if ! "$UV_EXE" pip install --python "$VIRTUAL_ENV/bin/python" --link-mode=copy \
        -e "$SRC_DIR/hermes-agent[all]" \
        "python-telegram-bot[webhooks]==22.6" 2>/dev/null; then
        "$VIRTUAL_ENV/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
        "$VIRTUAL_ENV/bin/python" -m pip install \
            -e "$SRC_DIR/hermes-agent[all]" \
            "python-telegram-bot[webhooks]==22.6" 2>/dev/null || true
    fi
    echo "[OK]    Venv rebuilt."
fi

# Export isolated environment variables
export HERMES_HOME="$HERMES_HOME"
export VIRTUAL_ENV
export PATH="$VIRTUAL_ENV/bin:$RUNTIME_DIR/python/bin:$RUNTIME_DIR/node/bin:$RUNTIME_DIR/uv:$RUNTIME_DIR/bin:$PATH"
export PYTHONNOUSERSITE=1
export PYTHONHOME=""
export PYTHONPATH=""
export UV_NO_CONFIG=1
export UV_PYTHON="$RUNTIME_DIR/python/bin/python3"
export PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright"
export NODE_PATH="$RUNTIME_DIR/node/lib/node_modules"
export NPM_CONFIG_PREFIX="$RUNTIME_DIR/node"

# Prevent Node/npm from writing to host home directory
export HOME="$PORTABLE_ROOT/.cache/unix-home"
mkdir -p "$HOME"

# ---------------------------------------------------------------------------
# Launch Hermes Verification
# ---------------------------------------------------------------------------
if [ ! -d "$SRC_DIR/hermes-agent" ]; then
    echo "[ERROR] Hermes source not found. Please delete .cache and try again."
    exit 1
fi

cd "$SRC_DIR/hermes-agent"

# Strip "hermes" from the start of arguments if user typed "launch.sh hermes setup"
if [ "$1" = "hermes" ] || [ "$1" = "HERMES" ]; then
    shift
fi

# If explicit arguments were passed, run Hermes directly (skip menu)
if [ $# -gt 0 ]; then
    hermes "$@"
    exit 0
fi

# ---------------------------------------------------------------------------
# ANSI Color Constants
# ---------------------------------------------------------------------------
ESC='\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
CYAN="${ESC}[36m"
BRIGHT_CYAN="${ESC}[96m"
GREEN="${ESC}[32m"
BRIGHT_GREEN="${ESC}[92m"
YELLOW="${ESC}[33m"
BRIGHT_YELLOW="${ESC}[93m"
RED="${ESC}[31m"
BRIGHT_RED="${ESC}[91m"
WHITE="${ESC}[37m"
BRIGHT_WHITE="${ESC}[97m"
GRAY="${ESC}[90m"

# ---------------------------------------------------------------------------
# Status Detection
# ---------------------------------------------------------------------------
# Analyzes the current state of the Hermes environment by checking various files.
# Updates global variables used by the interactive menu to display:
# - SETUP_STATUS: Whether the user has configured API keys in data/.env
# - PROVIDER_NAME / MODEL_NAME: The active LLM configuration from data/config.yaml
# - GATEWAY_STATUS: Whether the background FastAPI server is currently running,
#   by checking gateway.pid and validating the process ID.
# - HERMES_VERSION: Extracts the current version from the downloaded source code.
#
# Globals:
#   SETUP_STATUS, SETUP_ICON, SETUP_COLOR, PROVIDER_NAME, MODEL_NAME
#   GATEWAY_STATUS, GATEWAY_ICON, GATEWAY_COLOR, GATEWAY_PID, HERMES_VERSION
# Arguments:
#   None
# Returns:
#   None
detect_status() {
    SETUP_STATUS="Not configured"
    SETUP_ICON="[x]"
    SETUP_COLOR="$RED"
    PROVIDER_NAME=""
    MODEL_NAME=""

    if [ -f "$HERMES_HOME/.env" ] && grep -q '^[A-Z].*=' "$HERMES_HOME/.env"; then
        SETUP_STATUS="Configured"
        SETUP_ICON="[OK]"
        SETUP_COLOR="$BRIGHT_GREEN"
    fi

    if [ -f "$HERMES_HOME/config.yaml" ]; then
        PROVIDER_NAME=$(grep '^  provider:' "$HERMES_HOME/config.yaml" | head -n 1 | awk '{print $2}' || true)
        MODEL_NAME=$(grep '^  default:' "$HERMES_HOME/config.yaml" | head -n 1 | awk '{print $2}' || true)
    fi

    GATEWAY_STATUS="Stopped"
    GATEWAY_ICON="[ ]"
    GATEWAY_COLOR="$GRAY"
    GATEWAY_PID=""

    if [ -f "$HERMES_HOME/gateway.pid" ]; then
        GATEWAY_PID=$(grep -o '"pid":[0-9]*' "$HERMES_HOME/gateway.pid" | grep -o '[0-9]*' || true)
    fi

    if [ -n "$GATEWAY_PID" ]; then
        if kill -0 "$GATEWAY_PID" 2>/dev/null; then
            GATEWAY_STATUS="Running (PID $GATEWAY_PID)"
            GATEWAY_ICON="[OK]"
            GATEWAY_COLOR="$BRIGHT_GREEN"
        else
            GATEWAY_STATUS="Stopped (stale lock)"
            GATEWAY_ICON="[!]"
            GATEWAY_COLOR="$YELLOW"
        fi
    fi

    HERMES_VERSION="unknown"
    if [ -f "$SRC_DIR/hermes-agent/hermes_cli/__init__.py" ]; then
        HERMES_VERSION=$(grep '__version__' "$SRC_DIR/hermes-agent/hermes_cli/__init__.py" | head -n 1 | sed 's/.*"\(.*\)".*/\1/')
    fi
}

# ---------------------------------------------------------------------------
# Main Menu
# ---------------------------------------------------------------------------
# Displays the main interactive terminal dashboard menu for Hermes Portable.
# Renders the current configuration state (setup status, provider, model, gateway)
# and presents a list of primary actions for the user to choose from.
#
# Globals:
#   SETUP_STATUS, PROVIDER_NAME, MODEL_NAME, GATEWAY_STATUS, HERMES_VERSION
# Arguments:
#   None
# Returns:
#   None (Loops until user selects exit)
show_menu() {
    clear
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${BOLD}${BRIGHT_WHITE}                    HERMES PORTABLE LAUNCHER${RESET}"
    echo -e "${DIM}${GRAY}                         AI Agent for Everyone${RESET}"
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e " ${DIM}Setup${RESET}    ${SETUP_COLOR}${SETUP_ICON}${RESET} ${WHITE}${SETUP_STATUS}${RESET}"
    [ -n "$PROVIDER_NAME" ] && echo -e " ${DIM}Provider${RESET} ${CYAN}${PROVIDER_NAME}${RESET}"
    [ -n "$MODEL_NAME" ] && echo -e " ${DIM}Model${RESET}    ${WHITE}${MODEL_NAME}${RESET}"
    echo -e " ${DIM}Gateway${RESET}  ${GATEWAY_COLOR}${GATEWAY_ICON}${RESET} ${WHITE}${GATEWAY_STATUS}${RESET}"
    echo -e " ${DIM}Version${RESET}  ${GRAY}v${HERMES_VERSION}${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e "  ${BRIGHT_YELLOW}[1]${RESET}  ${WHITE}Start Hermes Chat${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[2]${RESET}  ${WHITE}Setup / Reconfigure Hermes${RESET}"
    if [ "$GATEWAY_STATUS" = "Running (PID $GATEWAY_PID)" ]; then
        echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Stop Gateway${RESET}  ${RED}[live]${RESET}"
    else
        echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Start Gateway${RESET}"
    fi
    echo -e "  ${BRIGHT_YELLOW}[4]${RESET}  ${WHITE}Advanced Options${RESET}  ${GRAY}-->${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[5]${RESET}  ${GRAY}Exit${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    read -p "$(echo -e "${BRIGHT_CYAN}Select option: ${RESET}")" choice

    case "$choice" in
        1) menu_chat ;;
        2) menu_setup ;;
        3) menu_gateway ;;
        4) show_advanced ;;
        5) menu_exit ;;
        *) show_menu ;;
    esac
}

# Launches the main Hermes chat CLI interactive interface in the terminal.
# Returns to the main menu when the chat session ends.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
menu_chat() {
    clear
    hermes
    show_menu
}

# Launches the interactive setup wizard to configure API keys, providers, and models.
# Re-detects environment status afterward to refresh the dashboard display.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
menu_setup() {
    clear
    hermes setup
    detect_status
    show_menu
}

# Toggles the background gateway server (starts if stopped, stops if running).
# Re-detects environment status afterward to update the dashboard display.
#
# Globals:
#   GATEWAY_STATUS, GATEWAY_PID
# Arguments:
#   None
# Returns:
#   None
menu_gateway() {
    if [ "$GATEWAY_STATUS" = "Running (PID $GATEWAY_PID)" ]; then
        hermes gateway stop
        echo ""
        echo -e "${BRIGHT_GREEN}Gateway stopped.${RESET}"
    else
        echo ""
        echo -e "${CYAN}Starting gateway in background ...${RESET}"
        hermes gateway &
        sleep 2
    fi
    read -p "Press Enter to continue ..."
    detect_status
    show_menu
}

# Exits the launcher menu and returns to the host shell.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   Exits process with status 0
menu_exit() {
    clear
    echo ""
    echo -e "${GRAY}Goodbye!${RESET}"
    echo ""
    exit 0
}

# ---------------------------------------------------------------------------
# Advanced Menu
# ---------------------------------------------------------------------------
# Displays the advanced options menu for diagnostics, logs, configuration, and updates.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None (Loops until user returns to main menu)
show_advanced() {
    clear
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${BOLD}${BRIGHT_WHITE}                       Advanced Options${RESET}"
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e "  ${BRIGHT_YELLOW}[1]${RESET}  ${WHITE}Run Doctor${RESET}            ${GRAY}- check for issues${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[2]${RESET}  ${WHITE}View Logs${RESET}             ${GRAY}- last 20 lines${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Edit Config${RESET}           ${GRAY}- open in editor${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[4]${RESET}  ${WHITE}Restart Gateway${RESET}       ${GRAY}- stop + start${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[5]${RESET}  ${WHITE}Update Hermes${RESET}         ${GRAY}- fetch latest${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[6]${RESET}  ${GRAY}Back to Main Menu${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    read -p "$(echo -e "${BRIGHT_CYAN}Select option: ${RESET}")" choice

    case "$choice" in
        1) adv_doctor ;;
        2) adv_logs ;;
        3) adv_config ;;
        4) adv_restart ;;
        5) adv_update ;;
        6) show_menu ;;
        *) show_advanced ;;
    esac
}

# Runs the Hermes doctor diagnostic tool to inspect virtualenv, dependencies, and settings.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
adv_doctor() {
    clear
    hermes doctor
    read -p "Press Enter to continue ..."
    show_advanced
}

# Displays the tail (last 20 lines) of the background gateway log file.
#
# Globals:
#   HERMES_HOME
# Arguments:
#   None
# Returns:
#   None
adv_logs() {
    clear
    if [ -f "$HERMES_HOME/logs/gateway.log" ]; then
        echo -e "${CYAN}=== Gateway Log (last 20 lines) ===${RESET}"
        tail -n 20 "$HERMES_HOME/logs/gateway.log"
    else
        echo -e "${YELLOW}No logs found.${RESET}"
    fi
    echo ""
    read -p "Press Enter to continue ..."
    show_advanced
}

# Opens the Hermes YAML configuration file in the system default text editor.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
adv_config() {
    clear
    hermes config edit
    show_advanced
}

# Restarts the background gateway service process.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
adv_restart() {
    hermes gateway restart
    echo ""
    echo -e "${BRIGHT_GREEN}Gateway restarted.${RESET}"
    read -p "Press Enter to continue ..."
    detect_status
    show_menu
}

# Fetches and applies updates for the Hermes Agent source code.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
adv_update() {
    clear
    hermes update
    read -p "Press Enter to continue ..."
    show_advanced
}

# ---------------------------------------------------------------------------
# Script Entry Point
# ---------------------------------------------------------------------------
detect_status
show_menu
