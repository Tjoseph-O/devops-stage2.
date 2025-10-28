#!/bin/bash

set -e

echo "========================================="
echo "Blue/Green Failover Test"
echo "========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Baseline - Blue should be active
echo "Test 1: Baseline (Blue active)"
echo "---"
blue_count=0

for i in {1..5}; do
  # Get both headers and body
  response=$(curl -si http://localhost:8080/version)
  
  # Extract pool from header (X-App-Pool)
  pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
  
  # If header doesn't exist, try from JSON body
  if [ -z "$pool" ]; then
    pool=$(echo "$response" | grep -o '"pool":"[^"]*"' | cut -d'"' -f4)
  fi
  
  echo "Request $i: Pool = $pool"
  
  if [ "$pool" = "blue" ]; then
    ((blue_count++))
  fi
done

echo ""
if [ $blue_count -eq 5 ]; then
  echo -e "${GREEN}✓ Baseline test passed - All traffic to Blue${NC}"
else
  echo -e "${RED}✗ Baseline test failed - Blue count: $blue_count/5${NC}"
  exit 1
fi
echo ""

# Test 2: Trigger chaos on Blue
echo "Test 2: Triggering chaos on Blue (error mode)"
echo "---"
curl -s -X POST "http://localhost:8081/chaos/start?mode=error"
echo "Chaos activated on Blue"
sleep 3
echo ""

# Test 3: Verify automatic failover to Green
echo "Test 3: Testing failover (should switch to Green with zero failures)"
echo "---"
success_count=0
green_count=0
blue_count=0
error_count=0
total_requests=20

for i in $(seq 1 $total_requests); do
  # Get HTTP status code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/version)
  
  # Get headers for pool info
  pool_header=$(curl -si http://localhost:8080/version 2>/dev/null | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
  
  if [ "$http_code" = "200" ]; then
    ((success_count++))
  else
    ((error_count++))
  fi
  
  if [ "$pool_header" = "green" ]; then
    ((green_count++))
  elif [ "$pool_header" = "blue" ]; then
    ((blue_count++))
  fi
  
  echo "Request $i: HTTP $http_code - Pool: $pool_header"
  sleep 0.5
done

echo ""
echo "========================================="
echo "Failover Test Results:"
echo "========================================="
echo "Total requests: $total_requests"
echo "Successful (200): $success_count"
echo "Failed (non-200): $error_count"
echo "Routed to Blue: $blue_count"
echo "Routed to Green: $green_count"
success_rate=$(awk "BEGIN {printf \"%.1f\", ($success_count/$total_requests)*100}")
green_rate=$(awk "BEGIN {printf \"%.1f\", ($green_count/$total_requests)*100}")
echo "Success rate: $success_rate%"
echo "Green routing rate: $green_rate%"
echo ""

# Evaluate results
if [ $success_count -eq $total_requests ]; then
  echo -e "${GREEN}✓ Zero downtime achieved - All requests succeeded${NC}"
else
  echo -e "${RED}✗ Downtime detected - $error_count requests failed${NC}"
fi

if [ $green_count -ge 19 ]; then
  echo -e "${GREEN}✓ Failover successful - ≥95% traffic to Green${NC}"
else
  echo -e "${RED}✗ Failover incomplete - Only $green_count/$total_requests to Green${NC}"
fi
echo ""

# Test 4: Stop chaos
echo "Test 4: Stopping chaos on Blue"
curl -s -X POST "http://localhost:8081/chaos/stop"
echo "Chaos stopped"
sleep 5
echo ""

# Test 5: Verify Blue recovery
echo "Test 5: Testing recovery (Blue should be back)"
echo "---"
recovery_blue=0
for i in {1..5}; do
  pool_header=$(curl -si http://localhost:8080/version 2>/dev/null | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
  
  echo "Request $i: Pool = $pool_header"
  
  if [ "$pool_header" = "blue" ]; then
    ((recovery_blue++))
  fi
  
  sleep 0.5
done

echo ""
if [ $recovery_blue -ge 3 ]; then
  echo -e "${GREEN}✓ Recovery successful - Traffic returned to Blue${NC}"
else
  echo -e "${YELLOW}⚠ Partial recovery - Blue served $recovery_blue/5 requests${NC}"
fi
echo ""

echo "========================================="
echo "Final Result:"
echo "========================================="

# Overall pass/fail
if [ $success_count -eq $total_requests ] && [ $green_count -ge 19 ]; then
  echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
  echo -e "${GREEN}   - Zero downtime during failover${NC}"
  echo -e "${GREEN}   - Proper routing to backup pool${NC}"
  echo -e "${GREEN}   - Headers preserved correctly${NC}"
  exit 0
else
  echo -e "${RED}❌ TESTS FAILED${NC}"
  [ $error_count -gt 0 ] && echo -e "${RED}   - Had $error_count failed requests${NC}"
  [ $green_count -lt 19 ] && echo -e "${RED}   - Only $green_count requests went to Green${NC}"
  exit 1
fi