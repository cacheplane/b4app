#!/usr/bin/env bats
# Exercise decision allocation with deterministic PR fixtures in an isolated repo.
# The override selects the copied script so the same fixtures cover either source.
setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  mkdir -p "$REPO/Scripts" "$REPO/docs/decisions" "$REPO/docs/verification" "$FIXTURE" "$BATS_TEST_TMPDIR/bin"
  cp "${DOCS_INDEX_TEST_TARGET:-$BATS_TEST_DIRNAME/../docs-index.sh}" "$REPO/Scripts/docs-index.sh"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email fixture@example.invalid
  git -C "$REPO" config user.name Fixture
  touch "$REPO/docs/decisions/D-010-main.md"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm fixture
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  touch "$REPO/docs/decisions/D-020-tree.md"
  : >"$FIXTURE/open"
  : >"$GH_LOG"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = pr ]; then
  # The old command succeeds, computing the first 100 PRs' first 100 files
  # from the same full population. Never reject it to manufacture red.
  visible_prs=0
  visible_files=0
  while IFS= read -r number; do
    visible_prs=$((visible_prs + 1))
    [ "$visible_prs" -le 100 ] || break
    per_pr=0
    while IFS= read -r name; do
      per_pr=$((per_pr + 1))
      [ "$per_pr" -le 100 ] || break
      visible_files=$((visible_files + 1))
      case "$name" in docs/decisions/D-*) printf '%s\n' "$name" ;; esac
    done <"$FIXTURE/files-$number"
  done <"$FIXTURE/open"
  printf 'legacy first-100 limit; visible files=%s\n' "$visible_files" >>"$GH_LOG"
  exit 0
fi
[ "${1:-}" = api ] || exit 91
shift
route=$1
shift
projection=
paginate=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
    --jq) projection=$2; shift 2 ;;
    *) exit 92 ;;
  esac
done
case "$route" in
  'repos/{owner}/{repo}/pulls?state=open&per_page=100')
    [ "$paginate" -eq 1 ] || exit 93
    [[ "$projection" == *'type == "number"'* && "$projection" == *'floor'* && "$projection" == *'error('* ]] || exit 94
    [ ! -e "$FIXTURE/fail-open" ] || exit 40
    cat "$FIXTURE/open"
    ;;
  repos/\{owner\}/\{repo\}/pulls/*/files\?per_page=100)
    [ "$paginate" -eq 1 ] || exit 95
    [[ "$projection" == *'type == "string"'* && "$projection" == *'length > 0'* && "$projection" == *'index("\u0000")'* && "$projection" == *'index("\r")'* && "$projection" == *'index("\n")'* && "$projection" == *'error('* ]] || exit 96
    number=${route#repos/\{owner\}/\{repo\}/pulls/}
    number=${number%%/*}
    # Invalid raw-name fixtures model gojq refusing before transport into Bash.
    # These finite stub checks do not execute or qualify the gojq expression.
    if [ -e "$FIXTURE/bad-name-$number" ]; then
      echo 'invalid filename projection' >&2
      exit 41
    fi
    if [ -e "$FIXTURE/partial-$number" ]; then
      printf 'file:docs/decisions/D-990-partial.md\n'
      echo 'later page failed' >&2
      exit 42
    fi
    [ ! -e "$FIXTURE/fail-files-$number" ] || exit 43
    while IFS= read -r name; do printf 'file:%s\n' "$name"; done <"$FIXTURE/files-$number"
    ;;
  repos/\{owner\}/\{repo\}/pulls/*)
    [[ "$projection" == *'.changed_files'* && "$projection" == *'type == "number"'* && "$projection" == *'floor'* && "$projection" == *'3000'* && "$projection" == *'.head.sha'* && "$projection" == *'type == "string"'* && "$projection" == *'error('* ]] || exit 97
    number=${route##*/}
    phase=before
    [ ! -e "$FIXTURE/seen-$number" ] || phase=after
    touch "$FIXTURE/seen-$number"
    [ ! -e "$FIXTURE/fail-$phase-$number" ] || exit 44
    # !invalid represents a typed JSON value rejected by gh/gojq. Other text
    # passes through so shell framing checks are independently exercised.
    detail=$(cat "$FIXTURE/$phase-$number")
    case "$detail" in
      '!invalid:'*) echo 'invalid detail projection' >&2; exit 45 ;;
    esac
    printf '%s\n' "$detail"
    ;;
  *) exit 98 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

pr() {
  local number=$1 count=$2
  printf '%s\n' "$number" >>"$FIXTURE/open"
  printf 'detail:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:%s\n' "$count" >"$FIXTURE/before-$number"
  cp "$FIXTURE/before-$number" "$FIXTURE/after-$number"
  : >"$FIXTURE/files-$number"
}
files() {
  local number=$1 count=$2 at=${3:-0} decision=${4:-D-030} i
  : >"$FIXTURE/files-$number"
  for ((i=1; i<=count; i++)); do
    if [ "$i" -eq "$at" ]; then
      printf 'docs/decisions/%s-reserved.md\n' "$decision"
    else
      printf 'Sources/unrelated-%s.swift\n' "$i"
    fi
  done >"$FIXTURE/files-$number"
}
invoke() {
  # Bats captures only this wrapper's stdout; script streams remain separate.
  bash "$REPO/Scripts/docs-index.sh" --next >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr"
}
expect_next() {
  run invoke
  if [ "$status" -ne 0 ] || [ "$(cat "$BATS_TEST_TMPDIR/stdout")" != "$1" ]; then
    printf 'docs-index --next exit: %s\nactual candidate: <%s>\nexpected candidate: <%s>\n' \
      "$status" "$(cat "$BATS_TEST_TMPDIR/stdout")" "$1" >&2
    printf 'captured stderr:\n' >&2
    cat "$BATS_TEST_TMPDIR/stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stdout")" = "$1" ]
}
expect_refusal() {
  run invoke
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/stdout" ]
}

