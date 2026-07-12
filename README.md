# handy-containers

**A grab-bag of tiny single-purpose container images, each built from its own `<name>.Dockerfile`.**

## Contents

- [Images](#images)
- [Image tags](#image-tags)
- [Adding a container](#adding-a-container)

## Images

| Image      | Purpose                                              |
| ---------- | --------------------------------------------------- |
| `unpacker` | Alpine with every common archive tool preinstalled. |
| `ffprobe`  | Debian slim with `ffprobe` and a `bash` entrypoint. |

Pull any of them from `ghcr.io/xsaveopt/<name>`:

```bash
docker run --rm -it ghcr.io/xsaveopt/unpacker:latest
```

## Image tags

`dev` tracks the tip of `main` (rebuilt every push). `latest`, `1`, `1.2`, `1.2.3` come from `v*.*.*` tags — a tag versions **all** images at once. Pre-releases (`1.2.3-rc1`) never get `latest`. Built for `linux/amd64`.

## Adding a container

Drop a `<name>.Dockerfile` in the repo root. CI lints it with hadolint, builds it on every push, and publishes `ghcr.io/xsaveopt/<name>` automatically — no workflow changes needed.
