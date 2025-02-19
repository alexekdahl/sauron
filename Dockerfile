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
    make \
    curl \
    gcc-10-aarch64-linux-gnu \
    gcc-10-arm-linux-gnueabihf

ADD docker/just /usr/local/bin
ADD docker/install-nim.sh /root/

RUN bash /root/install-nim.sh

