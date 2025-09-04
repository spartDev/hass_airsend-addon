#!/usr/bin/with-contenv bashio

# Enhanced Airsend Service Runner with Reception Support
# This script manages both the original AirSendWebService and the new reception system

set -e

LOG_FILE="/share/airsend_main.log"
RECEPTION_ENABLED="${RECEPTION_ENABLED:-true}"

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE" >&2
}

# Cleanup function
cleanup() {
    log_info "Shutting down Airsend services..."
    
    # Kill all child processes
    pkill -P $$ || true
    
    # Kill specific services
    pkill -f "AirSendWebService" || true
    pkill -f "php.*callback" || true
    pkill -f "init_reception.sh" || true
    
    log_info "Cleanup completed"
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Main execution
cd /home

# Detect architecture
arch="$(apk --print-arch)"
case "$arch" in
    aarch64) arch='arm64' ;;
    armhf) arch='armhf' ;;
    armv7) arch='arm' ;;
    amd64) arch='x86_64' ;;
    i386) arch='x86' ;;
esac

log_info "=== Airsend Enhanced Service Starting ==="
log_info "Architecture: ${arch}"
log_info "Reception Enabled: ${RECEPTION_ENABLED}"

# Get hostname for internal URL
hname="$(hostname -i)"
log_info "Internal URL: http://${hname}:33863/"

# Set up Home Assistant token if running in supervisor
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    echo "${SUPERVISOR_TOKEN}" > hass_api.token
    echo "$(bashio::config 'auto_include')" > auto_include.cfg
    echo "$(bashio::config 'reception_enabled' 'true')" > reception_enabled.cfg
    
    # Export for child processes
    export SUPERVISOR_TOKEN
    export HASS_API_AUTHORIZED=true
    
    log_info "Running in Home Assistant Supervisor mode"
else
    log_info "Not running on Home Assistant machine (external mode)"
    export HASS_API_AUTHORIZED=false
fi

# Increase file descriptor limit
ulimit -n 4096

# Start AirSendWebService (original functionality)
log_info "Starting AirSendWebService..."
./bin/unix/${arch}/AirSendWebService 99399 > /share/airsend_service.log 2>&1 &
AIRSEND_PID=$!

# Wait for AirSendWebService to start
sleep 5

if ! kill -0 $AIRSEND_PID 2>/dev/null; then
    log_error "Failed to start AirSendWebService"
    exit 1
fi

log_info "AirSendWebService started with PID $AIRSEND_PID"

# Check if reception should be enabled
if [ "${RECEPTION_ENABLED}" = "true" ] && [ "${HASS_API_AUTHORIZED}" = "true" ]; then
    log_info "Starting reception system..."
    
    # Check if callback.php is the enhanced version (has reception support)
    if grep -q "AirsendReceptionApp" /home/callback.php 2>/dev/null; then
        # Start the reception initialization script
        /home/init_reception.sh &
        RECEPTION_PID=$!
    else
        log_warn "callback.php does not have reception support, using legacy mode"
        php -S 127.0.0.1:80 callback.php > /share/airsend_legacy.log 2>&1 &
        LEGACY_PID=$!
    fi
    
    if [ -n "${RECEPTION_PID:-}" ]; then
        log_info "Reception system started with PID $RECEPTION_PID"
    elif [ -n "${LEGACY_PID:-}" ]; then
        log_info "Legacy PHP server started with PID $LEGACY_PID"
    fi
else
    log_info "Reception system disabled or not authorized"
    
    # Fall back to original behavior (PHP server for emission only)
    log_info "Starting legacy PHP server for emission only..."
    php -S 127.0.0.1:80 callback.php > /share/airsend_legacy.log 2>&1 &
    LEGACY_PID=$!
    
    log_info "Legacy PHP server started with PID $LEGACY_PID"
fi

# Monitor services
log_info "=== All services started, entering monitoring loop ==="

while true; do
    # Check AirSendWebService
    if ! kill -0 $AIRSEND_PID 2>/dev/null; then
        log_error "AirSendWebService died, restarting all services..."
        exit 1
    fi
    
    # Check reception system if enabled
    if [ "${RECEPTION_ENABLED}" = "true" ] && [ "${HASS_API_AUTHORIZED}" = "true" ]; then
        if [ -n "${RECEPTION_PID:-}" ] && ! kill -0 $RECEPTION_PID 2>/dev/null; then
            log_error "Reception system died, restarting..."
            /home/init_reception.sh &
            RECEPTION_PID=$!
            log_info "Reception system restarted with PID $RECEPTION_PID"
        fi
    fi
    
    # Check legacy PHP server if running
    if [ -n "${LEGACY_PID:-}" ] && ! kill -0 $LEGACY_PID 2>/dev/null; then
        log_error "Legacy PHP server died, restarting..."
        php -S 127.0.0.1:80 callback.php > /share/airsend_legacy.log 2>&1 &
        LEGACY_PID=$!
        log_info "Legacy PHP server restarted with PID $LEGACY_PID"
    fi
    
    # Sleep before next check
    sleep 30
done