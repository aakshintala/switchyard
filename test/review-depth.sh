#!/usr/bin/env bash
# Tests for bin/review-depth. All diffs, crates and gh output are local fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/review-depth"
fail() { echo "FAIL: $1" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-review-depth.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/outside" "$T/repo/crate-a/src" "$T/repo/crate-b/src" "$T/bin"

expect_output() {
  local expected="$1"; shift
  local out rc
  out="$("$BIN" "$@" 2>"$T/stderr")"; rc=$?
  [ "$rc" -eq 0 ] || fail "command '$*' exited $rc: $(cat "$T/stderr")"
  [ "$out" = "$expected" ] || fail "command '$*' returned [$out], expected [$expected]"
}
expect_failure() {
  local label="$1"; shift
  local rc
  "$BIN" "$@" >"$T/stdout" 2>"$T/stderr"; rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded"
}

cat >"$T/pub.diff" <<'DIFF'
diff --git a/src/api.rs b/src/api.rs
--- a/src/api.rs
+++ b/src/api.rs
@@ -1 +1 @@
+pub fn public_api() {}
DIFF
# No root means the current working directory decides whether grep is available.
(cd "$T/outside" && "$BIN" "$T/pub.diff") >"$T/outside.out" || fail "diff-only public API classification failed"
grep -q '^full pub signature public_api (diff-only; no repo root)$' "$T/outside.out" || fail "no-root result names diff-only signal"
out="$("$BIN" "$T/pub.diff")" || fail "default root classification failed"
[ "$out" = 'single non-test lines=1 threshold=700' ] || fail "default git root returned [$out]"

cat >"$T/repo/Cargo.toml" <<'TOML'
[workspace]
members = ["crate-a", "crate-b"]
TOML
printf '[package]\nname="crate-a"\nversion="0.1.0"\nedition="2024"\n' >"$T/repo/crate-a/Cargo.toml"
printf '[package]\nname="crate-b"\nversion="0.1.0"\nedition="2024"\n' >"$T/repo/crate-b/Cargo.toml"
printf 'pub struct PublicThing;\n' >"$T/repo/crate-a/src/lib.rs"
printf 'use crate_a::PublicThing;\n' >"$T/repo/crate-b/src/lib.rs"
cat >"$T/cross-crate.diff" <<'DIFF'
diff --git a/crate-a/src/lib.rs b/crate-a/src/lib.rs
--- a/crate-a/src/lib.rs
+++ b/crate-a/src/lib.rs
@@ -1 +1 @@
-pub struct PublicThing;
+pub struct PublicThing { pub field: u8 }
DIFF
expect_output 'full pub signature PublicThing used by another crate' \
  "$T/cross-crate.diff" --repo-root "$T/repo"

# A changed enum variant inherits the public API of its enclosing enum.
printf 'pub enum Mode {\n    Existing,\n    New,\n}\n' >"$T/repo/crate-a/src/mode.rs"
printf 'use crate_a::Mode;\nfn matches(mode: Mode) { match mode { Mode::Existing => (), Mode::New => () } }\n' >"$T/repo/crate-b/src/lib.rs"
cat >"$T/enum-variant.diff" <<'DIFF'
diff --git a/crate-a/src/mode.rs b/crate-a/src/mode.rs
--- a/crate-a/src/mode.rs
+++ b/crate-a/src/mode.rs
@@ -1,3 +1,4 @@
 pub enum Mode {
     Existing,
+    New,
 }
DIFF
expect_output 'full pub signature Mode used by another crate' \
  "$T/enum-variant.diff" --repo-root "$T/repo"
cat >"$T/enum-variant-file-context.diff" <<'DIFF'
diff --git a/crate-a/src/mode.rs b/crate-a/src/mode.rs
--- a/crate-a/src/mode.rs
+++ b/crate-a/src/mode.rs
@@ -3 +3 @@
-    Old,
+    New,
DIFF
expect_output 'full pub signature Mode used by another crate' \
  "$T/enum-variant-file-context.diff" --repo-root "$T/repo"

cat >"$T/multiline-signature.diff" <<'DIFF'
diff --git a/crate-a/src/lib.rs b/crate-a/src/lib.rs
--- a/crate-a/src/lib.rs
+++ b/crate-a/src/lib.rs
@@ -1,3 +1,3 @@
 pub fn MultiArg(
-    first: u8,
+    first: u16,
 ) {}
DIFF
printf 'let _ = MultiArg(1);\n' >"$T/repo/crate-b/src/lib.rs"
expect_output 'full pub signature MultiArg used by another crate' \
  "$T/multiline-signature.diff" --repo-root "$T/repo"
printf 'use crate_a::PublicThing;\n' >"$T/repo/crate-b/src/lib.rs"
cat >"$T/pub-field.diff" <<'DIFF'
diff --git a/crate-a/src/lib.rs b/crate-a/src/lib.rs
--- a/crate-a/src/lib.rs
+++ b/crate-a/src/lib.rs
@@ -1 +1 @@
+    pub field: u8,
DIFF
printf 'let value = thing.field;\n' >"$T/repo/crate-b/src/lib.rs"
expect_output 'full pub signature field used by another crate' \
  "$T/pub-field.diff" --repo-root "$T/repo"

# A changed field inherits serialization markers from its enclosing type.
printf '#[derive(Serialize, Deserialize)]\nstruct SavedState {\n    value: String,\n}\n' >"$T/repo/crate-a/src/saved_state.rs"
cat >"$T/serialized-field.diff" <<'DIFF'
diff --git a/crate-a/src/saved_state.rs b/crate-a/src/saved_state.rs
--- a/crate-a/src/saved_state.rs
+++ b/crate-a/src/saved_state.rs
@@ -2,3 +2,3 @@
 struct SavedState {
-    value: u32,
+    value: String,
 }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/saved_state.rs' \
  "$T/serialized-field.diff" --repo-root "$T/repo"
cat >"$T/serialized-file-context.diff" <<'DIFF'
diff --git a/crate-a/src/saved_state.rs b/crate-a/src/saved_state.rs
--- a/crate-a/src/saved_state.rs
+++ b/crate-a/src/saved_state.rs
@@ -3 +3 @@
-    value: u32,
+    value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/saved_state.rs' \
  "$T/serialized-file-context.diff" --repo-root "$T/repo"
cat >"$T/serialized-context.diff" <<'DIFF'
diff --git a/src/saved.rs b/src/saved.rs
--- a/src/saved.rs
+++ b/src/saved.rs
@@ -1,4 +1,4 @@
 #[derive(Serialize, Deserialize)]
 struct SavedState {
-    value: u32,
+    value: String,
 }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=src/saved.rs' \
  "$T/serialized-context.diff" --repo-root "$T/outside"

# Enclosing-type lookup covers multiline attrs, stacked attrs, docs, and generics.
cat >"$T/repo/crate-a/src/multiline_derive.rs" <<'RUST'
#[derive(
    Debug,
    Serialize,
    Deserialize,
)]
struct MultiDerived {
    value: String,
}
RUST
cat >"$T/multiline-derive.diff" <<'DIFF'
diff --git a/crate-a/src/multiline_derive.rs b/crate-a/src/multiline_derive.rs
--- a/crate-a/src/multiline_derive.rs
+++ b/crate-a/src/multiline_derive.rs
@@ -7 +7 @@
-    value: u32,
+    value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/multiline_derive.rs' \
  "$T/multiline-derive.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/multiline_serde.rs" <<'RUST'
