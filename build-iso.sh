#!/bin/bash
set -e

# Check if the second script exists
if [ ! -f "create-iso.sh" ]; then
    echo "Error: create-iso.sh not found in current directory"
    exit 1
fi

# Check if Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    echo "Error: Dockerfile not found in current directory"
    exit 1
fi

echo "Building Docker image..."
docker build -t linux-iso-builder .

echo "Creating output directory..."
mkdir -p output

echo "Running container to build ISO..."
docker run --rm \
    -v "$(pwd)/output:/output" \
    -e HOST_UID=$(id -u) \
    -e HOST_GID=$(id -g) \
    linux-iso-builder

echo "Cleaning up Docker image..."
docker rmi linux-iso-builder

echo "Done! ISO file should be in ./output/ directory"