#!/bin/bash

# Check if BIND (named) is active
systemctl is-active --quiet bind9
if [ $? -eq 0 ]; then
    exit 0    # healthy
else
    exit 1    # fail
fi
