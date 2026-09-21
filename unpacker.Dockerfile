FROM alpine:3

RUN apk add --no-cache \
    7zip \
    bzip2 \
    gzip \
    tar \
    unzip \
    xz \
    zstd \
 && adduser -D -u 10001 app

USER 10001:10001
WORKDIR /home/app

CMD ["sh"]