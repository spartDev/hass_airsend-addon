<?php
/**
 * Enhanced Airsend Callback Handler with Bidirectional Reception
 * Version: 2.0
 * 
 * This file handles both emission (HA → Airsend) and reception (Remote → Airsend → HA)
 */

require_once dirname(__FILE__) . "/hassapi.class.php";

// Configuration
$BASE_HASS_API = "http://supervisor/core/api";
$HASS_API_TOKEN = @file_get_contents('hass_api.token');
$LOG_FILE = '/share/airsend_reception.log';
$CONFIG_FILE = '/config/airsend.yaml';
$SECRETS_FILE = '/config/secrets.yaml';
$LISTENING_STATE_FILE = '/tmp/airsend_listening.json';

// For external machine deployment
if (empty($HASS_API_TOKEN)) {
    // $BASE_HASS_API = "http://homeassistant.local:8123/api";
    // $HASS_API_TOKEN = 'your-token-here';
}

// Initialize logging
function logMessage($level, $message, $context = []) {
    global $LOG_FILE;
    $timestamp = date('Y-m-d H:i:s');
    $contextStr = !empty($context) ? ' ' . json_encode($context) : '';
    $logEntry = "[$timestamp] [$level] $message$contextStr\n";
    
    // Write to log file
    @file_put_contents($LOG_FILE, $logEntry, FILE_APPEND | LOCK_EX);
    
    // Also output to stdout for Docker logs
    if ($level === 'ERROR' || $level === 'WARNING') {
        error_log($logEntry);
    }
}

// YAML Parser (simple implementation without external dependencies)
class SimpleYAMLParser {
    public static function parse($content) {
        $lines = explode("\n", $content);
        $result = [];
        $currentKey = null;
        $currentIndent = 0;
        $stack = [&$result];
        
        foreach ($lines as $line) {
            // Skip comments and empty lines
            if (preg_match('/^\s*#/', $line) || trim($line) === '') {
                continue;
            }
            
            // Calculate indentation
            preg_match('/^(\s*)(.+)$/', $line, $matches);
            $indent = strlen($matches[1]);
            $content = trim($matches[2]);
            
            // Parse key-value pairs
            if (strpos($content, ':') !== false) {
                list($key, $value) = array_map('trim', explode(':', $content, 2));
                
                // Remove quotes if present
                $key = trim($key, '"\'');
                $value = trim($value, '"\'');
                
                // Handle indent levels
                $indentLevel = intval($indent / 2);
                while (count($stack) > $indentLevel + 1) {
                    array_pop($stack);
                }
                
                if ($value === '' || $value === '~' || $value === 'null') {
                    $stack[count($stack) - 1][$key] = [];
                    $stack[] = &$stack[count($stack) - 1][$key];
                } else {
                    // Convert values to appropriate types
                    if ($value === 'true') $value = true;
                    elseif ($value === 'false') $value = false;
                    elseif (is_numeric($value)) $value = is_float($value) ? floatval($value) : intval($value);
                    
                    $stack[count($stack) - 1][$key] = $value;
                }
            }
        }
        
        return $result;
    }
}

// Airsend API Client
class AirsendClient {
    private $devices = [];
    private $secrets = [];
    private $listeningStates = [];
    
    public function __construct() {
        $this->loadConfiguration();
        $this->loadListeningStates();
    }
    
    private function loadConfiguration() {
        global $CONFIG_FILE, $SECRETS_FILE;
        
        // Load secrets first to resolve references
        if (file_exists($SECRETS_FILE)) {
            $content = file_get_contents($SECRETS_FILE);
            $this->secrets = SimpleYAMLParser::parse($content);
            logMessage('INFO', 'Loaded secrets configuration');
        }
        
        // Load device configuration
        if (file_exists($CONFIG_FILE)) {
            $content = file_get_contents($CONFIG_FILE);
            $parsed = SimpleYAMLParser::parse($content);
            
            // Check if devices are under 'devices' key or at root level
            if (isset($parsed['devices'])) {
                $this->devices = $parsed['devices'];
            } else {
                $this->devices = $parsed;
            }
            
            // Process each device to resolve secrets and extract connection info
            foreach ($this->devices as $name => &$device) {
                // Handle spurl field if present
                if (isset($device['spurl'])) {
                    $spurl = $device['spurl'];
                    
                    // Resolve secret reference if present
                    if (strpos($spurl, '!secret') === 0) {
                        $secretKey = trim(str_replace('!secret', '', $spurl));
                        $spurl = $this->secrets[$secretKey] ?? $spurl;
                    }
                    
                    // Parse spurl to extract IP and password
                    if (preg_match('/sp:\/\/([^@]+)@([^:]+)(?::(\d+))?/', $spurl, $matches)) {
                        $device['password'] = $matches[1];
                        $device['ip'] = $matches[2];
                        if (isset($matches[3])) {
                            $device['port'] = $matches[3];
                        }
                    }
                }
                
                // Fallback to separate ip/password fields if no spurl
                if (!isset($device['ip']) && !isset($device['spurl'])) {
                    logMessage('WARNING', 'Device missing connection info', ['device' => $name]);
                }
            }
            
            logMessage('INFO', 'Loaded device configuration', ['devices' => count($this->devices)]);
        } else {
            logMessage('WARNING', 'Configuration file not found', ['file' => $CONFIG_FILE]);
        }
    }
    
