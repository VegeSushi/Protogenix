FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    wget \
    gzip \
    cpio \
    xorriso \
    isolinux \
    syslinux-common \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY create-iso.sh /build/
RUN chmod +x /build/create-iso.sh

CMD ["/build/create-iso.sh"]