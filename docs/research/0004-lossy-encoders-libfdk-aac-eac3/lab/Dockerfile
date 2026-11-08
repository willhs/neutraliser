# FFmpeg 7.1.1 with libfdk_aac (nonfree: for measurement only, never shipped), on the same base as the
# production image (Debian 13). Build: docker build -t fdk-lab -f Dockerfile .
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates xz-utils pkg-config nasm autoconf automake libtool cmake \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sL https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v2.0.3.tar.gz | tar xz -C /tmp \
 && cd /tmp/fdk-aac-2.0.3 && autoreconf -fiv >/dev/null && ./configure --prefix=/usr/local --disable-shared >/dev/null \
 && make -j4 >/dev/null && make install
RUN curl -sL https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz | tar xJ -C /tmp \
 && cd /tmp/ffmpeg-7.1.1 && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure --enable-nonfree --enable-libfdk-aac \
      --disable-doc --disable-ffplay --disable-debug --extra-libs=-lm >/dev/null \
 && make -j4 >/dev/null && make install
ENTRYPOINT []
