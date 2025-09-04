#!/bin/bash

# Airsend Reception Test Suite
# This script validates the reception system functionality

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_LOG="/share/airsend_test_$(date +%Y%m%d_%H%M%S).log"
ADDON_URL="http://localhost:33863"
TEST_RESULTS=()
FAILED_TESTS=0
PASSED_TESTS=0

# Logging functions
log() {
    echo -e "$1" | tee -a "$TEST_LOG"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1" | tee -a "$TEST_LOG"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1" | tee -a "$TEST_LOG"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $1")
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" | tee -a "$TEST_LOG"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TEST_RESULTS+=("FAIL: $1")
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$TEST_LOG"
}

log_info() {
    echo -e "[INFO] $1" | tee -a "$TEST_LOG"
}

# Helper functions
check_service() {
    local service=$1
    if pgrep -f "$service" > /dev/null; then
        return 0
    else
        return 1
    fi
}

make_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local response
    
    if [ "$method" = "GET" ]; then
        response=$(curl -s -w "\n%{http_code}" "$ADDON_URL$endpoint" 2>/dev/null || echo "000")
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
                   -H "Content-Type: application/json" \
                   -d "$data" \
                   "$ADDON_URL$endpoint" 2>/dev/null || echo "000")
    fi
    
    echo "$response"
}

# Test functions
test_prerequisites() {
    log_test "Checking prerequisites..."
    
    # Check if running in Home Assistant
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        log_pass "Running in Home Assistant Supervisor environment"
    else
        log_warn "Not running in Home Assistant Supervisor environment"
    fi
    
    # Check required files
    local required_files=(
        "/home/callback_enhanced.php"
        "/home/init_reception.sh"
        "/home/hassapi.class.php"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            log_pass "Required file exists: $file"
        else
            log_fail "Required file missing: $file"
        fi
    done
    
    # Check required commands
    local required_commands=(
        "php"
        "curl"
        "jq"
    )
    
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" > /dev/null; then
            log_pass "Required command available: $cmd"
        else
            log_fail "Required command missing: $cmd"
        fi
    done
}

test_services() {
    log_test "Checking running services..."
    
    # Check AirSendWebService
    if check_service "AirSendWebService"; then
        log_pass "AirSendWebService is running"
    else
        log_fail "AirSendWebService is not running"
    fi
    
    # Check PHP server
    if check_service "php.*callback"; then
        log_pass "PHP callback server is running"
    else
        log_fail "PHP callback server is not running"
    fi
    
    # Check if port 33863 is listening
    if netstat -ln | grep -q ":33863"; then
        log_pass "Port 33863 is listening"
    else
        log_fail "Port 33863 is not listening"
    fi
}

test_api_endpoints() {
    log_test "Testing API endpoints..."
    
    # Test status endpoint
    response=$(make_request "GET" "/status")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Status endpoint responding (HTTP $http_code)"
        
        # Check if response is valid JSON
        if echo "$body" | jq . > /dev/null 2>&1; then
            log_pass "Status endpoint returns valid JSON"
            
            # Check API authorization
            if echo "$body" | jq -e '.api_authorized == true' > /dev/null 2>&1; then
                log_pass "API is authorized"
            else
                log_fail "API is not authorized"
            fi
        else
            log_fail "Status endpoint returns invalid JSON"
        fi
    else
        log_fail "Status endpoint not responding (HTTP $http_code)"
    fi
    
    # Test logs endpoint
    response=$(make_request "GET" "/logs?lines=10")
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Logs endpoint responding (HTTP $http_code)"
    else
        log_fail "Logs endpoint not responding (HTTP $http_code)"
    fi
}

test_initialization() {
    log_test "Testing initialization endpoint..."
    
    response=$(make_request "GET" "/initialize")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Initialize endpoint responding (HTTP $http_code)"
        
        if echo "$body" | jq . > /dev/null 2>&1; then
            log_pass "Initialize endpoint returns valid JSON"
            
            # Check initialization result
            if echo "$body" | jq -e '.success' > /dev/null 2>&1; then
                local success=$(echo "$body" | jq -r '.success')
                if [ "$success" = "true" ]; then
                    log_pass "Initialization successful"
                else
                    log_warn "Initialization reported failure (may be due to missing config)"
                fi
                
                # Display initialization details
                local initialized=$(echo "$body" | jq -r '.result.initialized // 0')
                local failed=$(echo "$body" | jq -r '.result.failed // 0')
                local total=$(echo "$body" | jq -r '.result.total // 0')
                
                log_info "Devices initialized: $initialized/$total (failed: $failed)"
            else
                log_fail "Initialize response missing success field"
            fi
        else
            log_fail "Initialize endpoint returns invalid JSON"
        fi
    else
        log_fail "Initialize endpoint not responding (HTTP $http_code)"
    fi
}

test_webhook() {
    log_test "Testing webhook endpoint..."
    
    # Create test webhook data (simulating physical remote press)
    local test_data='{
        "method": "radio",
        "channel": 13920,
        "source": 567765,
        "command": "down",
        "timestamp": '$(date +%s)',
        "reliability": 10
    }'
    
    response=$(make_request "POST" "/webhook" "$test_data")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Webhook endpoint responding (HTTP $http_code)"
        
        if echo "$body" | jq . > /dev/null 2>&1; then
            log_pass "Webhook endpoint returns valid JSON"
            
            # Note: Success may be false if no matching device configured
            local success=$(echo "$body" | jq -r '.success // false')
            if [ "$success" = "true" ]; then
                log_pass "Webhook processed successfully"
            else
                log_warn "Webhook processed but no matching device (expected if not configured)"
            fi
        else
            log_fail "Webhook endpoint returns invalid JSON"
        fi
    else
        log_fail "Webhook endpoint not responding (HTTP $http_code)"
    fi
}

