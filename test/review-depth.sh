#!/usr/bin/env bash
# Tests for bin/review-depth. All diffs and gh output are local fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/review-depth"
fail() { echo "FAIL: $1" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-review-depth.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

expect_output() {
  local expected="$1"; shift
  local out rc
  out="$("$BIN" "$@" 2>"$T/stderr")"; rc=$?
  [ "$rc" -eq 0 ] || fail "command '$*' exited $rc: $(cat "$T/stderr")"
  [ "$out" = "$expected" ] || fail "command '$*' returned [$out], expected [$expected]"
  case "$out" in
    full\ *|single\ *) ;;
    *) fail "command '$*' did not print a depth and reason: [$out]" ;;
  esac
}
expect_failure() {
  local label="$1"; shift
  local rc
  "$BIN" "$@" >"$T/stdout" 2>"$T/stderr"; rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded"
}

cat >"$T/pub-fn.diff" <<'DIFF'
diff --git a/src/api.rs b/src/api.rs
--- a/src/api.rs
+++ b/src/api.rs
@@ -1 +1 @@
-pub fn review_depth_fn() -> u8 { 0 }
+pub fn review_depth_fn() -> u16 { 0 }
DIFF
expect_output 'full rust pub line file=src/api.rs' "$T/pub-fn.diff"

cat >"$T/pub-field.diff" <<'DIFF'
diff --git a/src/model.rs b/src/model.rs
--- a/src/model.rs
+++ b/src/model.rs
@@ -1 +1 @@
-    pub review_depth_value: u8,
+    pub review_depth_value: u16,
DIFF
expect_output 'full rust pub line file=src/model.rs' "$T/pub-field.diff"

for item in struct enum trait; do
  cat >"$T/pub-$item.diff" <<DIFF
diff --git a/src/$item.rs b/src/$item.rs
--- a/src/$item.rs
+++ b/src/$item.rs
@@ -1 +1 @@
-pub $item ReviewDepthThing;
+pub $item ReviewDepthThing { }
DIFF
  expect_output "full rust pub line file=src/$item.rs" "$T/pub-$item.diff"
done

cat >"$T/pub-crate.diff" <<'DIFF'
diff --git a/src/visibility.rs b/src/visibility.rs
--- a/src/visibility.rs
+++ b/src/visibility.rs
@@ -1 +1 @@
-pub(crate) fn local_api() {}
+pub(crate) fn local_api(value: u8) {}
DIFF
expect_output 'full rust pub line file=src/visibility.rs' "$T/pub-crate.diff"

cat >"$T/impl-pub.diff" <<'DIFF'
diff --git a/src/impl.rs b/src/impl.rs
--- a/src/impl.rs
+++ b/src/impl.rs
@@ -1 +1 @@
-impl ReviewDepthWidget { fn new() -> Self { Self } }
+impl ReviewDepthWidget { pub fn new() -> Self { Self } }
DIFF
expect_output 'full rust pub line file=src/impl.rs' "$T/impl-pub.diff"

cat >"$T/persisted.diff" <<'DIFF'
diff --git a/src/record.rs b/src/record.rs
--- a/src/record.rs
+++ b/src/record.rs
@@ -1 +1 @@
-#[derive(Serialize)]
+#[derive(Serialize, Deserialize)]
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=src/record.rs' "$T/persisted.diff"

cat >"$T/persisted-context.diff" <<'DIFF'
diff --git a/src/model.rs b/src/model.rs
--- a/src/model.rs
+++ b/src/model.rs
@@ -1,5 +1,5 @@
 #[derive(Serialize, Deserialize)]
 struct Saved {
-    value: u8,
+    value: u16,
 }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=src/model.rs' "$T/persisted-context.diff"

cat >"$T/spawn.diff" <<'DIFF'
diff --git a/src/worker.rs b/src/worker.rs
--- a/src/worker.rs
+++ b/src/worker.rs
@@ -1 +1 @@
-let child = None;
+let child = Command::new("worker").spawn()?;
DIFF
expect_output 'full locking/process-lifetime signal=spawn file=src/worker.rs' "$T/spawn.diff"

cat >"$T/lock.diff" <<'DIFF'
diff --git a/src/state.rs b/src/state.rs
--- a/src/state.rs
+++ b/src/state.rs
@@ -1 +1 @@
-let guard = state.get();
+let guard = state.lock().unwrap();
DIFF
expect_output 'full locking/process-lifetime signal=lock( file=src/state.rs' "$T/lock.diff"

cat >"$T/large.diff" <<'DIFF'
diff --git a/src/large.rs b/src/large.rs
--- a/src/large.rs
+++ b/src/large.rs
@@ -0,0 +1,3 @@
+private_one();
+private_two();
+private_three();
DIFF
expect_output 'full non-test lines=3 threshold=2' "$T/large.diff" --threshold 2

