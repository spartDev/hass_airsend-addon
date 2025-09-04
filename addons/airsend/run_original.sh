#!/usr/bin/with-contenv bashio

# Original pattern that was working
# AirSendWebService runs in foreground, then exits, then PHP starts

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
	echo $(bashio::config 'auto_include' || echo "true") > auto_include.cfg
else
	echo "Not running on Home Assistant machine..."
fi

ulimit -n 4096

# Run AirSendWebService - it will exit quickly after initialization
./bin/unix/${arch}/AirSendWebService 99399

# After AirSendWebService exits, start PHP server
php -S 127.0.0.1:80 callback.php

# Keep container running
sleep infinity