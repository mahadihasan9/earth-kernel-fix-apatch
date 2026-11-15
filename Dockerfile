FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        cpio \
        kmod \
        zip \
        unzip \
        rsync \
        git \
        curl \
        ca-certificates \
        file \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Build as the same numeric uid as the host user so bind-mounted files keep
# their ownership.
RUN useradd -m -u 1000 builder

USER builder
ENV HOME=/home/builder
WORKDIR /workspace
