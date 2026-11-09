#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Kanata Error Log
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🔥

# Documentation:
# @raycast.description Output /Library/Logs/Kanata/kanata.err.log
# @raycast.author plasmadice
# @raycast.authorURL https://github.com/plasmadice

# echo last 100 lines of kanata.err.log
tail -n 100 /Library/Logs/Kanata/kanata.err.log
