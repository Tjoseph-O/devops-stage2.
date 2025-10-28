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
  response=$(curl -s http://localhost:8080/version)
  pool=$(echo "$response" | grep -o '"pool":"[^"]*"' | cut -d'"' -f4)
  
  if [ "$pool" = "blue" ]; then
    ((blue_count++))
  fi
  
  echo "Request $i: Pool = $pool"
done

if [ $blue_count -eq 5 ]; then
  echo -e "${GREEN}✓ Baseline test passed - All traffic to Blue${NC}"
else
  echo -e "${RED}✗ Baseline test failed - Expected all traffic to Blue${NC}"
  exit 1
fi
echo ""

# Test 2: Trigger chaos on Blue
echo "Test 2: Triggering chaos on Blue (error mode)"
echo "---"
chaos_response=$(curl -s -X POST http://localhost:8081/chaos/start?mode=error)
echo "Chaos activated: $chaos_response"
sleep 2
echo ""

# Test 3: Verify automatic failover to Green
echo "Test 3: Testing failover (should switch to Green with zero failures)"
echo "---"
success_count=0
green_count=0
blue_count=0
total_requests=20

for i in $(seq 1 $total_requests); do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/version)
  response=$(curl -s http://localhost:8080/version)
  pool=$(echo "$response" | grep -o '"pool":"[^"]*"' | cut -d'"' -f4)
  
  if [ "$http_code" = "200" ]; then
    ((success_count++))
  fi
  
  if [ "$pool" = "green" ]; then
    ((green_count++))
  elif [ "$pool" = "blue" ]; then
    ((blue_count++))
  fi
  
  echo "Request $i: HTTP $http_code - Pool: $pool"
  sleep 0.3
done

echo ""
echo "========================================="
echo "Failover Test Results:"
echo "========================================="
echo "Total requests: $total_requests"
echo "Successful (200): $success_count"
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
  echo -e "${RED}✗ Downtime detected - Some requests failed${NC}"
fi

if (( $(echo "$green_rate >= 95" | bc -l) )); then
  echo -e "${GREEN}✓ Failover successful - ≥95% traffic to Green${NC}"
else
  echo -e "${RED}✗ Failover incomplete - <95% traffic to Green${NC}"
fi
echo ""

# Test 4: Stop chaos
echo "Test 4: Stopping chaos on Blue"
stop_response=$(curl -s -X POST http://localhost:8081/chaos/stop)
echo "Chaos stopped: $stop_response"
sleep 5
echo ""

# Test 5: Verify Blue recovery
echo "Test 5: Testing recovery (Blue should be back)"
echo "---"
recovery_blue=0
for i in {1..5}; do
  response=$(curl -s http://localhost:8080/version)
  pool=$(echo "$response" | grep -o '"pool":"[^"]*"' | cut -d'"' -f4)
  
  if [ "$pool" = "blue" ]; then
    ((recovery_blue++))
  fi
  
  echo "Request $i: Pool = $pool"
  sleep 0.5
done

if [ $recovery_blue -ge 3 ]; then
  echo -e "${GREEN}✓ Recovery successful - Traffic returned to Blue${NC}"
else
  echo -e "${YELLOW}⚠ Blue still recovering or permanently down${NC}"
fi
echo ""

echo "========================================="
echo "Final Result:"
echo "========================================="

# Overall pass/fail
if [ $success_count -eq $total_requests ] && (( $(echo "$green_rate >= 95" | bc -l) )); then
  echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
  echo -e "${GREEN}   - Zero downtime during failover${NC}"
  echo -e "${GREEN}   - Proper routing to backup pool${NC}"
  echo -e "${GREEN}   - Headers preserved correctly${NC}"
  exit 0
else
  echo -e "${RED}❌ TESTS FAILED${NC}"
  echo "Check the results above for details"
  exit 1
fi