#[serde(
    rename_all = "snake_case",
)]
struct SerdeConfig {
    value: String,
}
RUST
cat >"$T/multiline-serde.diff" <<'DIFF'
diff --git a/crate-a/src/multiline_serde.rs b/crate-a/src/multiline_serde.rs
--- a/crate-a/src/multiline_serde.rs
+++ b/crate-a/src/multiline_serde.rs
@@ -5 +5 @@
-    value: u32,
+    value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde attribute file=crate-a/src/multiline_serde.rs' \
  "$T/multiline-serde.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/cfg_attr.rs" <<'RUST'
#[cfg_attr(
    feature = "serde",
    derive(Serialize),
)]
struct Conditional {
    value: String,
}
RUST
cat >"$T/cfg-attr.diff" <<'DIFF'
diff --git a/crate-a/src/cfg_attr.rs b/crate-a/src/cfg_attr.rs
--- a/crate-a/src/cfg_attr.rs
+++ b/crate-a/src/cfg_attr.rs
@@ -6 +6 @@
-    value: u32,
+    value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde type file=crate-a/src/cfg_attr.rs' \
  "$T/cfg-attr.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/generic_state.rs" <<'RUST'
#[allow(dead_code)]
#[serde(
    rename_all = "snake_case",
)]
/// Persisted generic state.
struct GenericState<T>
where
    T: Clone,
{
    value: T,
}
RUST
cat >"$T/generic-where-doc-stack.diff" <<'DIFF'
diff --git a/crate-a/src/generic_state.rs b/crate-a/src/generic_state.rs
--- a/crate-a/src/generic_state.rs
+++ b/crate-a/src/generic_state.rs
@@ -10 +10 @@
-    value: T,
+    value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde attribute file=crate-a/src/generic_state.rs' \
  "$T/generic-where-doc-stack.diff" --repo-root "$T/repo"

