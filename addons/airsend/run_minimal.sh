#!/usr/bin/with-contenv bashio

# Minimal script - just run PHP servers without AirSendWebService
# This is to test if the addon can work without the binary

cd /home

echo "=== Minimal Airsend Addon Starting ==="
echo "Note: Running without AirSendWebService binary"
hname="$(hostname -i)"
echo "Internal URL: http://${hname}:33863/"

# Save token if available
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    echo ${SUPERVISOR_TOKEN} > hass_api.token
    echo "true" > auto_include.cfg
else
    echo "Not running on Home Assistant machine..."
fi

# Start PHP server for legacy callback (port 80)
echo "Starting PHP callback server on port 80..."
php -S 127.0.0.1:80 callback.php 2>&1 | sed 's/^/[PHP80] /' &
PHP_PID=$!

# Note: In minimal mode, we can run reception server on 33863 since AirSendWebService is not running
# Start PHP server for reception if enhanced callback exists
if grep -q "AirsendReceptionApp" /home/callback.php 2>/dev/null; then
    echo "Starting reception server on port 33863..."
    php -S 0.0.0.0:33863 callback.php 2>&1 | sed 's/^/[PHP33863] /' &
    RECEPTION_PID=$!
fi

echo ""
echo "Services started:"
echo "  PHP Callback (port 80): PID $PHP_PID"
[ -n "${RECEPTION_PID:-}" ] && echo "  Reception Server (port 33863): PID $RECEPTION_PID"
echo ""
echo "NOTE: AirSendWebService binary is NOT running."
echo "This may limit functionality but should allow basic testing."
echo ""

# Simple monitoring
while true; do
    # Check PHP servers
    if ! kill -0 $PHP_PID 2>/dev/null; then
        echo "PHP callback server died, restarting..."
        php -S 127.0.0.1:80 callback.php 2>&1 | sed 's/^/[PHP80] /' &
        PHP_PID=$!
    fi
    
    if [ -n "${RECEPTION_PID:-}" ] && ! kill -0 $RECEPTION_PID 2>/dev/null; then
        echo "Reception server died, restarting..."
        php -S 0.0.0.0:33863 callback.php 2>&1 | sed 's/^/[PHP33863] /' &
        RECEPTION_PID=$!
    fi
    
    sleep 30
done