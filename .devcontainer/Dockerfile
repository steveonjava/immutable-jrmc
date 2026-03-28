FROM mcr.microsoft.com/devcontainers/base:ubuntu

USER root

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      appstream \
      binutils \
      ca-certificates \
      curl \
      desktop-file-utils \
      file \
      findutils \
      gcc \
      git \
      libc6-dev \
      patchelf \
      proot \
      python3 \
      rsync \
      squashfs-tools \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://git.bryanroessler.com/bryan/installJRMC/raw/branch/master/installJRMC" \
      -o /usr/local/bin/installJRMC && \
    chmod 0755 /usr/local/bin/installJRMC