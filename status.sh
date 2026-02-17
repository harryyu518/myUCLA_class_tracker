#!/bin/bash
# UCLA ClassSearch Monitor Status Command
# Shows all important monitoring info in one view

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   UCLA ClassSearch Monitor Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if running
echo ""
echo "📊 Process Status:"
if pgrep -f "monitor_classsearch.py" > /dev/null; then
    PID=$(pgrep -f "monitor_classsearch.py" | head -1)
    echo "  ✅ Running (PID: $PID)"
else
    echo "  ❌ NOT Running"
fi

# Check LaunchAgent status
echo ""
echo "🔧 LaunchAgent Status:"
if launchctl list com.myucla.classsearch.monitor 2>/dev/null | grep -q "PID"; then
    echo "  ✅ Loaded"
    launchctl list com.myucla.classsearch.monitor 2>/dev/null | grep PID | awk '{print "     "$0}'
else
    echo "  ❌ Not Loaded"
fi

# Show latest snapshots and timestamps
echo ""
echo "📁 Snapshot Files:"
cd <LOCAL_REPO> 2>/dev/null || exit 1
LATEST=$(ls -t snapshots/classsearch_*.html 2>/dev/null | head -1)
SECOND=$(ls -t snapshots/classsearch_*.html 2>/dev/null | head -2 | tail -1)

if [ -n "$LATEST" ]; then
    LATEST_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LATEST")
    LATEST_SIZE=$(ls -lh "$LATEST" | awk '{print $5}')
    echo "  Latest:  $LATEST"
    echo "           Size: $LATEST_SIZE | Time: $LATEST_TIME"
    
    # Calculate time elapsed
    LATEST_TS=$(stat -f "%m" "$LATEST")
    NOW=$(date +%s)
    ELAPSED=$((NOW - LATEST_TS))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    echo "           ⏱️  Elapsed: ${MINUTES}m ${SECONDS}s ago"
fi

if [ -n "$SECOND" ]; then
    SECOND_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$SECOND")
    SECOND_SIZE=$(ls -lh "$SECOND" | awk '{print $5}')
    echo ""
    echo "  Previous: $SECOND"
    echo "            Size: $SECOND_SIZE | Time: $SECOND_TIME"
fi

# Check for changes
echo ""
echo "🔍 Content Comparison:"
if [ -n "$LATEST" ] && [ -n "$SECOND" ]; then
    DIFF=$(diff -q "$SECOND" "$LATEST" 2>/dev/null)
    if [ -z "$DIFF" ]; then
        echo "  ✅ No changes detected (files identical)"
    else
        echo "  ⚠️  Content changed!"
    fi
else
    echo "  ℹ️  Insufficient files for comparison"
fi

# Check Pushover config
echo ""
echo "🔔 Pushover Notifications:"
grep -q "export PUSHOVER_APP_TOKEN" <LOCAL_REPO>/run_monitor_classsearch.sh 2>/dev/null && \
    APP_TOKEN=$(grep "export PUSHOVER_APP_TOKEN" <LOCAL_REPO>/run_monitor_classsearch.sh | cut -d'"' -f2) || APP_TOKEN=""

if [ -n "$APP_TOKEN" ]; then
    echo "  ✅ Configured (Token: ${APP_TOKEN:0:10}...)"
else
    echo "  ❌ Not configured"
fi

# Polling interval
echo ""
echo "⏲️  Monitoring Config:"
echo "  Poll Interval: 3 minutes"
echo "  Max Snapshots: 2 (auto-rotated)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 Quick Commands:"
echo "   • View logs:        tail -f monitor_classsearch.log"
echo "   • Stop monitor:     launchctl unload ~/Library/LaunchAgents/com.myucla.classsearch.monitor.plist"
echo "   • Start monitor:    launchctl load ~/Library/LaunchAgents/com.myucla.classsearch.monitor.plist"
echo "   • View page:        open http://localhost:8001/classsearch_saved.html"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
