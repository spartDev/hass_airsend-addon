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
    
    # Use bashio if available, otherwise use defaults
    if command -v bashio &> /dev/null; then
        bashio::config 'auto_include' > auto_include.cfg 2>/dev/null || echo "true" > auto_include.cfg
        bashio::config 'reception_enabled' > reception_enabled.cfg 2>/dev/null || echo "true" > reception_enabled.cfg
    else
        echo "true" > auto_include.cfg
        echo "true" > reception_enabled.cfg
    fi
    
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

# Make sure the binary is executable
chmod +x ./bin/unix/${arch}/AirSendWebService 2>/dev/null || true

# The AirSendWebService runs in foreground, so we need to run it with nohup in background
nohup ./bin/unix/${arch}/AirSendWebService 99399 > /share/airsend_service.log 2>&1 &
AIRSEND_PID=$!

log_info "AirSendWebService starting with PID $AIRSEND_PID..."

# Give it more time to start as it might need to initialize
sleep 10

# Check if it's still running
if ! kill -0 $AIRSEND_PID 2>/dev/null; then
    log_error "AirSendWebService failed to start or crashed"
    # Show error output
    if [ -f /share/airsend_service.log ]; then
        log_error "Error output from AirSendWebService:"
        cat /share/airsend_service.log | while read line; do
            log_error "  $line"
        done
    fi
    # Try alternative: run in foreground in background subshell
    log_info "Attempting alternative startup method..."
    ( ./bin/unix/${arch}/AirSendWebService 99399 2>&1 | tee /share/airsend_service.log ) &
    AIRSEND_PID=$!
    sleep 5
    if ! kill -0 $AIRSEND_PID 2>/dev/null; then
        log_error "Alternative startup also failed"
        exit 1
    fi
fi

log_info "AirSendWebService running with PID $AIRSEND_PID"

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