test_configuration() {
    log_test "Checking configuration files..."
    
    # Check for airsend.yaml
    if [ -f "/config/airsend.yaml" ]; then
        log_pass "Configuration file exists: /config/airsend.yaml"
        
        # Validate YAML syntax (basic check)
        if grep -E "^[a-zA-Z0-9_]+:" "/config/airsend.yaml" > /dev/null; then
            log_pass "Configuration file appears to have valid YAML structure"
        else
            log_warn "Configuration file may have invalid YAML structure"
        fi
    else
        log_warn "Configuration file not found: /config/airsend.yaml"
        log_info "Create this file to configure devices for reception"
    fi
    
    # Check for secrets.yaml
    if [ -f "/config/secrets.yaml" ]; then
        log_pass "Secrets file exists: /config/secrets.yaml"
    else
        log_warn "Secrets file not found: /config/secrets.yaml"
    fi
}

test_logging() {
    log_test "Checking logging functionality..."
    
    # Check if log file exists
    if [ -f "/share/airsend_reception.log" ]; then
        log_pass "Reception log file exists"
        
        # Check if log file is being written to
        local log_size=$(stat -c%s "/share/airsend_reception.log" 2>/dev/null || echo "0")
        if [ "$log_size" -gt 0 ]; then
            log_pass "Log file is being written to (size: $log_size bytes)"
            
            # Check recent log entries
            local recent_logs=$(tail -n 5 "/share/airsend_reception.log" 2>/dev/null | wc -l)
            if [ "$recent_logs" -gt 0 ]; then
                log_pass "Recent log entries found"
            fi
        else
            log_warn "Log file is empty"
        fi
    else
        log_warn "Reception log file not found"
    fi
}

test_home_assistant_integration() {
    log_test "Testing Home Assistant integration..."
    
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        # Test connection to Home Assistant API
        response=$(curl -s -o /dev/null -w "%{http_code}" \
                   -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                   "http://supervisor/core/api/" 2>/dev/null || echo "000")
        
        if [ "$response" = "200" ]; then
            log_pass "Successfully connected to Home Assistant API"
        else
            log_fail "Failed to connect to Home Assistant API (HTTP $response)"
        fi
        
        # Check if we can read states
        response=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                   "http://supervisor/core/api/states" 2>/dev/null)
        
        if echo "$response" | jq -e 'type == "array"' > /dev/null 2>&1; then
            log_pass "Can read Home Assistant states"
            
            # Count Airsend entities
            local airsend_entities=$(echo "$response" | jq '[.[] | select(.entity_id | startswith("cover.airsend_"))] | length')
            log_info "Found $airsend_entities Airsend cover entities"
        else
            log_fail "Cannot read Home Assistant states"
        fi
    else
        log_warn "Not running in Supervisor environment, skipping HA integration tests"
    fi
}