    private function loadListeningStates() {
        global $LISTENING_STATE_FILE;
        
        if (file_exists($LISTENING_STATE_FILE)) {
            $content = file_get_contents($LISTENING_STATE_FILE);
            $this->listeningStates = json_decode($content, true) ?: [];
        }
    }
    
    private function saveListeningStates() {
        global $LISTENING_STATE_FILE;
        
        file_put_contents($LISTENING_STATE_FILE, json_encode($this->listeningStates, JSON_PRETTY_PRINT));
    }
    
    private function formatIPv6($ip) {
        // Handle IPv6 addresses with brackets for URL formatting
        if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
            return "[$ip]";
        }
        return $ip;
    }
    
    private function makeApiCall($ip, $password, $method, $params = []) {
        $formattedIp = $this->formatIPv6($ip);
        $url = "sp://$password@$formattedIp:33863/api/$method";
        
        $ch = curl_init();
        curl_setopt($ch, CURLOPT_URL, $url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 10);
        curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5);
        
        if (!empty($params)) {
            curl_setopt($ch, CURLOPT_POST, true);
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($params));
            curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
        }
        
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);
        
        if ($error) {
            logMessage('ERROR', 'API call failed', [
                'ip' => $formattedIp,
                'method' => $method,
                'error' => $error
            ]);
            return false;
        }
        
        if ($httpCode !== 200) {
            logMessage('ERROR', 'API call returned error', [
                'ip' => $formattedIp,
                'method' => $method,
                'http_code' => $httpCode,
                'response' => $response
            ]);
            return false;
        }
        
        logMessage('DEBUG', 'API call successful', [
            'ip' => $formattedIp,
            'method' => $method,
            'response' => substr($response, 0, 200)
        ]);
        
        return json_decode($response, true);
    }
    
    public function initializeListening() {
        $initialized = 0;
        $failed = 0;
        
        foreach ($this->devices as $name => $device) {
            if (!isset($device['channel']['listen']) || !$device['channel']['listen']) {
                continue;
            }
            
            $ip = $device['ip'] ?? null;
            $password = $device['password'] ?? $this->secrets['airsend_password'] ?? null;
            $channelId = $device['channel']['id'] ?? null;
            
            if (!$ip || !$password || !$channelId) {
                logMessage('WARNING', 'Missing configuration for device', ['device' => $name]);
                $failed++;
                continue;
            }
            
            // Set listening channel
            $result = $this->makeApiCall($ip, $password, 'setListenChannel', [
                'channel' => $channelId
            ]);
            
            if ($result === false) {
                $failed++;
                continue;
            }
            
            // Set callback URL
            $callbackUrl = $this->getCallbackUrl();
            $result = $this->makeApiCall($ip, $password, 'setCallback', [
                'url' => $callbackUrl
            ]);
            
            if ($result !== false) {
                $this->listeningStates[$name] = [
                    'enabled' => true,
                    'channel' => $channelId,
                    'timestamp' => time()
                ];
                $initialized++;
                logMessage('INFO', 'Initialized listening for device', [
                    'device' => $name,
                    'channel' => $channelId
                ]);
            } else {
                $failed++;
            }
        }
        
        $this->saveListeningStates();
        
        return [
            'initialized' => $initialized,
            'failed' => $failed,
            'total' => count($this->devices)
        ];
    }
    
    private function getCallbackUrl() {
        // Get the addon's internal IP
        $hostname = gethostbyname(gethostname());
        return "http://$hostname:33863/webhook";
    }
    
    public function getStatus() {
        return [
            'devices' => count($this->devices),
            'listening' => $this->listeningStates,
            'callback_url' => $this->getCallbackUrl()
        ];
    }
}

// Webhook Handler
class WebhookHandler {
    private $api;
    private $devices;
    