cat >"$T/private.diff" <<'DIFF'
diff --git a/src/private.rs b/src/private.rs
--- a/src/private.rs
+++ b/src/private.rs
@@ -0,0 +1 @@
+fn helper(value: u8) {}
DIFF
expect_output 'single non-test lines=1 threshold=700' "$T/private.diff"

cat >"$T/rust-test.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,3 +1,3 @@
 #[cfg(test)]
 mod tests {
-    pub fn review_depth_test_helper() {}
+    pub fn review_depth_test_helper(value: u8) {}
 }
DIFF
expect_output 'full rust pub line file=src/thing.rs' "$T/rust-test.diff"

cat >"$T/rust-test-serde.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,5 +1,5 @@
 #[cfg(test)]
 mod tests {
-    #[derive(Serialize)]
+    #[derive(Serialize, Deserialize)]
     struct Saved;
 }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=src/thing.rs' "$T/rust-test-serde.diff"

cat >"$T/rust-test-braces-then-production.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,8 +1,8 @@
 #[cfg(test)]
 mod tests {
     #[test]
     fn helper() {
         let text = "{";
         // {
     }
 }
-pub fn value() -> u8 { 0 }
+pub fn value() -> u16 { 0 }
DIFF
expect_output 'full rust pub line file=src/thing.rs' "$T/rust-test-braces-then-production.diff"

cat >"$T/rust-test-large-edit.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,4 +1,8 @@
 #[cfg(test)]
 mod tests {
-    fn old() {}
+    fn helper() {
+        private_one();
+        private_two();
+        private_three();
+    }
 }
DIFF
expect_output 'single non-test lines=0 threshold=2' "$T/rust-test-large-edit.diff" --threshold 2

cat >"$T/rust-test-then-production.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,5 +1,5 @@
 #[cfg(test)]
 mod tests {
     fn helper() {}
 }
-pub fn value() -> u8 { 0 }
+pub fn value() -> u16 { 0 }
DIFF
expect_output 'full rust pub line file=src/thing.rs' "$T/rust-test-then-production.diff"

cat >"$T/rust-production-before-test.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,5 +1,5 @@
-pub fn value() -> u8 { 0 }
+pub fn value() -> u16 { 0 }
 #[cfg(test)]
 mod tests {
     fn helper() {}
 }
DIFF
expect_output 'full rust pub line file=src/thing.rs' "$T/rust-production-before-test.diff"

cat >"$T/rust-private-before-test.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,5 +1,5 @@
-fn value() -> u8 { 0 }
+fn value() -> u16 { 0 }
 #[cfg(test)]
 mod tests {
     fn helper() {}
 }
DIFF
expect_output 'full non-test lines=2 threshold=1' "$T/rust-private-before-test.diff" --threshold 1

cat >"$T/test-path.diff" <<'DIFF'
diff --git a/tests/review_depth.rs b/tests/review_depth.rs
--- a/tests/review_depth.rs
+++ b/tests/review_depth.rs
@@ -1 +1,2 @@
-fn test_helper() {}
+pub fn test_helper() {}
+private_test_line();
DIFF
expect_output 'single non-test lines=0 threshold=700' "$T/test-path.diff"

cat >"$T/test-path-serde.diff" <<'DIFF'
diff --git a/tests/serde_model.rs b/tests/serde_model.rs
--- a/tests/serde_model.rs
+++ b/tests/serde_model.rs
@@ -1 +1 @@
-#[derive(Serialize)]
+#[derive(Serialize, Deserialize)]
DIFF
expect_output 'single non-test lines=0 threshold=700' "$T/test-path-serde.diff"

out="$(cat "$T/private.diff" | "$BIN" 2>"$T/stderr")" || fail "stdin diff classification failed"
[ "$out" = 'single non-test lines=1 threshold=700' ] || fail "stdin returned [$out]"

cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >"$T/gh.args"
cat "$T/private.diff"
EOF
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH" expect_output 'single non-test lines=1 threshold=700' --pr 42 --repo aakshintala/switchyard
[ "$(cat "$T/gh.args")" = 'pr diff 42 --repo aakshintala/switchyard' ] || fail "--pr used the expected gh command"

expect_output 'full non-test lines=1 threshold=0' "$T/private.diff" --threshold 0
REVIEW_DEPTH_THRESHOLD=0 expect_output 'full non-test lines=1 threshold=0' "$T/private.diff"
expect_failure 'negative threshold' "$T/private.diff" --threshold -1
expect_failure 'invalid CLI threshold' "$T/private.diff" --threshold nope
REVIEW_DEPTH_THRESHOLD=nope "$BIN" "$T/private.diff" >"$T/stdout" 2>"$T/stderr"
[ "$?" -ne 0 ] || fail "invalid threshold environment unexpectedly succeeded"
expect_failure 'missing diff' "$T/missing.diff"
expect_failure 'repo without PR' --repo aakshintala/switchyard

printf 'review-depth: all cases passed\n'
