#!/bin/bash
#
# Copyright 2022 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Test building targets that are declared as compatible only with certain
# platforms (see the "target_compatible_with" common build rule attribute).

# --- begin runfiles.bash initialization v2 ---
# Copy-pasted from the Bazel Bash runfiles library v2.
set -uo pipefail; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v2 ---

source "$(rlocation bazel_skylib/tests/unittest.bash)" \
  || { echo "Could not source bazel_skylib/tests/unittest.bash" >&2; exit 1; }

# `uname` returns the current platform, e.g "MSYS_NT-10.0" or "Linux".
# `tr` converts all upper case letters to lower case.
# `case` matches the result if the `uname | tr` expression to string prefixes
# that use the same wildcards as names do in Bash, i.e. "msys*" matches strings
# starting with "msys", and "*" matches everything (it's the default case).
case "$(uname -s | tr [:upper:] [:lower:])" in
msys*)
  # As of 2019-01-15, Bazel on Windows only supports MSYS Bash.
  declare -r is_windows=true
  ;;
*)
  declare -r is_windows=false
  ;;
esac

if "$is_windows"; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL="*"
fi

function set_up() {
  mkdir -p target_skipping || fail "couldn't create directory"

  cat > target_skipping/pass.sh <<EOF || fail "couldn't create pass.sh"
#!/bin/bash
exit 0
EOF
  chmod +x target_skipping/pass.sh

  # Platforms
  default_host_platform="@local_config_platform//:host"

  cat > WORKSPACE <<EOF
workspace(name = 'bazel_skylib')
EOF

  cat > BUILD <<EOF
EOF
  cat > bzl_library.bzl <<EOF
def bzl_library(**kwargs):
    """A dummy implementation of bzl_library()."""
    pass
EOF

  mkdir -p lib
  cat > lib/BUILD <<EOF
EOF

  for file in compatibility.bzl selects.bzl compatibility/BUILD compatibility/defs.bzl; do
    mkdir -p "$(dirname "lib/${file}")" \
      || fail "couldn't mkdir for ${file}"
    ln -sf "$(rlocation "bazel_skylib/lib/${file}")" "lib/${file}" \
      || fail "couldn't symlink ${file}."
  done

  cat > target_skipping/BUILD <<EOF || fail "couldn't create BUILD file"
load("//lib:compatibility.bzl", "compatibility")

# We're not validating visibility here. Let everything access these targets.
package(default_visibility = ["//visibility:public"])

constraint_setting(name = "foo_version")

constraint_value(
    name = "foo1",
    constraint_setting = ":foo_version",
)

constraint_value(
    name = "foo2",
    constraint_setting = ":foo_version",
)

constraint_value(
    name = "foo3",
    constraint_setting = ":foo_version",
)

constraint_setting(name = "bar_version")

constraint_value(
    name = "bar1",
    constraint_setting = "bar_version",
)

constraint_value(
    name = "bar2",
    constraint_setting = "bar_version",
)

platform(
    name = "foo1_bar1_platform",
    parents = ["${default_host_platform}"],
    constraint_values = [
        ":foo1",
        ":bar1",
    ],
)

platform(
    name = "foo2_bar1_platform",
    parents = ["${default_host_platform}"],
    constraint_values = [
        ":foo2",
        ":bar1",
    ],
)

platform(
    name = "foo2_bar2_platform",
    parents = ["${default_host_platform}"],
    constraint_values = [
        ":foo2",
        ":bar2",
    ],
)

platform(
    name = "foo3_platform",
    parents = ["${default_host_platform}"],
    constraint_values = [
        ":foo3",
    ],
)

platform(
    name = "bar1_platform",
    parents = ["${default_host_platform}"],
    constraint_values = [
        ":bar1",
    ],
)
EOF
}

# Builds the specified target against various platforms and expects the builds
# to succeed.
function ensure_that_target_builds_for_platforms() {
  local target="$1"
  local platform

  for platform in "${@:2}"; do
    echo "Building ${target} for ${platform}. Expecting success."
    bazel build \
      --show_result=10 \
      --host_platform="${platform}" \
      --platforms="${platform}" \
      --nocache_test_results \
      "${target}"  &> "${TEST_log}" \
      || fail "Bazel failed unexpectedly."

    expect_log "INFO: Build completed successfully"
  done
}