    public function __construct($api, $devices) {
        $this->api = $api;
        $this->devices = $devices;
    }
    
    public function handleRadioEvent($data) {
        logMessage('INFO', 'Received radio event', $data);
        
        // Extract event details
        $method = $data['method'] ?? null;
        $channel = $data['channel'] ?? null;
        $source = $data['source'] ?? null;
        $command = $data['command'] ?? null;
        $timestamp = $data['timestamp'] ?? time();
        
        if ($method !== 'radio' || !$channel || !$source || !$command) {
            logMessage('WARNING', 'Invalid radio event format', $data);
            return false;
        }
        
        // Find matching device
        $matchedDevice = null;
        $deviceName = null;
        
        foreach ($this->devices as $name => $device) {
            if (isset($device['channel']['id']) && $device['channel']['id'] == $channel) {
                if (isset($device['channel']['source']) && $device['channel']['source'] == $source) {
                    $matchedDevice = $device;
                    $deviceName = $name;
                    break;
                }
            }
        }
        
        if (!$matchedDevice) {
            logMessage('WARNING', 'No matching device found', [
                'channel' => $channel,
                'source' => $source
            ]);
            return false;
        }
        
        // Map command to Home Assistant state
        $state = $this->mapCommandToState($command);
        $entityId = $this->getEntityId($deviceName, $matchedDevice);
        
        if (!$entityId) {
            logMessage('ERROR', 'Could not determine entity ID', ['device' => $deviceName]);
            return false;
        }
        
        // Update Home Assistant entity
        $attributes = [
            'source' => 'physical_remote',
            'channel' => $channel,
            'command' => $command,
            'last_updated' => date('c', $timestamp)
        ];
        
        $result = $this->api->setState($entityId, $state, $state, $timestamp, null, $attributes);
        
        if ($result) {
            logMessage('INFO', 'Updated Home Assistant entity', [
                'entity_id' => $entityId,
                'state' => $state,
                'device' => $deviceName
            ]);
            
            // Fire custom event for automations
            $this->fireCustomEvent($entityId, $state, $command, $deviceName);
        }
        
        return $result;
    }
    
    private function mapCommandToState($command) {
        // Map Somfy RTS commands to Home Assistant states
        $mappings = [
            'up' => 'open',
            'down' => 'closed',
            'stop' => 'stopped',
            'my' => 'preset',
            'prog' => 'programming'
        ];
        
        return $mappings[strtolower($command)] ?? 'unknown';
    }
    
    private function getEntityId($deviceName, $device) {
        // Convert device name to Home Assistant entity ID format
        $entityId = preg_replace('/[^a-z0-9_]/', '_', strtolower($deviceName));
        $entityId = preg_replace('/_+/', '_', $entityId);
        
        // Determine entity type based on device type
        $type = $device['type'] ?? 4099;
        if ($type == 4099) { // Somfy RTS
            return "cover.airsend_$entityId";
        }
        
        return "switch.airsend_$entityId";
    }
    
    private function fireCustomEvent($entityId, $state, $command, $deviceName) {
        global $BASE_HASS_API, $HASS_API_TOKEN;
        
        $eventData = [
            'entity_id' => $entityId,
            'state' => $state,
            'command' => $command,
            'device_name' => $deviceName,
            'source' => 'airsend_reception'
        ];
        
        $ch = curl_init("$BASE_HASS_API/events/airsend_remote_pressed");
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($eventData));
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            "Authorization: Bearer $HASS_API_TOKEN",
            "Content-Type: application/json"
        ]);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);
        
        $result = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        
        if ($httpCode == 200 || $httpCode == 201) {
            logMessage('DEBUG', 'Fired custom event', $eventData);
        }
    }
}

// Main Application
class AirsendReceptionApp {
    private $api;
    private $client;
    private $webhookHandler;
    
    public function __construct() {
        global $BASE_HASS_API, $HASS_API_TOKEN;
        
        $this->api = new HassAPI($BASE_HASS_API, $HASS_API_TOKEN);
        
        if (!$this->api->isAuthorized()) {
            header("HTTP/1.1 401 Unauthorized");
            logMessage('ERROR', 'Unauthorized - missing API token');
            die("Unauthorized\n");
        }
        
        $this->client = new AirsendClient();
        $devices = $this->client->getStatus()['devices'];
        $this->webhookHandler = new WebhookHandler($this->api, $devices);
        
        logMessage('INFO', 'Airsend Reception App initialized');
    }
    
