#!/usr/bin/env bash

set -e

echo "Setting up project..."

chmod +x redis-tool

if [ -f "infra/id_rsa" ]; then
    chmod 600 infra/id_rsa
fi

echo ""
echo "Setup completed"
echo ""
echo "Run:"
echo " ./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1"