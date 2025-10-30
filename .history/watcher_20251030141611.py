#!/usr/bin/env python3
"""
Nginx Log Watcher - Monitors Nginx logs and sends Slack alerts
for failover events and high error rates.
"""

import os
import re
import time
import subprocess
import requests
from collections import deque
from datetime import datetime

# Configuration from environment variables
SLACK_WEBHOOK_URL = os.getenv('SLACK_WEBHOOK_URL', '')
ERROR_RATE_THRESHOLD = float(os.getenv('ERROR_RATE_THRESHOLD', '2'))  # percentage
WINDOW_SIZE = int(os.getenv('WINDOW_SIZE', '200'))  # requests
ALERT_COOLDOWN_SEC = int(os.getenv('ALERT_COOLDOWN_SEC', '300'))  # 5 minutes
LOG_FILE = '/var/log/nginx/access.log'

# State tracking
last_pool = None
request_window = deque(maxlen=WINDOW_SIZE)
last_failover_alert = 0
last_error_alert = 0

# Log parsing regex
LOG_PATTERN = re.compile(
    r'pool="(?P<pool>[^"]*)" '
    r'release="(?P<release>[^"]*)" '
    r'upstream_status="(?P<upstream_status>[^"]*)" '
    r'upstream_addr="(?P<upstream_addr>[^"]*)"'
)

def send_slack_alert(message, alert_type="info"):
    """Send alert to Slack"""
    if not SLACK_WEBHOOK_URL:
        print(f"⚠️  No Slack webhook configured. Alert: {message}")
        return False
    
    emoji = {
        "failover": "🔄",
        "error": "🚨",
        "recovery": "✅",
        "info": "ℹ️"
    }.get(alert_type, "📢")
    
    payload = {
        "text": f"{emoji} *DevOps Alert*",
        "blocks": [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": f"{emoji} DevOps Stage 3 Alert"
                }
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": message
                }
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
                    }
                ]
            }
        ]
    }
    
    try:
        response = requests.post(SLACK_WEBHOOK_URL, json=payload, timeout=5)
        if response.status_code == 200:
            print(f"✅ Slack alert sent: {alert_type}")
            return True
        else:
            print(f"❌ Slack alert failed: HTTP {response.status_code}")
            print(f"   Response: {response.text[:100]}")
            return False
    except Exception as e:
        print(f"❌ Error sending Slack alert: {e}")
        return False

def check_failover(pool):
    """Check if failover occurred"""
    global last_pool, last_failover_alert
    
    if last_pool is None:
        last_pool = pool
        print(f"📍 Initial pool: {pool}")
        return
    
    if pool != last_pool:
        # Failover detected
        current_time = time.time()
        
        # Check cooldown
        if current_time - last_failover_alert < ALERT_COOLDOWN_SEC:
            print(f"⏳ Failover detected but in cooldown ({int(current_time - last_failover_alert)}s ago)")
            last_pool = pool
            return
        
        message = (
            f"*Failover Detected!*\n\n"
            f"• Previous Pool: `{last_pool}`\n"
            f"• Current Pool: `{pool}`\n"
            f"• Direction: `{last_pool} → {pool}`\n\n"
            f"*Action Required:*\n"
            f"Check health of `{last_pool}` container and investigate cause of failover."
        )
        
        send_slack_alert(message, "failover")
        last_failover_alert = current_time
        print(f"🔄 FAILOVER: {last_pool} → {pool}")
        last_pool = pool