    public function handleRequest() {
        $method = $_SERVER['REQUEST_METHOD'];
        $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
        
        logMessage('DEBUG', 'Handling request', [
            'method' => $method,
            'path' => $path
        ]);
        
        switch ($path) {
            case '/initialize':
                $this->handleInitialize();
                break;
                
            case '/webhook':
                $this->handleWebhook();
                break;
                
            case '/status':
                $this->handleStatus();
                break;
                
            case '/logs':
                $this->handleLogs();
                break;
                
            default:
                // Handle legacy emission events (backward compatibility)
                $this->handleLegacyEmission();
                break;
        }
    }
    
    private function handleInitialize() {
        header('Content-Type: application/json');
        
        $result = $this->client->initializeListening();
        
        echo json_encode([
            'success' => $result['failed'] == 0,
            'result' => $result,
            'timestamp' => time()
        ]);
    }
    
    private function handleWebhook() {
        header('Content-Type: application/json');
        
        $raw = file_get_contents('php://input');
        $data = json_decode($raw, true);
        
        if (!$data) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid JSON']);
            return;
        }
        
        $result = $this->webhookHandler->handleRadioEvent($data);
        
        echo json_encode([
            'success' => $result,
            'timestamp' => time()
        ]);
    }
    
    private function handleStatus() {
        header('Content-Type: application/json');
        
        $status = $this->client->getStatus();
        $status['api_authorized'] = $this->api->isAuthorized();
        $status['timestamp'] = time();
        
        echo json_encode($status);
    }
    
    private function handleLogs() {
        global $LOG_FILE;
        
        header('Content-Type: text/plain');
        
        $lines = $_GET['lines'] ?? 100;
        $lines = min(1000, max(1, intval($lines)));
        
        if (file_exists($LOG_FILE)) {
            $content = file_get_contents($LOG_FILE);
            $logLines = explode("\n", $content);
            $logLines = array_slice($logLines, -$lines);
            echo implode("\n", $logLines);
        } else {
            echo "No logs available\n";
        }
    }
    
    private function handleLegacyEmission() {
        // Original callback.php functionality for backward compatibility
        $raw = file_get_contents('php://input');
        $data = json_decode($raw, true, 512, JSON_BIGINT_AS_STRING);
        
        if (is_array($data) && isset($data['events'])) {
            foreach ($data['events'] as $i => $val) {
                if (isset($val['channel']) && isset($val['type']) && isset($val['thingnotes'])) {
                    // Transfer event
                    if (isset($val['thingnotes']['uid'])) {
                        $entity_id = $this->api->searchEntityId($val['thingnotes']['uid']);
                        if (isset($entity_id)) {
                            if ($val['type'] == 3 || $val['type'] == 2 || $val['type'] == 1) {
                                $states = $this->api->convertNotesToStates($val['thingnotes']['notes']);
                                foreach ($states as $j => $state) {
                                    $this->api->setState($entity_id, $state[0], $state[1], $val['timestamp']);
                                }
                            } else {
                                $this->api->setState($entity_id, 'error', 'error_' . $val['type'], $val['timestamp']);
                            }
                        }
                    // Interrupt event
                    } else {
                        if ($val['type'] == 3) { // Event type GOT (sensor)
                            $isreliable = false;
                            if ($val['reliability'] > 0x6 && $val['reliability'] < 0x47) {
                                $isreliable = true;
                            }
                            if ($isreliable == true) {
                                $states = $this->api->convertNotesToStates($val['thingnotes']['notes']);
                                foreach ($states as $j => $state) {
                                    // Search entity and update
                                    $entities = $this->api->searchEntitiesFromChannelAndType($val['channel'], $state[0]);
                                    foreach ($entities as $k => $entity_id) {
                                        $this->api->setState($entity_id, $state[0], $state[1], $val['timestamp']);
                                    }
                                    // Creates if not exists
                                    if (count($entities) == 0) {
                                        logMessage('INFO', 'New channel found', [
                                            'channel' => json_encode($val['channel']),
                                            'type' => $state[0],
                                            'value' => $state[1]
                                        ]);
                                        $this->api->setState(null, $state[0], $state[1], $val['timestamp'], $val['channel']);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        echo json_encode(['success' => true]);
    }
}

// Initialize and run application
try {
    $app = new AirsendReceptionApp();
    $app->handleRequest();
} catch (Exception $e) {
    logMessage('ERROR', 'Application error', [
        'message' => $e->getMessage(),
        'trace' => $e->getTraceAsString()
    ]);
    
    header("HTTP/1.1 500 Internal Server Error");
    echo json_encode(['error' => 'Internal server error']);
}
?>