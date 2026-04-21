#!/bin/bash
set -eux
# ECS AMI already has Docker + awscli
systemctl enable --now docker
usermod -aG docker ec2-user
# make sure docker buildx is ready
docker buildx version || true
echo "builder-ready" > /tmp/builder-ready
