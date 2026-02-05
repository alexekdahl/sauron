FROM debian:bullseye-slim

ARG UPX_VERSION=5.0.1

ENV DEBIAN_FRONTEND='noninteractive'
ENV PATH=$PATH:/opt/nim/bin:/root/.nimble/bin:/usr/local/bin
ENV NIMBLEPATH=/root/.nimble

RUN apt-get update && \
    apt-get upgrade -yy && \
    apt-get install -yy \
      build-essential \
      git \
      curl \
      wget \
      gcc-arm-linux-gnueabihf \
      gcc-aarch64-linux-gnu \
      gcc-mipsel-linux-gnu  \
      binutils-aarch64-linux-gnu \
      binutils-arm-linux-gnueabihf \
      binutils-mipsel-linux-gnu


RUN curl -L https://nim-lang.org/download/nim-2.2.0-linux_x64.tar.xz -o nim-2.2.0-linux_x64.tar.xz && \
    tar xf nim-2.2.0-linux_x64.tar.xz && \
    mv nim-2.2.0 /opt/nim && \
    rm nim-2.2.0-linux_x64.tar.xz

RUN wget -nv https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-amd64_linux.tar.xz && \
    tar -xf upx-${UPX_VERSION}-amd64_linux.tar.xz && \
    rm upx-${UPX_VERSION}-amd64_linux.tar.xz && \
    cp upx-${UPX_VERSION}-amd64_linux/upx /usr/bin/ && \
    rm -rf upx-${UPX_VERSION}-amd64_linux

ADD docker/just /usr/local/bin
