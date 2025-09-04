#!/usr/bin/with-contenv bashio

# Airsend Reception Initialization Script
# This script manages the reception system lifecycle

set -e

LOG_FILE="/share/airsend_reception.log"
PID_FILE="/tmp/airsend_reception.pid"
HEALTH_CHECK_INTERVAL=60
RESTART_DELAY=10
MAX_RETRIES=5

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE" >&2
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" | tee -a "$LOG_FILE"
    fi
}

# Cleanup function
cleanup() {
    log_info "Shutting down Airsend Reception..."
    
    if [ -f "$PID_FILE" ]; then
        while read PID; do
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID"
                wait "$PID" 2>/dev/null || true
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
    
    log_info "Cleanup completed"
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Wait for Home Assistant to be ready
wait_for_homeassistant() {
    log_info "Waiting for Home Assistant to be ready..."
    
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
               "http://supervisor/core/api/" > /dev/null 2>&1; then
            log_info "Home Assistant is ready"
            return 0
        fi
        
        retries=$((retries + 1))
        log_debug "Home Assistant not ready, attempt $retries/30"
        sleep 5
    done
    
    log_error "Home Assistant did not become ready in time"
    return 1
}

# Start PHP server
start_php_server() {
    log_info "Starting PHP server on port 80 for callback handling..."
    
    # Note: Port 33863 is handled by AirSendWebService, not PHP
    # We only need PHP on port 80 for the callback interface
    
    # Kill any existing PHP server on port 80
    fuser -k 80/tcp 2>/dev/null || true
    sleep 1
    
    # Start PHP server on localhost:80 for callback handling
    cd /home
    php -S 127.0.0.1:80 callback.php \
        -d error_reporting=E_ALL \
        -d display_errors=Off \
        -d log_errors=On \
        -d error_log="$LOG_FILE" \
        > /dev/null 2>&1 &
    
    local PHP_PID=$!
    echo "$PHP_PID" > "$PID_FILE"
    
    # Wait for server to start
    sleep 2
    
    if ! kill -0 "$PHP_PID" 2>/dev/null; then
        log_error "Failed to start PHP server"
        return 1
    fi
    
    log_info "PHP callback server started with PID $PHP_PID on port 80"
    log_info "Note: AirSendWebService handles port 33863 for reception"
    return 0
}

# Initialize listening on all configured devices
initialize_listening() {
    log_info "Initializing Airsend listening mode..."
    
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        # Call initialization endpoint on port 80 (PHP callback server)
        response=$(curl -s -X GET "http://localhost:80/initialize" 2>/dev/null || echo "{}")
        
        if echo "$response" | grep -q '"success":true'; then
            log_info "Listening mode initialized successfully"
            echo "$response" | tee -a "$LOG_FILE"
            return 0
        fi
        
        retries=$((retries + 1))
        log_error "Failed to initialize listening (attempt $retries/$MAX_RETRIES)"
        log_debug "Response: $response"
        
        if [ $retries -lt $MAX_RETRIES ]; then
            sleep $RESTART_DELAY
        fi
    done
    
    log_error "Failed to initialize listening after $MAX_RETRIES attempts"
    return 1
}

# Health check function
health_check() {
    # Check if PHP server is running (check first PID which is the main server)
    if [ -f "$PID_FILE" ]; then
        PID=$(head -n1 "$PID_FILE")
        if ! kill -0 "$PID" 2>/dev/null; then
            log_error "PHP server is not running (PID $PID)"
            return 1
        fi
    else
        log_error "PID file not found"
        return 1
    fi
    
    # Check server status endpoint on port 80 (PHP callback server)
    response=$(curl -s -f "http://localhost:80/status" 2>/dev/null || echo "{}")
    
    if ! echo "$response" | grep -q '"api_authorized":true'; then
        log_error "Health check failed: API not authorized"
        return 1
    fi
    
    log_debug "Health check passed"
    return 0
}

# Monitor and restart if needed
monitor_loop() {
    log_info "Starting monitoring loop..."
    
    local consecutive_failures=0
    
    while true; do
        sleep $HEALTH_CHECK_INTERVAL
        
        if health_check; then
            consecutive_failures=0
        else
            consecutive_failures=$((consecutive_failures + 1))
            log_error "Health check failed ($consecutive_failures consecutive failures)"
            
            if [ $consecutive_failures -ge 3 ]; then
                log_error "Too many consecutive failures, restarting service..."
                
                # Stop current instances
                if [ -f "$PID_FILE" ]; then
                    while read PID; do
                        kill "$PID" 2>/dev/null || true
                    done < "$PID_FILE"
                    rm -f "$PID_FILE"
                fi
                
                sleep $RESTART_DELAY
                
                # Restart services
                if start_php_server && initialize_listening; then
                    log_info "Service restarted successfully"
                    consecutive_failures=0
                else
                    log_error "Failed to restart service"
                    sleep $((RESTART_DELAY * 3))
                fi
            fi
        fi
    done
}

# Create necessary directories
create_directories() {
    log_info "Creating necessary directories..."
    
    # Ensure share directory exists
    mkdir -p /share
    
    # Ensure config directory exists
    mkdir -p /config
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    chmod 666 "$LOG_FILE"
}

# Main execution
main() {
    log_info "=== Airsend Reception System Starting ==="
    log_info "Version: 2.0"
    log_info "Environment: Home Assistant Addon"
    
    # Create directories
    create_directories
    
    # Wait for Home Assistant
    if ! wait_for_homeassistant; then
        log_error "Cannot proceed without Home Assistant"
        exit 1
    fi
    
    # Start PHP server
    if ! start_php_server; then
        log_error "Failed to start PHP server"
        exit 1
    fi
    
    # Initialize listening
    if ! initialize_listening; then
        log_error "Failed to initialize listening, but continuing..."
        # Continue anyway to maintain backward compatibility
    fi
    
    # Display status
    log_info "=== System Status ==="
    curl -s "http://localhost:80/status" 2>/dev/null | tee -a "$LOG_FILE" || true
    echo "" >> "$LOG_FILE"
    
    # Start monitoring loop
    log_info "Starting health monitoring..."
    monitor_loop
}

# Start the main process
main "$@"