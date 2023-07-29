#!/usr/bin/env python3
# coding=utf-8

import subprocess
import sys
import requests
import json
import threading

# Get command line arguments
command_line_arguments = sys.argv[1:]

# Construct the process command to execute
process_command = ['bash', 'process.sh'] + command_line_arguments

# Get the callback URL from the command line arguments
callback_url = sys.argv[3]

# Function to send a callback request
def send_callback_request(body):
    requests.post(callback_url, json=body)

def output_stream_watcher(_, stream):
    for line in stream:
        print(line)

    if stream:
        stream.close()

def error_stream_watcher(_, stream):
    status_message_buffer = ''
    inside_status_tag = False
    error_message = ''

    for line in stream:
        i = 0
        while i < len(line):
            # Check if the current character marks the start of a status message tag
            if line[i:i+2] == '#*':
                inside_status_tag = True
                i += 2
            # Check if the current character marks the end of a status message tag
            elif line[i:i+2] == '*#':
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
                status_message_buffer += line[i]
                i += 1
            # If not inside a status message tag, append the current character to the error message buffer
            else:
                error_message += line[i]
                i += 1
        print(line)

    if stream:
        stream.close()

process_instance = subprocess.Popen(
  process_command,
  stdout=subprocess.PIPE,
  stderr=subprocess.PIPE, 
  universal_newlines=True
)

threading.Thread(target=output_stream_watcher, args=('STDOUT', process_instance.stdout)).start()
threading.Thread(target=error_stream_watcher, args=('STDERR', process_instance.stderr)).start()

exit_code = process_instance.wait()
if exit_code != 0:
    sys.exit(exit_code)