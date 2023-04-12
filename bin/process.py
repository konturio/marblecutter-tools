#!/usr/bin/env python3
# coding=utf-8

import subprocess
import sys
import requests
import json

# Get command line arguments
command_line_arguments = sys.argv[1:]

# Construct the process command to execute
process_command = ['bash', 'process.sh'] + command_line_arguments

# Get the callback URL from the command line arguments
callback_url = sys.argv[3]

# Function to send a callback request
def send_callback_request(body):
    response = requests.post(callback_url, json=body)

# Start the subprocess and capture its standard error output
process_instance = subprocess.Popen(process_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

# Initialize variables for parsing the subprocess's standard error output
status_message_buffer = ''
inside_status_tag = False
error_message = ''

# Parse the standard error output line by line
for stderr_chunk in process_instance.stderr:
    i = 0
    while i < len(stderr_chunk):
        # Check if the current character marks the start of a status message tag
        if stderr_chunk[i:i+2] == '#*':
            inside_status_tag = True
            i += 2
        # Check if the current character marks the end of a status message tag
        elif stderr_chunk[i:i+2] == '*#':
            inside_status_tag = False
            # Extract the status message from the buffer and send a callback request if necessary
            text = status_message_buffer.strip()
            if text:
                print('Found status message:', text, flush=True)
                status_update_body = json.loads(text)
                if status_update_body["status"] == "failed":
                    status_update_body["message"] = error_message
                send_callback_request(status_update_body)
            status_message_buffer = ''
            i += 2
        # If inside a status message tag, append the current character to the buffer
        elif inside_status_tag:
            status_message_buffer += stderr_chunk[i]
            i += 1
        # If not inside a status message tag, append the current character to the error message buffer
        else:
            error_message += stderr_chunk[i]
            i += 1
