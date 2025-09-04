#!/usr/bin/with-contenv bashio

# Compatibility script for original run.sh behavior
# This maintains the original functionality while addon is rebuilt

cd /home
arch="$(apk --print-arch)"
case "$arch" in \
		aarch64) arch='arm64' ;; \
		armhf) arch='armhf' ;; \
		armv7) arch='arm' ;; \
		amd64) arch='x86_64' ;; \
		i386) arch='x86' ;; \
	esac;
echo "AirSendWebService arch: ${arch}"
hname="$(hostname -i)"
echo "internal_url: http://${hname}:33863/"

if [ -n "${SUPERVISOR_TOKEN:-}" ]
then
	echo ${SUPERVISOR_TOKEN} > hass_api.token
	echo $(bashio::config 'auto_include') > auto_include.cfg
else
	echo "Not running on Home Assistant machine..."
fi

ulimit -n 4096

# Start AirSendWebService
./bin/unix/${arch}/AirSendWebService 99399 &
AIRSEND_PID=$!

# Give AirSendWebService time to start
sleep 5

# Start PHP callback server on port 80 for emission
php -S 127.0.0.1:80 callback.php &
PHP_PID=$!

# Monitor both services
while true; do
    # Check if AirSendWebService is still running
    if ! kill -0 $AIRSEND_PID 2>/dev/null; then
        echo "AirSendWebService died, exiting..."
        kill $PHP_PID 2>/dev/null || true
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