# Tuple structs and inline item bodies use the same serialization and API checks.
cat >"$T/repo/crate-a/src/inline_id.rs" <<'RUST'
#[derive(Serialize)]
struct InlineId(String);
RUST
cat >"$T/single-tuple.diff" <<'DIFF'
diff --git a/crate-a/src/inline_id.rs b/crate-a/src/inline_id.rs
--- a/crate-a/src/inline_id.rs
+++ b/crate-a/src/inline_id.rs
@@ -2 +2 @@
-struct InlineId(u32);
+struct InlineId(String);
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/inline_id.rs' \
  "$T/single-tuple.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/id.rs" <<'RUST'
pub struct Id<T>(
    pub String,
) where T: Clone;
RUST
printf 'use crate_a::Id;\nfn uses_id(id: Id<String>) {}\n' >"$T/repo/crate-b/src/lib.rs"
cat >"$T/multiline-tuple-public.diff" <<'DIFF'
diff --git a/crate-a/src/id.rs b/crate-a/src/id.rs
--- a/crate-a/src/id.rs
+++ b/crate-a/src/id.rs
@@ -2 +2 @@
-    pub u32,
+    pub String,
DIFF
expect_output 'full pub signature Id used by another crate' \
  "$T/multiline-tuple-public.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/inline_state.rs" <<'RUST'
#[derive(Serialize)]
struct InlineState { value: String }
RUST
cat >"$T/single-struct.diff" <<'DIFF'
diff --git a/crate-a/src/inline_state.rs b/crate-a/src/inline_state.rs
--- a/crate-a/src/inline_state.rs
+++ b/crate-a/src/inline_state.rs
@@ -2 +2 @@
-struct InlineState { value: u32 }
+struct InlineState { value: String }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/inline_state.rs' \
  "$T/single-struct.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/inline_mode.rs" <<'RUST'
#[derive(Serialize)]
enum InlineMode { New, }
RUST
cat >"$T/single-enum.diff" <<'DIFF'
diff --git a/crate-a/src/inline_mode.rs b/crate-a/src/inline_mode.rs
--- a/crate-a/src/inline_mode.rs
+++ b/crate-a/src/inline_mode.rs
@@ -2 +2 @@
-enum InlineMode { Old, }
+enum InlineMode { New, }
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/inline_mode.rs' \
  "$T/single-enum.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/packet-tuple.rs" <<'RUST'
