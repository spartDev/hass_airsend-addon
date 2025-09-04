# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Home Assistant Add-on for controlling AirSend devices over a local network. The addon runs as a Docker container and provides a web service that bridges AirSend device events with Home Assistant entities.

## Architecture

### Core Components

1. **AirSendWebService**: Binary executable that listens on port 99399 for AirSend device communication
   - Platform-specific binaries located in `/home/bin/unix/{arch}/`
   - Handles RF communication with AirSend devices

2. **PHP Callback Server**: Runs on localhost:80 to process AirSend events
   - `callback.php`: Receives JSON events from AirSendWebService and updates Home Assistant states
   - `hassapi.class.php`: Encapsulates Home Assistant API interactions

3. **Shell Scripts**:
   - `run.sh`: Main entry point that starts both AirSendWebService and PHP server
   - `state_post.sh`: Updates Home Assistant entity states via Supervisor API
   - `states_get.sh`: Fetches all entity states from Home Assistant

### Communication Flow

1. AirSend devices send RF signals to AirSendWebService
2. AirSendWebService converts RF data to JSON events and posts to callback.php
3. callback.php processes events and updates Home Assistant entities via Supervisor API
4. State changes are reflected in Home Assistant

## Development Commands

### Building the Docker Image

```bash
# For local development (replace BUILD_FROM in Dockerfile first)
cd addons/airsend
docker build -t hass_airsend-addon .
```

### Running the Container

```bash
# Standard Home Assistant addon deployment
docker run -dp 33863:33863 hass_airsend-addon

# For external machine deployment (modify callback.php with HA API credentials)
docker run -dp 33863:33863 hass_airsend-addon
```

### Installation

```bash
# Automated installation to Home Assistant
wget -q -O - https://raw.githubusercontent.com/devmel/hass_airsend-addon/master/install | bash -

# Manual: Copy addons/airsend folder to HA addon directory
```

## Key Configuration

- **Port**: 33863 (exposed for AirSend device communication)
- **API Authentication**: Uses `SUPERVISOR_TOKEN` environment variable when running in HA
- **Auto-include**: Boolean option to automatically include new discovered devices
- **Architecture Support**: aarch64, amd64, armhf, armv7, i386

## External Machine Setup

When running outside Home Assistant:
1. Modify `Dockerfile`: Replace `ARG BUILD_FROM FROM $BUILD_FROM` with specific base image
2. Edit `callback.php`: Set `$BASE_HASS_API` and `$HASS_API_TOKEN` to your HA instance values
3. Build and run the container as shown above