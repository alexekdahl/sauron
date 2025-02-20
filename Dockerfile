FROM debian:bullseye-slim

ENV DEBIAN_FRONTEND='noninteractive'
ENV PATH=$PATH:/root/.nimble/bin
ENV PATH=$PATH:/usr/local/bin
ENV NIMBLEPATH=/root/.nimble

RUN apt-get update && \
    apt-get upgrade -yy && \
    apt-get install -yy \
      build-essential \
      git \
      curl \
      gcc-arm-linux-gnueabihf \
      gcc-aarch64-linux-gnu \
      gcc-mipsel-linux-gnu  \
      binutils-aarch64-linux-gnu \
      binutils-arm-linux-gnueabihf \
      binutils-mipsel-linux-gnu


ADD docker/just /usr/local/bin
ADD docker/install-nim.sh /root/

RUN bash /root/install-nim.sh
