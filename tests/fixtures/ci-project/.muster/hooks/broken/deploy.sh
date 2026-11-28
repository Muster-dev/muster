#!/usr/bin/env bash
# Fixture for the action self-test: fails like an app whose redis is down.
echo "Starting broken..."
echo "Error: connect ECONNREFUSED 127.0.0.1:6379"
exit 3