@test "decision after first 100 files: legacy succeeds with wrong D-021, full 200 files require D-240" {
  pr 180 200
  files 180 200 150 D-239
  # Legacy's first 100 files contain no decision, matching the observed omission.
  expect_next D-240
  grep -q 'pulls?state=open&per_page=100 --paginate' "$GH_LOG"
  grep -q 'pulls/180/files?per_page=100 --paginate' "$GH_LOG"
}
@test "greatest decision after first 100 PRs: legacy succeeds with wrong D-021" {
  local i
  for ((i=1; i<=101; i++)); do pr "$i" 1; files "$i" 1; done
  files 101 1 1 D-499
  expect_next D-500
  grep -q 'pulls/101/files?per_page=100 --paginate' "$GH_LOG"
}
@test "main tree and PR maxima include leading zero numbers" {
  pr 1 2
  printf 'docs/decisions/D-007-low.md\ndocs/decisions/D-030-high.md\n' >"$FIXTURE/files-1"
  expect_next D-031
}
@test "main maximum wins over smaller tree and PR numbers" {
  rm "$REPO/docs/decisions/D-020-tree.md"
  pr 1 1; files 1 1 1 D-007
  expect_next D-011
}
@test "empty PR list succeeds with tree maximum" { expect_next D-021; }
@test "zero-file PR succeeds" { pr 1 0; expect_next D-021; }
@test "exactly 3000 files counted before decision selection" {
  pr 1 3000; files 1 3000 3000 D-600; expect_next D-601
}
@test "count above 3000 refuses" {
  pr 1 3001
  printf '!invalid:count-3001\n' >"$FIXTURE/before-1"
  expect_refusal
}
@test "missing count refuses" {
  pr 1 0; printf '!invalid:missing-count\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "nonnumeric count refuses" {
  pr 1 0; printf '!invalid:string-count\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "negative count refuses" {
  pr 1 0; printf '!invalid:negative-count\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "returned full-file count mismatch refuses" { pr 1 2; files 1 1; expect_refusal; }
@test "missing head refuses" {
  pr 1 0; printf '!invalid:missing-head\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "malformed head refuses" {
  pr 1 0; printf 'detail:BAD:0\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "head changed during files pagination refuses" {
  pr 1 0; printf 'detail:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:0\n' >"$FIXTURE/after-1"; expect_refusal
}
@test "count changed during files pagination refuses" {
  pr 1 0; printf 'detail:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1\n' >"$FIXTURE/after-1"; expect_refusal
}
@test "multiple detail records refuse" {
  pr 1 0; cat "$FIXTURE/after-1" >>"$FIXTURE/before-1"; expect_refusal
}
@test "unexpected detail fields refuse" {
  pr 1 0; printf 'detail:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0:extra\n' >"$FIXTURE/before-1"; expect_refusal
}
@test "invalid PR number refuses before route interpolation" {
  printf '0\n' >"$FIXTURE/open"; expect_refusal
  [ "$(wc -l <"$GH_LOG" | tr -d ' ')" = 1 ]
}
@test "NUL filename projection refuses" {
  pr 1 1; printf 'docs/a\0b\n' >"$FIXTURE/bad-name-1"; expect_refusal
}
@test "CR filename projection refuses" {
  pr 1 1; printf 'docs/a\rb\n' >"$FIXTURE/bad-name-1"; expect_refusal
}
@test "LF filename projection refuses" {
  pr 1 1; printf 'docs/a\nb\n' >"$FIXTURE/bad-name-1"; expect_refusal
}
@test "empty filename projection refuses" {
  pr 1 1; printf '\n' >"$FIXTURE/bad-name-1"; expect_refusal
}
@test "spaces tabs and unicode remain valid non-decision filenames" {
  pr 1 2; printf 'docs/a b\tcafé.md\ndocs/decisions/D-041-ok.md\n' >"$FIXTURE/files-1"; expect_next D-042
}
@test "open list query failure refuses" { touch "$FIXTURE/fail-open"; expect_refusal; }
@test "before detail query failure refuses" { pr 1 0; touch "$FIXTURE/fail-before-1"; expect_refusal; }
@test "files query failure refuses" { pr 1 0; touch "$FIXTURE/fail-files-1"; expect_refusal; }
@test "after detail query failure refuses" { pr 1 0; touch "$FIXTURE/fail-after-1"; expect_refusal; }
@test "later files failure emits no earlier high candidate" {
  pr 1 1; files 1 1 1 D-900
  pr 2 0; touch "$FIXTURE/fail-files-2"; expect_refusal
}
@test "partial files page output followed by failure emits no candidate" {
  pr 1 1; touch "$FIXTURE/partial-1"; expect_refusal
}
