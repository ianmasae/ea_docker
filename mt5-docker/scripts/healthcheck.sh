#!/bin/bash
# Check if terminal64.exe is running (via Hangover Wine)
if pgrep -f "terminal64.exe" > /dev/null 2>&1; then
    exit 0
elif pgrep -f "wineserver" > /dev/null 2>&1; then
    # Wine server running (MT5 might be initializing)
    exit 0
else
    exit 1
fi