#[derive(
    Serialize,
)]
enum PacketTuple {
    Data(
        String,
    ),
}
RUST
cat >"$T/enum-tuple-payload.diff" <<'DIFF'
diff --git a/crate-a/src/packet-tuple.rs b/crate-a/src/packet-tuple.rs
--- a/crate-a/src/packet-tuple.rs
+++ b/crate-a/src/packet-tuple.rs
@@ -6 +6 @@
-        u32,
+        String,
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/packet-tuple.rs' \
  "$T/enum-tuple-payload.diff" --repo-root "$T/repo"

cat >"$T/repo/crate-a/src/packet-struct.rs" <<'RUST'
#[derive(
    Serialize,
)]
enum PacketStruct {
    Data {
        value: String,
    },
}
RUST
cat >"$T/enum-struct-payload.diff" <<'DIFF'
diff --git a/crate-a/src/packet-struct.rs b/crate-a/src/packet-struct.rs
--- a/crate-a/src/packet-struct.rs
+++ b/crate-a/src/packet-struct.rs
@@ -6 +6 @@
-        value: u32,
+        value: String,
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=crate-a/src/packet-struct.rs' \
  "$T/enum-struct-payload.diff" --repo-root "$T/repo"

printf 'pub struct PrivateUse;\n' >"$T/repo/crate-a/src/lib.rs"
cat >"$T/unreferenced.diff" <<'DIFF'
diff --git a/crate-a/src/lib.rs b/crate-a/src/lib.rs
--- a/crate-a/src/lib.rs
+++ b/crate-a/src/lib.rs
@@ -1 +1 @@
+pub struct NoOtherCrateUse;
DIFF
expect_output 'single non-test lines=1 threshold=700' \
  "$T/unreferenced.diff" --repo-root "$T/repo"

# The API signal precedes serialization and process-lifetime signals.
printf 'use crate_a::PublicThing;\n' >"$T/repo/crate-b/src/lib.rs"
cat >"$T/ordered.diff" <<'DIFF'
diff --git a/crate-a/src/lib.rs b/crate-a/src/lib.rs
--- a/crate-a/src/lib.rs
+++ b/crate-a/src/lib.rs
@@ -1 +1,3 @@
+pub struct PublicThing;
+#[derive(Serialize)]
+let child = Command::new("x").spawn()?;
DIFF
expect_output 'full pub signature PublicThing used by another crate' \
  "$T/ordered.diff" --repo-root "$T/repo"

