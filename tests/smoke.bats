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
  if [ -n "${SMOKE_NAMES+set}" ]; then
    read -r -a names <<<"$SMOKE_NAMES"
  else
    names=()
    for file in "$root"/*.Dockerfile; do
      [ -f "$file" ] || continue
      name=$(basename -- "$file" .Dockerfile)
      names+=("$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')")
    done
  fi
  export SMOKE_UNDER_TEST="${names[*]}"

  if [ "${#names[@]}" -eq 0 ]; then
    printf 'there are no images to test, SMOKE_NAMES is empty or there is no name.Dockerfile\n' >&2
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
    file=$(dockerfile_for "$root" "$name")
    if [ -z "$file" ]; then
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

dockerfile_for() {
  local file stem
  for file in "$1"/*.Dockerfile; do
    [ -f "$file" ] || continue
    stem=$(basename -- "$file" .Dockerfile | tr '[:upper:]' '[:lower:]')
    if [ "$stem" = "$2" ]; then
      printf '%s' "$file"
      return 0
    fi
  done
}

covered_images() {
  grep -oE '^[[:space:]]*use_image [^[:space:]]+' "$BATS_TEST_FILENAME" | awk '{print $2}' | sort -u
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

@test "every image under test has smoke tests of its own" {
  local name missing=''
  [ -n "$SMOKE_UNDER_TEST" ] || return 1
  for name in $SMOKE_UNDER_TEST; do
    if ! covered_images | grep -qxF "$name"; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    printf 'no test in smoke.bats uses these images, so every test would skip:%s\n' "$missing" >&2
    return 1
  fi
}

@test "the unpacker default command is a shell that reads commands from stdin" {
  use_image unpacker
  run sh -c 'printf "id -u\npwd\n" | docker run --rm -i "$1"' _ "$image"
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = 10001 ] || return 1
  [ "${lines[1]}" = /home/app ] || return 1
}

@test "the unpacker image runs a command given in place of its default" {
  use_image unpacker
  run docker run --rm "$image" 7z i
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *7-Zip* ]] || return 1
}

@test "bsdtar resolves on PATH and reports itself" {
  use_image unpacker
  run in_image "$image" 'bsdtar --version'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == bsdtar* ]] || return 1
}

@test "bsdtar round trips a tar archive" {
  use_image unpacker
  run round_trip 'bsdtar -cf a.tar file.txt; mkdir out; bsdtar -xf a.tar -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "bsdtar extracts a zip that 7z wrote" {
  use_image unpacker
  run round_trip '7z a -bso0 -bsp0 -tzip f.zip file.txt; mkdir out; bsdtar -xf f.zip -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "7z round trips a .7z archive" {
  use_image unpacker
  run round_trip '7z a -bso0 -bsp0 -t7z f.7z file.txt; 7z t -bso0 -bsp0 f.7z; mkdir out; 7z x -bso0 -bsp0 -oout f.7z; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "7z writes the 7z format and not something else" {
  use_image unpacker
  run round_trip '7z a -bso0 -bsp0 -t7z f.7z file.txt; 7z l f.7z | grep -q "^Type = 7z"'
  [ "$status" -eq 0 ] || return 1
}

@test "tar round trips a bzip2 archive with -j" {
  use_image unpacker
  run round_trip 'tar -cjf a.tar.bz2 file.txt; bzip2 -t a.tar.bz2; mkdir out; tar -xjf a.tar.bz2 -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "tar round trips an xz archive with -J" {
  use_image unpacker
  run round_trip 'tar -cJf a.tar.xz file.txt; xz -t a.tar.xz; mkdir out; tar -xJf a.tar.xz -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "tar round trips a zstd archive with --zstd" {
  use_image unpacker
  run round_trip 'tar --zstd -cf a.tar.zst file.txt; zstd -q -t a.tar.zst; mkdir out; tar --zstd -xf a.tar.zst -C out; grep -q payload out/file.txt'
  [ "$status" -eq 0 ] || return 1
}

@test "the ffprobe entrypoint is bash and takes its arguments" {
  use_image ffprobe
  run docker run --rm "$image" -c 'printf "%s %s\n" "${BASH_VERSINFO[0]}" "$(id -u)"'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" =~ ^[0-9]+\ 10001$ ]] || return 1
}

@test "the ffprobe entrypoint reads a script from stdin when given no arguments" {
  use_image ffprobe
  run sh -c 'printf "ffprobe -version | head -n 1\npwd\n" | docker run --rm -i "$1"' _ "$image"
  [ "$status" -eq 0 ] || return 1
  [[ "${lines[0]}" == "ffprobe version "* ]] || return 1
  [ "${lines[1]}" = /home/app ] || return 1
}

@test "ffprobe describes a generated clip as JSON" {
  use_image ffprobe
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq is not on PATH'
  fi
  local json
  json=$(in_image "$image" 'set -e; cd "$(mktemp -d)"; ffmpeg -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=10 -f lavfi -i sine=frequency=440:duration=1 -shortest clip.mkv; ffprobe -v error -print_format json -show_format -show_streams clip.mkv') || return 1
  [ "$(jq -r '.format.format_name' <<<"$json")" = matroska,webm ] || return 1
  [ "$(jq '.streams | length' <<<"$json")" -eq 2 ] || return 1
  [ "$(jq -c '[.streams[] | select(.codec_type == "video") | .width, .height]' <<<"$json")" = '[64,48]' ] || return 1
  [ "$(jq '[.streams[] | select(.codec_type == "audio")] | length' <<<"$json")" -eq 1 ] || return 1
  jq -e '(.format.duration | tonumber) > 0.8 and (.format.duration | tonumber) < 1.3' <<<"$json" >/dev/null || return 1
}