def check_error_rate():
    """Check if error rate exceeds threshold"""
    global last_error_alert
    
    if len(request_window) < 10:  # Need minimum requests
        return
    
    error_count = sum(1 for status in request_window if status >= 500)
    error_rate = (error_count / len(request_window)) * 100
    
    if error_rate > ERROR_RATE_THRESHOLD:
        current_time = time.time()
        
        # Check cooldown
        if current_time - last_error_alert < ALERT_COOLDOWN_SEC:
            return
        
        message = (
            f"*High Error Rate Alert!*\n\n"
            f"• Error Rate: `{error_rate:.2f}%`\n"
            f"• Threshold: `{ERROR_RATE_THRESHOLD}%`\n"
            f"• Errors: `{error_count}/{len(request_window)}` requests\n"
            f"• Window Size: `{WINDOW_SIZE}` requests\n\n"
            f"*Action Required:*\n"
            f"Investigate upstream logs and consider toggling pools if issues persist."
        )
        
        send_slack_alert(message, "error")
        last_error_alert = current_time
        print(f"🚨 ERROR RATE: {error_rate:.2f}% ({error_count}/{len(request_window)})")

def parse_log_line(line):
    """Parse Nginx log line and extract relevant fields"""
    match = LOG_PATTERN.search(line)
    if not match:
        return None
    
    data = match.groupdict()
    
    # Parse upstream_status (can be comma-separated for retries)
    upstream_status = data['upstream_status']
    if upstream_status and upstream_status != '-':
        # Take the last status (final response)
        statuses = upstream_status.split(',')
        try:
            status_code = int(statuses[-1].strip())
        except ValueError:
            status_code = 0
    else:
        status_code = 0
    
    return {
        'pool': data['pool'] if data['pool'] != '-' else 'unknown',
        'release': data['release'] if data['release'] != '-' else 'unknown',
        'upstream_status': status_code,
        'upstream_addr': data['upstream_addr']
    }

def tail_log_file():
    """Tail the log file and process lines in real-time"""
    print(f"👀 Watching log file: {LOG_FILE}")
    print(f"📊 Config: Threshold={ERROR_RATE_THRESHOLD}%, Window={WINDOW_SIZE}, Cooldown={ALERT_COOLDOWN_SEC}s")
    
    # Wait for log file to exist
    while not os.path.exists(LOG_FILE):
        print(f"⏳ Waiting for log file to be created...")
        time.sleep(2)
    
    print(f"✅ Log file found, starting to monitor...")
    
    # Use tail command to follow log file (more reliable than file.seek)
    try:
        process = subprocess.Popen(
            ['tail', '-F', '-n', '0', LOG_FILE],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            bufsize=1
        )
        
        # Process each line as it comes
        for line in iter(process.stdout.readline, ''):
            if not line:
                continue
            
            line = line.strip()
            if not line:
                continue
            
            # Parse log line
            data = parse_log_line(line)
            if not data:
                continue
            
            pool = data['pool']
            status = data['upstream_status']
            
            # Track request in window
            if status > 0:
                request_window.append(status)
            
            # Check for failover
            if pool and pool != 'unknown':
                check_failover(pool)
            
            # Check error rate
            check_error_rate()
            
    except Exception as e:
        print(f"❌ Error in tail_log_file: {e}")
        raise
    finally:
        if 'process' in locals():
            process.terminate()
            process.wait()

def main():
    """Main entry point"""
    print("=" * 60)
    print("🚀 DevOps Stage 3 - Log Watcher Started")
    print("=" * 60)
    
    if not SLACK_WEBHOOK_URL:
        print("⚠️  WARNING: SLACK_WEBHOOK_URL not set. Alerts will only print to console.")
    else:
        print(f"✅ Slack webhook configured: {SLACK_WEBHOOK_URL[:50]}...")
    
    # Send startup notification
    send_slack_alert(
        "*Log Watcher Started*\n\n"
        f"• Monitoring: Nginx access logs\n"
        f"• Error Threshold: {ERROR_RATE_THRESHOLD}%\n"
        f"• Window Size: {WINDOW_SIZE} requests\n"
        f"• Alert Cooldown: {ALERT_COOLDOWN_SEC}s",
        "info"
    )
    
    try:
        tail_log_file()
    except KeyboardInterrupt:
        print("\n👋 Log watcher stopped by user")
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        send_slack_alert(f"*Log Watcher Error*\n\n```{str(e)}```", "error")

if __name__ == "__main__":
    main()