# Builds the specified target against various platforms and expects the builds
# to fail.
function ensure_that_target_doesnt_build_for_platforms() {
  local target="$1"
  local error_string="$2"
  local platform

  for platform in "${@:3}"; do
    echo "Building ${target} for ${platform}. Expecting failure."
    bazel build \
      --show_result=10 \
      --host_platform="${platform}" \
      --platforms="${platform}" \
      --nocache_test_results \
      "${target}"  &> "${TEST_log}" \
      && fail "Bazel passed unexpectedly."

    expect_log "ERROR: Target ${target} is incompatible and cannot be built, but was explicitly requested"
    expect_log " <-- target platform (${platform}) ${error_string}"
    expect_log 'FAILED: Build did NOT complete successfully'
  done
}

# Validates that we can express targets being compatible with A _or_ B.
function test_any_of_logic() {
  cat >> target_skipping/BUILD <<EOF
sh_test(
    name = "pass_on_foo1_or_foo2_but_not_on_foo3",
    srcs = [":pass.sh"],
    target_compatible_with = compatibility.any_of(":foo1", ":foo2"),
)
EOF

  ensure_that_target_builds_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_on_foo3 \
    //target_skipping:foo1_bar1_platform \
    //target_skipping:foo2_bar1_platform \
    //target_skipping:foo2_bar2_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_on_foo3 \
    "didn't satisfy constraint //lib/compatibility:any_of$" \
    //target_skipping:foo3_platform \
    //target_skipping:bar1_platform
}

# Validates that we can express targets being compatible with everything _but_
# A and B.
function test_none_of_logic() {
  cat >> target_skipping/BUILD <<EOF
sh_test(
    name = "pass_on_everything_but_foo1_and_foo2",
    srcs = [":pass.sh"],
    target_compatible_with = compatibility.none_of(":foo1", ":foo2"),
)
EOF

  ensure_that_target_builds_for_platforms \
    //target_skipping:pass_on_everything_but_foo1_and_foo2 \
    //target_skipping:foo3_platform \
    //target_skipping:bar1_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_everything_but_foo1_and_foo2 \
    "didn't satisfy constraint //lib/compatibility:none_of$" \
    //target_skipping:foo1_bar1_platform \
    //target_skipping:foo2_bar1_platform \
    //target_skipping:foo2_bar2_platform
}

# Validates that we can express targets being compatible with _only_ A and B,
# and nothing else.
function test_all_of_logic() {
  cat >> target_skipping/BUILD <<EOF
sh_test(
    name = "pass_on_only_foo1_and_bar1",
    srcs = [":pass.sh"],
    target_compatible_with = compatibility.all_of(":foo1", ":bar1"),
)
EOF

  ensure_that_target_builds_for_platforms \
    //target_skipping:pass_on_only_foo1_and_bar1 \
    //target_skipping:foo1_bar1_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_only_foo1_and_bar1 \
    "didn't satisfy constraints\\? \\[\\?//lib/compatibility:all_of_" \
    //target_skipping:foo2_bar1_platform \
    //target_skipping:foo2_bar2_platform \
    //target_skipping:foo3_platform \
    //target_skipping:bar1_platform
}

# Validates that we can express composed incompatibility.
function test_composition() {
  cat >> target_skipping/BUILD <<EOF
sh_test(
    name = "pass_on_foo1_or_foo2_but_not_bar1",
    srcs = [":pass.sh"],
    target_compatible_with = compatibility.any_of(
        ":foo1",
        ":foo2",
    ) + compatibility.none_of(
        ":bar1",
    ),
)
EOF

  ensure_that_target_builds_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_bar1 \
    //target_skipping:foo2_bar2_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_bar1 \
    "didn't satisfy constraint //lib/compatibility:none_of$" \
    //target_skipping:foo1_bar1_platform \
    //target_skipping:foo2_bar1_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_bar1 \
    "didn't satisfy constraint //lib/compatibility:any_of$" \
    //target_skipping:foo3_platform

  ensure_that_target_doesnt_build_for_platforms \
    //target_skipping:pass_on_foo1_or_foo2_but_not_bar1 \
    "didn't satisfy constraints \\[//lib/compatibility:" \
    //target_skipping:bar1_platform
  # Since the order of constraints isn't guaranteed until
  # 72787a1267a6087923aca83bf161f93c0a1323e0, we do two individual checks here.
  expect_log "//lib/compatibility:any_of\\>"
  expect_log "//lib/compatibility:none_of\\>"
}

cd "$TEST_TMPDIR"
run_suite "compatibility tests"
