setup_file() {
  if ! command -v docker >/dev/null 2>&1; then
    skip 'docker is not on PATH, so the images cannot be built or run'
  fi
  if ! docker info >/dev/null 2>&1; then
    skip 'docker is installed but the daemon is not reachable'
  fi

  local root name file tag
  local -a names
  root=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
  read -r -a names <<<"${SMOKE_NAMES:-unpacker ffprobe}"

  if [ "${#names[@]}" -eq 0 ]; then
    printf 'SMOKE_NAMES is set but names no images\n' >&2
    return 1
  fi
  if [ -n "${SMOKE_IMAGE:-}" ] && [ "${#names[@]}" -ne 1 ]; then
    printf 'SMOKE_IMAGE tests one image, so SMOKE_NAMES has to name exactly one\n' >&2
    return 1
  fi

  export SMOKE_TMP="$root/.tmp/smoke.$$"
  export SMOKE_BUILT="$SMOKE_TMP/built"
  mkdir -p "$SMOKE_TMP"
  : >"$SMOKE_BUILT"

  for name in "${names[@]}"; do
    if [ -n "${SMOKE_IMAGE:-}" ]; then
      export "SMOKE_REF_$name=$SMOKE_IMAGE"
      continue
    fi
    file="$root/$name.Dockerfile"
    if [ ! -f "$file" ]; then
      printf 'there is no %s.Dockerfile in %s\n' "$name" "$root" >&2
      return 1
    fi
    tag="handy-containers-smoke:$name"
    docker build --quiet --file "$file" --tag "$tag" "$root" >/dev/null
    printf '%s\n' "$tag" >>"$SMOKE_BUILT"
    export "SMOKE_REF_$name=$tag"
  done
}

teardown_file() {
  local tag
  if [ -n "${SMOKE_BUILT:-}" ] && [ -f "$SMOKE_BUILT" ]; then
    while IFS= read -r tag; do
      docker image rm -f "$tag" >/dev/null 2>&1 || true
    done <"$SMOKE_BUILT"
  fi
  if [ -n "${SMOKE_TMP:-}" ]; then
    rm -rf "$SMOKE_TMP"
  fi
}

use_image() {
  local var="SMOKE_REF_$1"
  if [ -z "${!var:-}" ]; then
    skip "$1 is not among the images under test"
  fi
  image=${!var}
}

in_image() {
  docker run --rm --entrypoint sh "$1" -c "$2"
}

round_trip() {
  in_image "$image" 'set -e; cd "$(mktemp -d)"; printf payload > file.txt; '"$1"
}

writable_mount() {
  local dir="$SMOKE_TMP/mount.$1" owner host waited=0
  mkdir -p "$dir"
  chmod 0777 "$dir"
  owner=$(docker run --rm --entrypoint sh --volume "$dir:/home/app/work" "$image" \
    -c 'printf ok > /home/app/work/probe && stat -c %u /home/app/work/probe' 2>&1) || owner=''
  if [ "$owner" != 10001 ]; then
    printf 'the container did not write the probe as uid 10001, it said %s\n' "${owner:-nothing}" >&2
    return 1
  fi
  while true; do
    host=$(cat "$dir/probe" 2>/dev/null) || host=''
    if [ "$host" = ok ]; then
      return 0
    fi
    if [ "$waited" -ge 5 ]; then
      break
    fi
    waited=$((waited + 1))
    sleep 1
  done
  printf 'the host never saw the probe the container wrote into the mount\n' >&2
  return 1
}

@test "the unpacker container runs as uid 10001" {
  use_image unpacker
  run in_image "$image" 'id -u'
  [ "$status" -eq 0 ] || return 1
  [ "$output" = 10001 ] || return 1
}

@test "the unpacker working directory is /home/app" {
  use_image unpacker
  run in_image "$image" 'pwd'
  [ "$status" -eq 0 ] || return 1
  [ "$output" = /home/app ] || return 1
}

@test "a directory mounted into the unpacker image is writable as uid 10001" {
  use_image unpacker
  writable_mount unpacker
}

@test "tar, gzip, bzip2, xz, zstd, unzip and 7z resolve on PATH" {
  use_image unpacker
  run in_image "$image" 'for tool in tar gzip bzip2 xz zstd unzip 7z; do command -v "$tool" >/dev/null || exit 1; done'
  [ "$status" -eq 0 ] || return 1
}

@test "each of those tools runs and reports itself" {
  use_image unpacker
  run in_image "$image" 'tar --version >/dev/null && gzip --version >/dev/null && bzip2 --version >/dev/null && xz --version >/dev/null && zstd --version >/dev/null && unzip -v >/dev/null && 7z i >/dev/null'
  [ "$status" -eq 0 ] || return 1
}

@test "tar and gzip round trip an archive" {
  use_image unpacker
  run round_trip 'tar -czf a.tgz file.txt; mkdir out; tar -xzf a.tgz -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "gzip round trips a file" {
  use_image unpacker
  run round_trip 'gzip -c file.txt > f.gz; gzip -dc f.gz | grep -q payload'
  [ "$status" -eq 0 ] || return 1
}

@test "bzip2 round trips a file" {
  use_image unpacker
  run round_trip 'bzip2 -c file.txt > f.bz2; bzip2 -dc f.bz2 | grep -q payload'
  [ "$status" -eq 0 ] || return 1
}

@test "xz round trips a file" {
  use_image unpacker
  run round_trip 'xz -c file.txt > f.xz; xz -dc f.xz | grep -q payload'
  [ "$status" -eq 0 ] || return 1
}

@test "zstd round trips a file" {
  use_image unpacker
  run round_trip 'zstd -q -c file.txt > f.zst; zstd -dc f.zst | grep -q payload'
  [ "$status" -eq 0 ] || return 1
}

@test "7z writes a zip that unzip reads back" {
  use_image unpacker
  run round_trip '7z a -bso0 -bsp0 -tzip f.zip file.txt; mkdir z; unzip -q f.zip -d z; grep -q payload z/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "the ffprobe container runs as uid 10001" {
  use_image ffprobe
  run in_image "$image" 'id -u'
  [ "$status" -eq 0 ] || return 1
  [ "$output" = 10001 ] || return 1
}

@test "the ffprobe working directory is /home/app" {
  use_image ffprobe
  run in_image "$image" 'pwd'
  [ "$status" -eq 0 ] || return 1
  [ "$output" = /home/app ] || return 1
}

@test "a directory mounted into the ffprobe image is writable as uid 10001" {
  use_image ffprobe
  writable_mount ffprobe
}

@test "ffmpeg and ffprobe resolve on PATH" {
  use_image ffprobe
  run in_image "$image" 'command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null'
  [ "$status" -eq 0 ] || return 1
}

@test "ffmpeg reports a version" {
  use_image ffprobe
  run in_image "$image" 'ffmpeg -version | head -n 1 | grep -q "^ffmpeg version "'
  [ "$status" -eq 0 ] || return 1
}

@test "ffprobe reports a version" {
  use_image ffprobe
  run in_image "$image" 'ffprobe -version | head -n 1 | grep -q "^ffprobe version "'
  [ "$status" -eq 0 ] || return 1
}
