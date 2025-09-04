# Airsend Reception Installation & Troubleshooting Guide

## Table of Contents
1. [Installation Steps](#installation-steps)
2. [Configuration](#configuration)
3. [Testing & Validation](#testing--validation)
4. [Troubleshooting](#troubleshooting)
5. [Common Issues & Solutions](#common-issues--solutions)
6. [Advanced Configuration](#advanced-configuration)

---

## Installation Steps

### Step 1: Backup Current Installation
Before upgrading, backup your current configuration:
```bash
# SSH into Home Assistant
cd /addon_configs/
cp -r airsend airsend_backup_$(date +%Y%m%d)
```

### Step 2: Install Enhanced Addon

#### Option A: Fresh Installation
1. Add the repository to Home Assistant:
   - Navigate to **Supervisor** → **Add-on Store**
   - Click **⋮** → **Repositories**
   - Add: `https://github.com/devmel/hass_airsend-addon`
   
2. Find "AirSend Enhanced" in local add-ons
3. Click **Install**

#### Option B: Upgrade Existing Installation
The addon files have been enhanced in-place. Simply:
1. Update your local repository:
```bash
cd /addons/airsend/
git pull
```
2. Or if manually updating, the enhanced features are already integrated into:
   - `callback.php` - Now includes reception capabilities
   - `run.sh` - Enhanced with reception support
   - `Dockerfile` - Updated dependencies
   - `config.yaml` - New configuration options
3. Restart the addon to apply changes

### Step 3: Configure Devices
1. Create configuration file at `/config/airsend.yaml`:
```yaml
# Example device configuration
devices:
  Volet séjour baie vitrée:
    id: 67706
    type: 4099
    wait: true
    spurl: !secret spurl  # Reference to secrets.yaml
    channel:
      id: 13920
      source: 567765
      listen: true  # Add this to enable reception
```

2. Create or update secrets file at `/config/secrets.yaml`:
```yaml
# Airsend device connection URL
spurl: "sp://PASSWORD@192.168.1.100"  # Format: sp://password@ip_address

# Or if using separate password
airsend_password: "your_actual_password"
```

### Step 4: Configure Addon Settings
1. Go to **Supervisor** → **AirSend** → **Configuration**
2. Set options:
```yaml
auto_include: true
reception_enabled: true
log_level: INFO
health_check_interval: 60
max_retries: 5
```

### Step 5: Start the Addon
1. Click **Start** in the addon page
2. Enable **Start on boot** and **Watchdog**
3. Check logs for initialization status

### Step 6: Verify Installation
```bash
# Run validation test
docker exec addon_airsend /home/test_reception.sh

# Check status
curl http://localhost:33863/status
```

---

## Configuration

### Basic Device Configuration

Each device in `/config/airsend.yaml` requires:

| Field | Description | Required | Example |
|-------|-------------|----------|---------|
| `id` | Device identifier | Yes | `67706` |
| `type` | Protocol type (4099=Somfy RTS) | Yes | `4099` |
| `wait` | Wait for command completion | No | `true` |
| `spurl` | Connection URL (sp://password@ip) | Yes | `!secret spurl` |
| `channel.id` | RF channel ID | Yes | `13920` |
| `channel.source` | Remote control ID | Yes | `567765` |
| `channel.listen` | Enable reception | For reception | `true` |

**Note:** The `spurl` field combines password and IP address in format `sp://PASSWORD@IP_ADDRESS:PORT`

### Home Assistant Integration

Add to `configuration.yaml`:

```yaml
# Enable REST commands
rest_command:
  airsend_init:
    url: "http://localhost:33863/initialize"
    method: GET

# Monitor health
binary_sensor:
  - platform: rest
    name: Airsend Health
    resource: http://localhost:33863/status
    value_template: "{{ value_json.api_authorized }}"
    scan_interval: 60

# React to remote events
automation:
  - alias: Physical Remote Pressed
    trigger:
      - platform: event
        event_type: airsend_remote_pressed
    action:
      - service: logbook.log
        data:
          name: "Remote Control"
          message: "{{ trigger.event.data.device_name }} - {{ trigger.event.data.command }}"
```

---

## Testing & Validation

### 1. Run Built-in Test Suite
```bash
docker exec addon_airsend /home/test_reception.sh
```

Expected output:
```
[PASS] Prerequisites check
[PASS] Services running
[PASS] API endpoints responding
[PASS] Initialization successful
```

### 2. Test Remote Reception
```bash
# Simulate remote button press
curl -X POST http://localhost:33863/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "method": "radio",
    "channel": 13920,
    "source": 567765,
    "command": "down",
    "timestamp": 1234567890
  }'
```

### 3. Monitor Logs
```bash
# View reception logs
tail -f /share/airsend_reception.log

# Check for errors
grep ERROR /share/airsend_reception.log
```

### 4. Verify Entity Updates
1. Press physical remote button
2. Check Home Assistant entity state within 2 seconds
3. Verify event in Developer Tools → Events → `airsend_remote_pressed`

---

## Troubleshooting

### Diagnostic Commands

```bash
# Check addon status
docker ps | grep airsend

# View all logs
docker logs addon_airsend

# Check listening status
curl http://localhost:33863/status | jq .

# Test connectivity to Airsend
ping 192.168.1.100

# Verify configuration
cat /config/airsend.yaml
```

### Log Analysis

#### Understanding Log Levels
- **DEBUG**: Detailed operation info (verbose)
- **INFO**: Normal operation messages
- **WARNING**: Non-critical issues
- **ERROR**: Critical failures requiring attention

#### Key Log Patterns
```bash
# Check initialization
grep "Initialized listening" /share/airsend_reception.log

# Find connection errors
grep "API call failed" /share/airsend_reception.log

# Monitor remote events
grep "Received radio event" /share/airsend_reception.log
```

---

## Common Issues & Solutions

### Issue 1: Reception Not Working

**Symptoms:**
- Physical remote presses don't update HA entities
- No events in logs

**Solutions:**
1. Verify device configuration:
```bash
curl http://localhost:33863/status
# Check "listening" field for your device
```

2. Reinitialize listening:
```bash
curl http://localhost:33863/initialize
```

3. Check Airsend connectivity:
```bash
# Test direct connection
curl "sp://password@192.168.1.100:33863/api/status"
```

### Issue 2: "API Not Authorized" Error

**Symptoms:**
- Status shows `api_authorized: false`
- Entities not updating

**Solutions:**
1. Verify Supervisor token:
```bash
echo $SUPERVISOR_TOKEN
```

2. Restart addon:
```bash
ha addon restart airsend
```

3. Check Home Assistant API:
```bash
curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/
```

### Issue 3: Multiple Devices Not Working

**Symptoms:**
- Only one device receives events
- Other devices show "listening: false"

**Note:** Airsend hardware limitation - only one channel can be monitored at a time.

**Solutions:**
1. Use multiple Airsend devices (one per channel)
2. Prioritize most important device:
```yaml
devices:
  # Set listen: true only for primary device
  Volet principal:
    id: 67706
    type: 4099
    spurl: !secret spurl
    channel:
      id: 13920
      source: 567765
      listen: true
      
  Volet secondaire:
    id: 67707
    type: 4099
    spurl: !secret spurl
    channel:
      id: 13921
      source: 567766
      listen: false  # Emission only
```

### Issue 4: High CPU/Memory Usage

**Symptoms:**
- Addon consuming excessive resources
- System slowdown

**Solutions:**
1. Increase health check interval:
```yaml
health_check_interval: 120  # 2 minutes instead of 1
```

2. Reduce log verbosity:
```yaml
log_level: WARNING  # Instead of DEBUG
```

3. Implement log rotation:
```bash
# Add to crontab
0 0 * * * truncate -s 0 /share/airsend_reception.log
```

### Issue 5: Delayed State Updates

**Symptoms:**
- >2 second delay between remote press and HA update
- Intermittent delays

**Solutions:**
1. Check network latency:
```bash
ping -c 10 192.168.1.100
```

2. Optimize webhook processing:
- Ensure no blocking operations
- Check system resources

3. Review automation complexity:
- Simplify triggered automations
- Use async processing

---

## Advanced Configuration

### External Machine Deployment

For running outside Home Assistant:

1. Modify `callback.php`:
```php
$BASE_HASS_API = "http://homeassistant.local:8123/api";
$HASS_API_TOKEN = "your-long-lived-token";
```

2. Update Dockerfile:
```dockerfile
FROM php:8-alpine
# Remove ARG BUILD_FROM
```

3. Run container:
```bash
docker build -t airsend-reception .
docker run -d \
  -p 33863:33863 \
  -v /path/to/config:/config \
  -v /path/to/share:/share \
  --name airsend-reception \
  airsend-reception
```

### IPv6 Support

For IPv6 Airsend devices:
```yaml
devices:
  Device IPv6:
    id: 67708
    type: 4099
    spurl: "sp://PASSWORD@fe80::1234:5678:90ab:cdef"  # IPv6 address
    # Brackets added automatically when needed
    channel:
      id: 13922
      source: 567767
      listen: true
```

### Custom Entity Names

Override default entity naming:
```yaml
# In airsend.yaml
devices:
  Volet custom:
    id: 67709
    type: 4099
    spurl: !secret spurl
    entity_id_override: "cover.my_custom_name"
    # Instead of auto-generated cover.airsend_volet_custom
    channel:
      id: 13923
      source: 567768
      listen: true
```

### Performance Tuning

```yaml
# config.yaml addon options
reception_enabled: true
log_level: WARNING  # Reduce logging overhead
health_check_interval: 180  # 3 minutes
max_retries: 3  # Reduce retry attempts
```

### Security Hardening

1. Restrict network access:
```yaml
# Docker network isolation
network_mode: host  # Change to bridge if possible
```

2. Implement rate limiting (add to callback.php):
```php
// Simple rate limiting
session_start();
$_SESSION['requests'] = ($_SESSION['requests'] ?? 0) + 1;
if ($_SESSION['requests'] > 100) {
    http_response_code(429);
    die("Rate limit exceeded");
}
```

---

## Monitoring & Maintenance

### Health Monitoring Dashboard

Create Lovelace card:
```yaml
type: vertical-stack
cards:
  - type: gauge
    entity: sensor.airsend_devices_listening
    min: 0
    max: 10
    severity:
      green: 1
      yellow: 0
      red: 0
      
  - type: entities
    title: Airsend Status
    entities:
      - binary_sensor.airsend_health
      - sensor.airsend_last_event
      - sensor.airsend_error_count
```

### Automated Maintenance

```yaml
# Auto-restart on failure
automation:
  - alias: Restart Airsend on Failure
    trigger:
      - platform: state
        entity_id: binary_sensor.airsend_health
        to: "off"
        for: "00:05:00"
    action:
      - service: hassio.addon_restart
        data:
          addon: airsend
```

### Backup Strategy

```bash
#!/bin/bash
# backup_airsend.sh
BACKUP_DIR="/backup/airsend"
mkdir -p $BACKUP_DIR

# Backup configuration
cp /config/airsend.yaml $BACKUP_DIR/airsend_$(date +%Y%m%d).yaml
cp /config/secrets.yaml $BACKUP_DIR/secrets_$(date +%Y%m%d).yaml

# Backup logs
cp /share/airsend_*.log $BACKUP_DIR/

# Cleanup old backups (keep 7 days)
find $BACKUP_DIR -mtime +7 -delete
```

---

## Support Resources

### Getting Help

1. **Check Logs First**
   - Addon logs: Supervisor → AirSend → Logs
   - Reception logs: `/share/airsend_reception.log`
   - Test results: `/share/airsend_test_*.log`

2. **Community Support**
   - Home Assistant Forums: https://community.home-assistant.io
   - GitHub Issues: https://github.com/devmel/hass_airsend-addon/issues

3. **Debug Mode**
   Set `log_level: DEBUG` for verbose logging

### Reporting Issues

Include:
- Home Assistant version
- Addon version
- Device configuration (sanitized)
- Relevant log excerpts
- Test suite output

### Contributing

Improvements welcome! Submit PRs to:
https://github.com/devmel/hass_airsend-addon

---

## Success Metrics

Your installation is successful when:
- ✅ Test suite passes all checks
- ✅ Physical remote updates HA within 2 seconds  
- ✅ Health sensor shows "on"
- ✅ No ERROR entries in logs
- ✅ Automatic recovery works after network interruption

---

*Last updated: 2024*
*Version: 2.0 - Enhanced with Bidirectional Reception*