#!/bin/bash

# This script is for running a simple HTTP server to serve ignition templates files to fcos.

cd ./ignition-files
python3 -m http.server 8000
