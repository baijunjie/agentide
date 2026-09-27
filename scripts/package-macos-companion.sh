#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: package-macos-companion.sh OUTPUT_DIR ARCH" >&2
  exit 64
fi

output_dir=$1
expected_archs=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
node_runtime="$repo_root/node_modules/node/bin/node"
runtime_entitlements="$script_dir/macos-companion-runtime.entitlements"

if [ ! -x "$node_runtime" ]; then
  echo "standalone Node runtime is missing; run pnpm install" >&2
  exit 1
fi

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentide-companion.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM

cd "$repo_root"
pnpm --filter @agentide/agent-host build
pnpm --filter @agentide/agent-host deploy --prod --legacy "$staging_dir/AgentHost"
rm -rf "$staging_dir/AgentHost/src" "$staging_dir/AgentHost/test" "$staging_dir/AgentHost/native"
find "$staging_dir/AgentHost" -name '*.d.ts' -delete
find "$staging_dir/AgentHost" -name '*.tsbuildinfo' -delete
cp "$node_runtime" "$staging_dir/AgentHost/node"
helper_parts="$staging_dir/helper-parts"
mkdir -p "$helper_parts"
helper_inputs=""
for expected_arch in $expected_archs; do
  helper_part="$helper_parts/file-access-$expected_arch"
  cc -Wall -Wextra -Werror -arch "$expected_arch" "$repo_root/apps/agent-host/native/file-access.c" -o "$helper_part"
  helper_inputs="$helper_inputs $helper_part"
done
# The paths are generated in a private temporary directory and cannot contain shell separators.
# shellcheck disable=SC2086
lipo -create $helper_inputs -output "$staging_dir/AgentHost/dist/native/file-access"
chmod 755 "$staging_dir/AgentHost/node" "$staging_dir/AgentHost/dist/native/file-access"

find "$staging_dir/AgentHost" -type f -perm -111 | while IFS= read -r executable; do
  if file "$executable" | grep -q 'Mach-O'; then
    executable_archs=$(lipo -archs "$executable")
    for expected_arch in $expected_archs; do
      case " $executable_archs " in
        *" $expected_arch "*) ;;
        *)
          echo "$executable architectures ($executable_archs) do not include $expected_arch" >&2
          exit 1
          ;;
      esac
    done
  fi
done

rm -rf "$output_dir"
mkdir -p "$(dirname -- "$output_dir")"
mv "$staging_dir/AgentHost" "$output_dir"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  find "$output_dir" -type f -perm -111 | while IFS= read -r executable; do
    if file "$executable" | grep -q 'Mach-O'; then
      case "$(basename -- "$executable")" in
        node|claude)
          /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --entitlements "$runtime_entitlements" "$executable"
          ;;
        *)
          /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$executable"
          ;;
      esac
    fi
  done
fi

runtime_probe=$("$output_dir/node" -p "'agentide-runtime-ok'")
if [ "$runtime_probe" != "agentide-runtime-ok" ]; then
  echo "packaged Node runtime failed its execution probe" >&2
  exit 1
fi
