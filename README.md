# Pterodactyl-Docker-Images

## Overview

This project contains Docker images for use with Pterodactyl. It includes various versions of Java and PHP, ensuring that the images work on different platforms such as `linux/amd64` and `linux/arm64`.

## Directory Structure

- `.github/workflows/Java.yml`: GitHub Actions workflow for building and publishing the Java Docker images.
- `java/entrypoint.sh`: Entrypoint script executed when the Java container starts.
- `java/21/Dockerfile`: Dockerfile for Java 21.
- `Laravel/entrypoint.sh`: Entrypoint script executed when the Laravel container starts.
- `Laravel/11/Dockerfile`: Dockerfile for Laravel with PHP 8.2.

## Docker Images

The Docker images are automatically built and pushed to the GitHub Container Registry (`ghcr.io`). The tags of the images follow the schema `java_<version>` and `laravel_<version>`.

## Usage

### Running a Docker Image

To run a Docker image, use the following command:

```sh
docker run -it ghcr.io/coho04/pterodactyl-docker-images:java_<version>
```