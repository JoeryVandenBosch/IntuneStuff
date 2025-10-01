#!/bin/zsh
#set -x
# -------------------------------------------------------------------------------------------------------------------------------
# Custom Attribute Script to Check if diagnostic data submission to Apple is disabled
# CIS Benchmark Level 1 - 2.6.3 Analytics & Improvements
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
# Check if diagnostic data submission to Apple is disabled
diagnostic_profile=$(
/usr/bin/osascript -l JavaScript << EOS
function run() {
    let autoSubmitStatus = $.NSUserDefaults.alloc.initWithSuiteName('com.apple.SubmitDiagInfo').objectForKey('AutoSubmit').js;
    let allowDiagnosticSubmissionStatus = $.NSUserDefaults.alloc.initWithSuiteName('com.apple.applicationaccess').objectForKey('allowDiagnosticSubmission').js;
    let siriDataSharingStatus = $.NSUserDefaults.alloc.initWithSuiteName('com.apple.assistant.support').objectForKey('Siri Data Sharing Opt-In Status').js;

    if (autoSubmitStatus == false && allowDiagnosticSubmissionStatus == false && siriDataSharingStatus == 2) {
        return "true";
    } else {
        return "false";
    }
}
EOS
)

# Determine diagnostic data submission status
if [[ "$diagnostic_profile" == "true" ]]; then
    echo "PASSED: Sending diagnostic data to Apple is disabled"
else
    echo "FAILED: Data and diagnostic data are sent to Apple"
fi
