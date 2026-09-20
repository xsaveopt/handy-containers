setup_file() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "the lowercasing expansion needs bash 4 or newer, and this is $BASH_VERSION"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq is not on PATH'
  fi

  local root
  root=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
  export DISCOVERY_TMP="$root/.tmp/discovery.$$"
  mkdir -p "$DISCOVERY_TMP"
}

teardown_file() {
  if [ -n "${DISCOVERY_TMP:-}" ]; then
    rm -rf "$DISCOVERY_TMP"
  fi
}

discover_build_matrix() {
  (
    shopt -s nullglob
    cd -- "$1" || exit 1
    for f in *.Dockerfile; do
      name="${f%.Dockerfile}"
      jq -cn --arg name "${name,,}" --arg file "$f" '{name:$name,file:$file}'
    done | jq -cs '{include: .}'
  )
}

discover_name_matrix() {
  (
    shopt -s nullglob
    cd -- "$1" || exit 1
    for f in *.Dockerfile; do
      name="${f%.Dockerfile}"
      jq -cn --arg name "${name,,}" '{name:$name}'
    done | jq -cs '{include: .}'
  )
}

fixture() {
  local dir="$DISCOVERY_TMP/$1" file
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  for file in "$@"; do
    : >"$dir/$file"
  done
  printf '%s' "$dir"
}

assert_matrix() {
  local got_sorted want_sorted
  got_sorted=$(printf '%s' "$1" | jq -cS '.include |= sort_by(tostring)')
  want_sorted=$(printf '%s' "$2" | jq -cS '.include |= sort_by(tostring)')
  if [ "$got_sorted" != "$want_sorted" ]; then
    printf 'wanted %s\n' "$want_sorted" >&2
    printf 'got    %s\n' "$got_sorted" >&2
    return 1
  fi
}

@test "a Dockerfile per image becomes one matrix entry each" {
  local dir
  dir=$(fixture two-images ffprobe.Dockerfile unpacker.Dockerfile)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[{"name":"ffprobe","file":"ffprobe.Dockerfile"},{"name":"unpacker","file":"unpacker.Dockerfile"}]}'
}

@test "a Dockerfile per image stays on one line for the step output" {
  local dir
  dir=$(fixture two-images ffprobe.Dockerfile unpacker.Dockerfile)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "the image name is lowercased while the file name is left alone" {
  local dir
  dir=$(fixture mixed-case Unpacker.Dockerfile MiXeD-Case.Dockerfile)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[{"name":"unpacker","file":"Unpacker.Dockerfile"},{"name":"mixed-case","file":"MiXeD-Case.Dockerfile"}]}'
}

@test "the lowercased matrix stays on one line for the step output" {
  local dir
  dir=$(fixture mixed-case Unpacker.Dockerfile MiXeD-Case.Dockerfile)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "anything that is not a name.Dockerfile is skipped" {
  local dir
  dir=$(fixture other-files ffprobe.Dockerfile Dockerfile README.md notes.Dockerfile.txt .Dockerfile.swp)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[{"name":"ffprobe","file":"ffprobe.Dockerfile"}]}'
}

@test "the matrix from a tree of other files stays on one line for the step output" {
  local dir
  dir=$(fixture other-files ffprobe.Dockerfile Dockerfile README.md notes.Dockerfile.txt .Dockerfile.swp)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "a space in the file name survives into both fields" {
  local dir
  dir=$(fixture spaced 'my tool.Dockerfile')
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[{"name":"my tool","file":"my tool.Dockerfile"}]}'
}

@test "a spaced file name stays on one line for the step output" {
  local dir
  dir=$(fixture spaced 'my tool.Dockerfile')
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "a tree with no Dockerfiles gives an empty matrix" {
  local dir
  dir=$(fixture empty)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[]}'
}

@test "an empty matrix stays on one line for the step output" {
  local dir
  dir=$(fixture empty)
  run discover_build_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "the cleanup job discovers the same names without the file" {
  local dir
  dir=$(fixture cleanup-shape Unpacker.Dockerfile README.md)
  run discover_name_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[{"name":"unpacker"}]}'
}

@test "the cleanup matrix stays on one line for the step output" {
  local dir
  dir=$(fixture cleanup-shape Unpacker.Dockerfile README.md)
  run discover_name_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}

@test "the cleanup job also copes with no Dockerfiles at all" {
  local dir
  dir=$(fixture cleanup-empty)
  run discover_name_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  assert_matrix "$output" '{"include":[]}'
}

@test "the empty cleanup matrix stays on one line for the step output" {
  local dir
  dir=$(fixture cleanup-empty)
  run discover_name_matrix "$dir"
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
}