cat >"$T/persisted.diff" <<'DIFF'
diff --git a/src/record.rs b/src/record.rs
--- a/src/record.rs
+++ b/src/record.rs
@@ -1 +1 @@
+#[derive(Serialize, Deserialize)]
DIFF
expect_output 'full persisted/wire-format signal=serde derive file=src/record.rs' "$T/persisted.diff" --repo-root "$T/outside"
cat >"$T/schema.diff" <<'DIFF'
diff --git a/migrations/004_add_state.sql b/migrations/004_add_state.sql
--- /dev/null
+++ b/migrations/004_add_state.sql
@@ -0,0 +1 @@
+ALTER TABLE jobs ADD COLUMN state TEXT;
DIFF
expect_output 'full persisted/wire-format signal=schema or migration file file=migrations/004_add_state.sql' "$T/schema.diff" --repo-root "$T/outside"
cat >"$T/proto.diff" <<'DIFF'
diff --git a/proto/job.proto b/proto/job.proto
--- /dev/null
+++ b/proto/job.proto
@@ -0,0 +1,2 @@
+message JobRecord {
+  string id = 1;
DIFF
expect_output 'full persisted/wire-format signal=wire or schema file file=proto/job.proto' "$T/proto.diff" --repo-root "$T/outside"
cat >"$T/json-writer.diff" <<'DIFF'
diff --git a/src/records.rs b/src/records.rs
--- a/src/records.rs
+++ b/src/records.rs
@@ -1 +1 @@
+serde_json::to_writer(file, &record)?;
DIFF
expect_output 'full persisted/wire-format signal=JSON record writer file=src/records.rs' "$T/json-writer.diff" --repo-root "$T/outside"

cat >"$T/process.diff" <<'DIFF'
diff --git a/src/worker.rs b/src/worker.rs
--- a/src/worker.rs
+++ b/src/worker.rs
@@ -1 +1 @@
+let child = Command::new("worker").spawn()?;
DIFF
expect_output 'full locking/process-lifetime signal=spawn file=src/worker.rs' "$T/process.diff" --repo-root "$T/outside"
cat >"$T/lock.diff" <<'DIFF'
diff --git a/src/state.rs b/src/state.rs
--- a/src/state.rs
+++ b/src/state.rs
@@ -1 +1 @@
+let guard = state.lock().unwrap();
DIFF
expect_output 'full locking/process-lifetime signal=lock( file=src/state.rs' "$T/lock.diff" --repo-root "$T/outside"

python3 -I - "$T/large.diff" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("diff --git a/src/large.rs b/src/large.rs\n--- a/src/large.rs\n+++ b/src/large.rs\n@@ -0,0 +1,701 @@\n")
    for n in range(701):
        f.write(f"+line_{n};\n")
PY
expect_output 'full non-test lines=701 threshold=700' "$T/large.diff" --repo-root "$T/outside"
python3 -I - "$T/threshold.diff" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("diff --git a/src/plain.rs b/src/plain.rs\n--- a/src/plain.rs\n+++ b/src/plain.rs\n@@ -0,0 +1,3 @@\n+one\n+two\n+three\n")
PY
expect_output 'full non-test lines=3 threshold=2' "$T/threshold.diff" --threshold 2 --repo-root "$T/outside"
expect_output 'single non-test lines=1 threshold=1' "$T/unreferenced.diff" --threshold 1 --repo-root "$T/repo"
REVIEW_DEPTH_THRESHOLD=0 expect_output 'full non-test lines=1 threshold=0' "$T/unreferenced.diff" --repo-root "$T/repo"
out="$(cat "$T/unreferenced.diff" | "$BIN" --repo-root "$T/repo")" || fail "stdin diff classification failed"
[ "$out" = 'single non-test lines=1 threshold=700' ] || fail "stdin returned [$out]"

cat >"$T/test-path.diff" <<'DIFF'
diff --git a/test/test_review_depth.sh b/test/test_review_depth.sh
--- a/test/test_review_depth.sh
+++ b/test/test_review_depth.sh
@@ -1 +1,3 @@
+one
+two
+three
DIFF
expect_output 'single non-test lines=0 threshold=700' "$T/test-path.diff" --repo-root "$T/outside"
cat >"$T/rust-test.diff" <<'DIFF'
diff --git a/src/thing.rs b/src/thing.rs
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,4 +1,5 @@
 #[cfg(test)]
 mod tests {
-    assert_eq!(1, 2);
+    assert_eq!(2, 2);
+    assert!(true);
 }
DIFF
expect_output 'single non-test lines=0 threshold=700' "$T/rust-test.diff" --repo-root "$T/outside"

cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >"$T/gh.args"
cat "$T/pr.diff"
EOF
chmod +x "$T/bin/gh"
cp "$T/unreferenced.diff" "$T/pr.diff"
PATH="$T/bin:$PATH" expect_output 'single non-test lines=1 threshold=700' --pr 42 --repo aakshintala/switchyard --repo-root "$T/outside"
[ "$(cat "$T/gh.args")" = 'pr diff 42 --repo aakshintala/switchyard' ] || fail "--pr used the expected gh command"

expect_failure 'negative threshold' "$T/unreferenced.diff" --threshold -1
expect_failure 'invalid CLI threshold' "$T/unreferenced.diff" --repo-root "$T/repo" --threshold nope
REVIEW_DEPTH_THRESHOLD=nope "$BIN" "$T/unreferenced.diff" --repo-root "$T/repo" >"$T/stdout" 2>"$T/stderr"
[ "$?" -ne 0 ] || fail "invalid threshold environment unexpectedly succeeded"
expect_failure 'missing diff' "$T/missing.diff"
expect_failure 'repo without PR' --repo aakshintala/switchyard

printf 'review-depth: ok\n'
