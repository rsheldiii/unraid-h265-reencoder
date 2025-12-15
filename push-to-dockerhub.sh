#!/bin/bash

# Docker Hub username
DOCKERHUB_USER="rsheldiii"
IMAGE_NAME="h265-reencoder"
TAG="latest"

echo "============================================"
echo "Building Docker image..."
echo "============================================"
docker build -t ${IMAGE_NAME}:${TAG} .

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo ""
echo "============================================"
echo "Tagging image for Docker Hub..."
echo "============================================"
docker tag ${IMAGE_NAME}:${TAG} ${DOCKERHUB_USER}/${IMAGE_NAME}:${TAG}

echo ""
echo "============================================"
echo "Pushing to Docker Hub..."
echo "============================================"
docker push ${DOCKERHUB_USER}/${IMAGE_NAME}:${TAG}

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Successfully pushed to Docker Hub!"
    echo "🔗 https://hub.docker.com/r/${DOCKERHUB_USER}/${IMAGE_NAME}"
    echo ""
    echo "Use in Unraid:"
    echo "  Repository: ${DOCKERHUB_USER}/${IMAGE_NAME}:${TAG}"
else
    echo ""
    echo "❌ Push failed! Make sure you're logged in:"
    echo "  docker login"
    exit 1
fi

