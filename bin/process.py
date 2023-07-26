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
    response = requests.post(callback_url, json=body)

# Start the subprocess and capture its standard error output


def read_stream(stream, callback):
    while True:
        line = stream.readline()
        if line:
            callback(line)
        else:
            break


# Initialize variables for parsing the subprocess's standard error output

def stdout_callback(line):
    print(line)

# Parse the standard error output line by line


def stderr_callback(stderr_chunk):
    status_message_buffer = ''
    inside_status_tag = False
    error_message = ''

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


# Start the subprocess and capture its standard error output
process_instance = subprocess.Popen(
    process_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

# Create separate threads for reading stdout and stderr
stdout_thread = threading.Thread(target=read_stream, args=(
    process_instance.stdout, stdout_callback))
stderr_thread = threading.Thread(target=read_stream, args=(
    process_instance.stderr, stderr_callback))

# Start the threads
stdout_thread.start()
stderr_thread.start()

# Wait for both threads to finish
stdout_thread.join()
stderr_thread.join()
