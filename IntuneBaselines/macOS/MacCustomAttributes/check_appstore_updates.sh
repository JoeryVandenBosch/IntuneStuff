#!/bin/zsh
#set -x
# -------------------------------------------------------------------------------------------------------------------------------
# Custom Attribute Script to Check if app store updates are installed automatically
# CIS Benchmark Level 1 - 1.5 Ensure Install Application Updates from the App Store Is Enabled (Automated)
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
# Check if App Store automatic updates are enabled
appstore_update=$(defaults read com.apple.commerce AutoUpdate 2>/dev/null)

# Determine update status
if [[ "$appstore_update" == "true" ]]; then
    echo "PASSED: App Store updates are instealled automatically"
else
    echo "FAILED: App Store updates are not installed automatically"
fi