#!/usr/bin/with-contenv bashio

# Simple run script that focuses on getting AirSendWebService working
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

echo "AirSendWebService arch: ${arch}"
hname="$(hostname -i)"
echo "internal_url: http://${hname}:33863/"

# Save token if available
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    echo ${SUPERVISOR_TOKEN} > hass_api.token
    echo "true" > auto_include.cfg
    echo "true" > reception_enabled.cfg
else
    echo "Not running on Home Assistant machine..."
fi

# Set file limit
ulimit -n 4096

# Make binary executable
chmod +x ./bin/unix/${arch}/AirSendWebService 2>/dev/null || true

# Check if binary exists and is executable
if [ ! -f "./bin/unix/${arch}/AirSendWebService" ]; then
    echo "ERROR: AirSendWebService binary not found at ./bin/unix/${arch}/AirSendWebService"
    ls -la ./bin/unix/ 2>/dev/null || echo "bin/unix directory not found"
    exit 1
fi

# Start AirSendWebService in background and capture output
echo "Starting AirSendWebService..."
./bin/unix/${arch}/AirSendWebService 99399 > /share/airsend_service.log 2>&1 &
AIRSEND_PID=$!

# Give it time to start
sleep 5

# Check if it started successfully
if ! kill -0 $AIRSEND_PID 2>/dev/null; then
    echo "ERROR: AirSendWebService failed to start. Output:"
    cat /share/airsend_service.log 2>/dev/null || echo "No log output"
    # Don't exit yet, try to continue with PHP services
fi

# Start PHP server for callback
echo "Starting PHP callback server..."
php -S 127.0.0.1:80 callback.php &
PHP_PID=$!

# If reception is enabled and we have the enhanced callback, start reception server too
if [ -f /home/callback.php ] && grep -q "AirsendReceptionApp" /home/callback.php 2>/dev/null; then
    echo "Starting reception server on port 33863..."
    php -S 0.0.0.0:33863 callback.php &
    RECEPTION_PID=$!
fi

echo "Services started:"
echo "  AirSendWebService: PID $AIRSEND_PID"
echo "  PHP Callback: PID $PHP_PID"
[ -n "${RECEPTION_PID:-}" ] && echo "  Reception Server: PID $RECEPTION_PID"

# Keep the script running - but don't exit if AirSendWebService dies
# It might be that AirSendWebService isn't needed for basic emission
echo "Entering monitoring loop..."
while true; do
    # Check if AirSendWebService is still running (if it was started)
    if [ -n "${AIRSEND_PID:-}" ] && ! kill -0 $AIRSEND_PID 2>/dev/null; then
        echo "WARNING: AirSendWebService is not running"
        # Try to restart it
        echo "Attempting to restart AirSendWebService..."
        ./bin/unix/${arch}/AirSendWebService 99399 > /share/airsend_service.log 2>&1 &
        AIRSEND_PID=$!
        sleep 5
        if ! kill -0 $AIRSEND_PID 2>/dev/null; then
            echo "Failed to restart AirSendWebService"
            echo "Last error:"
            tail -5 /share/airsend_service.log 2>/dev/null
            # Continue running without it
            unset AIRSEND_PID
        fi
    fi
    
    # Check if PHP server is still running
    if ! kill -0 $PHP_PID 2>/dev/null; then
        echo "PHP server died, restarting..."
        php -S 127.0.0.1:80 callback.php &
        PHP_PID=$!
    fi
    
    # Check reception server if it exists
    if [ -n "${RECEPTION_PID:-}" ] && ! kill -0 $RECEPTION_PID 2>/dev/null; then
        echo "Reception server died, restarting..."
        php -S 0.0.0.0:33863 callback.php &
        RECEPTION_PID=$!
    fi
    
    sleep 30
done