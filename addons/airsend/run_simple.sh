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

# Start AirSendWebService in background
echo "Starting AirSendWebService..."
./bin/unix/${arch}/AirSendWebService 99399 &
AIRSEND_PID=$!

# Give it time to start
sleep 5

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

# Keep the script running
while true; do
    # Check if AirSendWebService is still running
    if ! kill -0 $AIRSEND_PID 2>/dev/null; then
        echo "AirSendWebService died, exiting..."
        exit 1
    fi
    
    # Check if PHP server is still running
    if ! kill -0 $PHP_PID 2>/dev/null; then
        echo "PHP server died, restarting..."
        php -S 127.0.0.1:80 callback.php &
        PHP_PID=$!
    fi
    
    sleep 30
done