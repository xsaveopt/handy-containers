setup_file() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "the lowercasing expansion needs bash 4 or newer, and this is $BASH_VERSION"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq is not on PATH'
  fi
  if ! command -v yq >/dev/null 2>&1; then
    skip 'yq is not on PATH, so the run blocks cannot be read from the workflows'
  fi

  local root
  root=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
  export DISCOVERY_ROOT="$root"
  export DISCOVERY_TMP="$root/.tmp/discovery.$$"
  mkdir -p "$DISCOVERY_TMP"

  yq -r '.jobs.discover.steps[] | select(.id == "set") | .run' "$root/.github/workflows/release.yml" >"$DISCOVERY_TMP/build.sh"
  yq -r '.jobs.discover.steps[] | select(.id == "set") | .run' "$root/.github/workflows/ghcr-cleanup.yml" >"$DISCOVERY_TMP/cleanup.sh"
}

teardown_file() {
  if [ -n "${DISCOVERY_TMP:-}" ]; then
    rm -rf "$DISCOVERY_TMP"
  fi
}

run_step() {
  local script="$DISCOVERY_TMP/$1.sh" out
  if ! grep -q 'GITHUB_OUTPUT' "$script"; then
    printf 'the %s discovery step was not found in its workflow\n' "$1" >&2
    return 1
  fi
  out="$DISCOVERY_TMP/output.$1.$BATS_TEST_NUMBER"
  : >"$out"
  (
    cd -- "$2" || exit 1
    GITHUB_OUTPUT="$out" bash --noprofile --norc -eo pipefail "$script"
  ) || return 1
  cat "$out"
}

discover_build_matrix() {
  run_step build "$1"
}

discover_name_matrix() {
  run_step cleanup "$1"
}

matrix_of() {
  printf '%s' "${1#matrix=}"
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
  got_sorted=$(matrix_of "$1" | jq -cS '.include |= sort_by(tostring)')
  want_sorted=$(printf '%s' "$2" | jq -cS '.include |= sort_by(tostring)')
  if [ "$got_sorted" != "$want_sorted" ]; then
    printf 'wanted %s\n' "$want_sorted" >&2
    printf 'got    %s\n' "$got_sorted" >&2
    return 1
  fi
}

assert_one_output_line() {
  [ "${#lines[@]}" -eq 1 ] || return 1
  [[ "${lines[0]}" == matrix=* ]] || return 1
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
  assert_one_output_line
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
  assert_one_output_line
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
  assert_one_output_line
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
  assert_one_output_line
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
  assert_one_output_line
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
  assert_one_output_line
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
  assert_one_output_line
}

@test "the cleanup job prunes exactly the images the build job publishes" {
  local dir build cleanup
  dir=$(fixture agree ffprobe.Dockerfile Unpacker.Dockerfile 'my tool.Dockerfile' README.md)
  build=$(discover_build_matrix "$dir") || return 1
  cleanup=$(discover_name_matrix "$dir") || return 1
  build=$(matrix_of "$build" | jq -c '[.include[].name] | sort')
  cleanup=$(matrix_of "$cleanup" | jq -c '[.include[].name] | sort')
  [ "$build" = "$cleanup" ] || return 1
}

@test "the repository's own Dockerfiles each become a build entry" {
  local file count
  run discover_build_matrix "$DISCOVERY_ROOT"
  [ "$status" -eq 0 ] || return 1
  count=$(matrix_of "$output" | jq '.include | length')
  [ "$count" -ge 1 ] || return 1
  [ "$count" -eq "$(find "$DISCOVERY_ROOT" -maxdepth 1 -name '*.Dockerfile' | wc -l)" ] || return 1
  while IFS= read -r file; do
    [ -f "$DISCOVERY_ROOT/$file" ] || return 1
  done < <(matrix_of "$output" | jq -r '.include[].file')
}
