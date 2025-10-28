#!/bin/bash

echo "========================================="
echo "Blue/Green Failover Test"
echo "========================================="
echo ""

# Test 1: Baseline
echo "Test 1: Baseline (Blue should be active)"
echo "---"
blue_count=0

for i in {1..5}; do
  pool=$(curl -si http://localhost:8080/version 2>/dev/null | grep "X-App-Pool:" | awk '{print $2}' | tr -d '\r\n ')
  echo "Request $i: Pool = $pool"
  
  if [ "$pool" = "blue" ]; then
    ((blue_count++))
  fi
done

echo ""
if [ $blue_count -eq 5 ]; then
  echo "✓ Baseline test passed - All traffic to Blue"
else
  echo "✗ Baseline test failed - Blue count: $blue_count/5"
  exit 1
fi
echo ""

# Test 2: Trigger chaos
echo "Test 2: Triggering chaos on Blue"
echo "---"
curl -s -X POST "http://localhost:8081/chaos/start?mode=error"
echo "Chaos activated"
sleep 2
echo ""

# Test 3: Failover test
echo "Test 3: Testing failover to Green (zero downtime expected)"
echo "---"
success_count=0
green_count=0
total_requests=20

for i in $(seq 1 $total_requests); do
  # Get HTTP code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/version)
  
  # Get pool from header
  pool=$(curl -si http://localhost:8080/version 2>/dev/null | grep "X-App-Pool:" | awk '{print $2}' | tr -d '\r\n ')
  
  if [ "$http_code" = "200" ]; then
    ((success_count++))
  fi
  
  if [ "$pool" = "green" ]; then
    ((green_count++))
  fi
  
  echo "Request $i: HTTP $http_code - Pool: $pool"
  sleep 0.5
done

echo ""
echo "========================================="
echo "Failover Results:"
echo "========================================="
echo "Total requests: $total_requests"
echo "Successful (200): $success_count"
echo "Routed to Green: $green_count"
success_rate=$(awk "BEGIN {printf \"%.0f\", ($success_count/$total_requests)*100}")
green_rate=$(awk "BEGIN {printf \"%.0f\", ($green_count/$total_requests)*100}")
echo "Success rate: $success_rate%"
echo "Green routing rate: $green_rate%"
echo ""

if [ $success_count -eq $total_requests ]; then
  echo "✓ Zero downtime - All requests succeeded"
else
  echo "✗ Had failures: $((total_requests - success_count)) requests failed"
fi

if [ $green_count -ge 19 ]; then
  echo "✓ Failover successful - ≥95% to Green"
else
  echo "✗ Failover incomplete - Only $green_count to Green"
fi
echo ""

# Test 4: Stop chaos
echo "Test 4: Stopping chaos"
echo "---"
curl -s -X POST "http://localhost:8081/chaos/stop"
echo "Chaos stopped - waiting for Blue recovery..."
sleep 5
echo ""

# Test 5: Recovery
echo "Test 5: Verifying Blue recovery"
echo "---"
recovery_blue=0

for i in {1..5}; do
  pool=$(curl -si http://localhost:8080/version 2>/dev/null | grep "X-App-Pool:" | awk '{print $2}' | tr -d '\r\n ')
  echo "Request $i: Pool = $pool"
  
  if [ "$pool" = "blue" ]; then
    ((recovery_blue++))
  fi
  
  sleep 0.5
done

echo ""
if [ $recovery_blue -ge 3 ]; then
  echo "✓ Recovery successful - Blue is back"
else
  echo "⚠ Partial recovery - Blue served $recovery_blue/5"
fi
echo ""

# Final verdict
echo "========================================="
echo "FINAL RESULT"
echo "========================================="

if [ $success_count -eq $total_requests ] && [ $green_count -ge 19 ]; then
  echo "✅ ALL TESTS PASSED"
  echo ""
  echo "Achievement unlocked:"
  echo "  ✓ Zero downtime during failover"
  echo "  ✓ 100% success rate ($success_count/$total_requests)"
  echo "  ✓ Automatic routing to Green ($green_count/$total_requests)"
  echo "  ✓ Headers preserved correctly"
  echo ""
  exit 0
else
  echo "❌ TESTS FAILED"
  echo ""
  [ $success_count -ne $total_requests ] && echo "  ✗ Had $((total_requests - success_count)) failed requests"
  [ $green_count -lt 19 ] && echo "  ✗ Only $green_count/$total_requests went to Green"
  echo ""
  exit 1
fi