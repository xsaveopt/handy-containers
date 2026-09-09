FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -u 10001 -m app

USER 10001:10001
WORKDIR /home/app

ENTRYPOINT ["bash"]
