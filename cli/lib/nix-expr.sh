# shellcheck shell=bash
format_nix_call() {
  local indent="$1" lib="$2" func="$3"
  shift 3

  local body=""
  for pair in "$@"; do
    local key="${pair%%=*}" val="${pair#*=}"
    [[ "$key" == "filters" && "$val" == "null" ]] && continue
    body+="${indent}  ${key} = ${val};"$'\n'
  done

  printf '%s%s.%s {\n%s%s}\n' "$indent" "$lib" "$func" "$body" "$indent"
}

nix_string() {
  local esc="${1//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//\$/\\\$}"
  printf '"%s"' "$esc"
}

nix_path_expr() {
  local p="$1"
  if [[ "$p" =~ ^[A-Za-z0-9._/+-]+$ ]]; then
    printf '%s' "$p"
    return 0
  fi
  if [[ "$p" == /* ]]; then
    nix_string "$p"
  else
    printf '(./. + %s)' "$(nix_string "/${p#./}")"
  fi
}

format_fetch_call() {
  local indent="$1" lib="$2" repo_type="$3"
  local repo_id="$4" ref="$5" filter_json="$6" file_tree_hash="$7"
  local tree_path="${8:-}" git_repo_hash="${9:-}"

  local func
  case "$repo_type" in
    dataset) func="fetchDataset" ;;
    space) func="fetchSpace" ;;
    *) func="fetchModel" ;;
  esac

  local args=("repoId=\"$repo_id\"" "rev=\"$ref\"" "filters=$filter_json")
  if [[ -n "$tree_path" ]]; then
    args+=("fileTree=builtins.fromJSON (builtins.readFile $(nix_path_expr "$tree_path"))")
  fi
  args+=("fileTreeHash=\"$file_tree_hash\"")
  if [[ -n "$git_repo_hash" ]]; then
    args+=("gitRepoHash=\"$git_repo_hash\"")
  fi

  format_nix_call "$indent" "$lib" "$func" "${args[@]}"
}

format_git_fetch_call() {
  local indent="$1" lib="$2"
  local git_url="$3" rev="$4" lfs_url="$5" filter_json="$6"
  local lfs_path="${7:-}" git_repo_hash="${8:-}" lfs_json="${9:-}"

  local args=("url=\"$git_url\"" "rev=\"$rev\"" "lfsUrl=\"$lfs_url\"" "filters=$filter_json")
  if [[ -n "$lfs_path" ]]; then
    args+=("lfsFiles=builtins.fromJSON (builtins.readFile $(nix_path_expr "$lfs_path"))")
  elif [[ -n "$lfs_json" ]]; then
    args+=("lfsFiles=builtins.fromJSON $(nix_string "$lfs_json")")
  fi
  if [[ -n "$git_repo_hash" ]]; then
    args+=("gitRepoHash=\"$git_repo_hash\"")
  fi

  format_nix_call "$indent" "$lib" "fetchGitLFS" "${args[@]}"
}

wrap_flake_expr() {
  cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $1
EOF
}

generate_fetch_expr() {
  wrap_flake_expr "$(format_fetch_call "  " "lib" "$@")"
}

generate_git_fetch_expr() {
  wrap_flake_expr "$(format_git_fetch_call "  " "lib" "$@")"
}

build_with_expr() {
  local expr="$1"
  local operation_name="${2:-build}"

  debug "$operation_name expression: $expr"

  local build_output
  if build_output=$(nix --extra-experimental-features 'nix-command flakes' build --impure --expr "$expr" --no-link --print-out-paths); then
    echo "$build_output"
    return 0
  else
    return 1
  fi
}
