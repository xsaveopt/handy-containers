# handy-containers

A collection of small single-purpose container images, each built from its own name.Dockerfile in the repo root and published to ghcr.io/xsaveopt/{name}.

| Image | What it holds |
| --- | --- |
| unpacker | Alpine with tar, gzip, bzip2, xz, zstd, unzip and p7zip, starting in `sh` |
| ffprobe | Debian slim with ffmpeg (which includes ffprobe), using `bash` as its entrypoint |

Both images run as uid 10001 with /home/app as the working directory, so a mounted folder needs to be writable by that user if the tools write into it.

```sh
docker run --rm -it -v "$PWD:/home/app/work" ghcr.io/xsaveopt/unpacker:latest
```

## Image tags

Every push to main publishes a dev tag for each image.
Pushing a v1.2.3 tag releases all images together as 1.2.3, 1.2 and 1, along with latest, while a pre-release tag such as v1.2.3-rc1 only gets its exact version.
Images are built for linux/amd64, and a nightly job prunes untagged versions from the registry.

## Adding a container

Add a name.Dockerfile to the repo root and CI picks it up on its own.
Every push and pull request lints it with hadolint and builds it, and pushes to main or a version tag publish it as ghcr.io/xsaveopt/{name}, with the name lowercased.

## License

GPL-2.0, see LICENSE.