simulate_remote_press() {
    log_test "Simulating remote button press..."
    
    local device_name="test_shutter"
    local channel_id=13920
    local source_id=567765
    
    log_info "Simulating DOWN command for $device_name"
    
    # Create realistic webhook data
    local webhook_data='{
        "method": "radio",
        "channel": '$channel_id',
        "source": '$source_id',
        "command": "down",
        "timestamp": '$(date +%s)',
        "reliability": 15,
        "rssi": -65,
        "frequency": 433.92
    }'
    
    response=$(make_request "POST" "/webhook" "$webhook_data")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Remote press simulation sent successfully"
        log_info "Response: $body"
    else
        log_fail "Remote press simulation failed (HTTP $http_code)"
    fi
    
    sleep 2
    
    log_info "Simulating UP command for $device_name"
    
    webhook_data='{
        "method": "radio",
        "channel": '$channel_id',
        "source": '$source_id',
        "command": "up",
        "timestamp": '$(date +%s)',
        "reliability": 15,
        "rssi": -65,
        "frequency": 433.92
    }'
    
    response=$(make_request "POST" "/webhook" "$webhook_data")
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "Second remote press simulation sent successfully"
    else
        log_fail "Second remote press simulation failed"
    fi
}

# Performance test
test_performance() {
    log_test "Testing performance and response times..."
    
    local total_time=0
    local iterations=10
    
    for i in $(seq 1 $iterations); do
        local start_time=$(date +%s%N)
        response=$(curl -s -o /dev/null -w "%{http_code}" "$ADDON_URL/status" 2>/dev/null)
        local end_time=$(date +%s%N)
        
        if [ "$response" = "200" ]; then
            local elapsed=$((($end_time - $start_time) / 1000000))
            total_time=$((total_time + elapsed))
        fi
    done
    
    local avg_time=$((total_time / iterations))
    
    if [ $avg_time -lt 100 ]; then
        log_pass "Average response time: ${avg_time}ms (excellent)"
    elif [ $avg_time -lt 500 ]; then
        log_pass "Average response time: ${avg_time}ms (good)"
    elif [ $avg_time -lt 1000 ]; then
        log_warn "Average response time: ${avg_time}ms (acceptable)"
    else
        log_fail "Average response time: ${avg_time}ms (too slow)"
    fi
}

# Generate test report
generate_report() {
    log ""
    log "========================================="
    log "       AIRSEND RECEPTION TEST REPORT     "
    log "========================================="
    log ""
    log "Test Date: $(date)"
    log "Test Log: $TEST_LOG"
    log ""
    log "Test Results Summary:"
    log "  Passed: $PASSED_TESTS"
    log "  Failed: $FAILED_TESTS"
    log "  Total:  $((PASSED_TESTS + FAILED_TESTS))"
    log ""
    
    if [ $FAILED_TESTS -eq 0 ]; then
        log "${GREEN}✓ All tests passed successfully!${NC}"
    else
        log "${RED}✗ Some tests failed. Please review the results.${NC}"
    fi
    
    log ""
    log "Detailed Results:"
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == PASS* ]]; then
            log "  ${GREEN}✓${NC} ${result#PASS: }"
        else
            log "  ${RED}✗${NC} ${result#FAIL: }"
        fi
    done
    
    log ""
    log "========================================="
    
    # Save summary to share
    {
        echo "Test completed at $(date)"
        echo "Passed: $PASSED_TESTS, Failed: $FAILED_TESTS"
    } > /share/airsend_test_summary.txt
}

# Main execution
main() {
    log "========================================="
    log "    AIRSEND RECEPTION VALIDATION TEST    "
    log "========================================="
    log ""
    
    # Run all tests
    test_prerequisites
    test_services
    test_api_endpoints
    test_initialization
    test_webhook
    test_configuration
    test_logging
    test_home_assistant_integration
    test_performance
    
    # Optional: simulate remote press
    if [ "${1:-}" = "--simulate" ]; then
        simulate_remote_press
    fi
    
    # Generate report
    generate_report
    
    # Exit with appropriate code
    if [ $FAILED_TESTS -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Run tests
main "$@"