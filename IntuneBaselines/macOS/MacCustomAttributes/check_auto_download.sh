#!/bin/zsh
#set -x
# -------------------------------------------------------------------------------------------------------------------------------
# Custom Attribute Script to Check if updates are automatically downloaded
# CIS Benchmark Level 1 - 1.3 Ensure Download New Updates When Available Is Enabled
# -------------------------------------------------------------------------------------------------------------------------------
#
# remove the previous line (set -x) if you want to run the script line by line.
# in terminal type: bash -x scriptname
#
# DISCLAIMER: 
# This script is provided "as is" without warranties or guarantees of any kind. While it has been created to fulfill specific functions 
# and has worked effectively for my personal requirements, its performance may vary in different environments or use-cases. 
# Users are advised to employ this script at their own discretion and risk. 
# No responsibility will be assumed for any direct, indirect, incidental, or consequential damages that may arise from its use.
# ALWAYS TEST it in a controlled environment before deploying it in your production environment!
#
# -------------------------------------------------------------------------------------------------------------------------------
# Check if updates are being automatically downloaded
automatic_download_status=$(
/usr/bin/osascript -l JavaScript << EOS
$.NSUserDefaults.alloc.initWithSuiteName('com.apple.SoftwareUpdate').objectForKey('AutomaticDownload').js
EOS
)

# Determine download status
if [[ "$automatic_download_status" == "true" ]]; then
    echo "PASSED: Updates will automatically download"
else
    echo "FAILED: Updates are not downloaded automatically"
fi


