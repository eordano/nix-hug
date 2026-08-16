# shellcheck shell=bash
NIX_HUG_FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

discover_hash_fast() {
  local url="$1"

  debug "Discovering hash for $url"

  local hash=""

  if command -v nix-prefetch-url >/dev/null 2>&1; then
    if hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null); then
      if [[ "$hash" != sha256-* ]]; then
        hash=$(nix --extra-experimental-features 'nix-command' hash convert --hash-algo sha256 --to sri "$hash" 2>/dev/null) || hash=""
      fi
    fi
  fi

  if [[ -z "$hash" ]]; then
    local output
    if output=$(nix --extra-experimental-features 'nix-command flakes' eval --impure --expr "builtins.fetchurl { url = \"$url\"; sha256 = \"$NIX_HUG_FAKE_HASH\"; }" 2>&1); then
      warn "Expected hash mismatch but eval succeeded for $url"
      return 1
    fi
    hash=$(echo "$output" | grep -o 'got: *sha256[-:][A-Za-z0-9+/=]*' |
      grep -o 'sha256[-:][A-Za-z0-9+/=]*' | tail -1)
  fi

  if [[ -z "$hash" || "$hash" == "$NIX_HUG_FAKE_HASH" ]]; then
    error "Could not discover hash for $url"
    debug "Eval output was: $output"
    return 1
  fi

  echo "$hash"
}

discover_git_lfs_files() {
  local git_url="$1" rev="$2"

  local expr
  expr="let
    flake = builtins.getFlake \"$(get_flake_path)\";
    nh = flake.lib.\${builtins.currentSystem};
  in
  nh.fetchGitLfsFiles { url = \"$git_url\"; rev = \"$rev\"; }"

  nix --extra-experimental-features 'nix-command flakes' eval --impure --json --expr "$expr"
}

discover_git_repo_hash() {
  local git_url="$1" rev="$2"

  debug "Discovering git repo hash for $git_url at $rev"

  local expr output
  expr="let
    flake = builtins.getFlake \"$(get_flake_path)\";
    pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
  in
  pkgs.fetchgit {
    url = \"$git_url\";
    rev = \"$rev\";
    fetchLFS = false;
    hash = \"$NIX_HUG_FAKE_HASH\";
  }"

  if output=$(nix --extra-experimental-features 'nix-command flakes' build --impure --no-link --expr "$expr" 2>&1); then
    warn "Expected hash mismatch but the build succeeded for $git_url"
    return 1
  fi

  local hash
  hash=$(echo "$output" | grep -o 'got: *sha256-[A-Za-z0-9+/=]*' | grep -o 'sha256-[A-Za-z0-9+/=]*' | tail -1)

  if [[ -z "$hash" ]]; then
    error "Could not discover git repo hash for $git_url"
    debug "Build output was: $output"
    return 1
  fi

  echo "$hash"
}

get_repo_files_fast() {
  local repo_id="$1"
  local ref="$2"

  local url="https://huggingface.co/api/${repo_id}/tree/${ref}?recursive=true"

  debug "Fetching file tree from $url"
  local response
  local http_code
  local temp_response
  temp_response="$(mktemp)"

  http_code=$(curl -w "%{http_code}" -o "$temp_response" -sL "$url" 2>/dev/null || echo "000")

  if [[ "$http_code" != "200" ]]; then
    if [[ "$http_code" == "404" ]]; then
      error "Repository not found: $repo_id"
    else
      error "Failed to fetch repository information (HTTP $http_code)"
    fi
    rm -f "$temp_response"
    return 1
  fi

  if [[ ! -s "$temp_response" ]]; then
    error "Empty response from API"
    rm -f "$temp_response"
    return 1
  fi

  response=$(cat "$temp_response")
  rm -f "$temp_response"

  if ! echo "$response" | jq empty 2>/dev/null; then
    error "Invalid JSON response from $url"
    return 1
  fi

  echo "$response"
}

create_filter_json_fast() {
  local filters=("$@")

  [[ ${#filters[@]} -eq 0 ]] && {
    echo "null"
    return
  }

  if ((${#filters[@]} % 2 != 0)); then
    error "Filter arguments must come in pairs (flag value)"
    return 1
  fi

  local type="" patterns=()

  for ((i = 0; i < ${#filters[@]}; i += 2)); do
    local flag="${filters[i]}" pattern="${filters[i + 1]}"

    case "$flag" in
      --include)
        [[ -n "$type" && "$type" != "include" ]] && {
          error "Cannot mix filter types"
          return 1
        }
        type="include"
        ;;
      --exclude)
        [[ -n "$type" && "$type" != "exclude" ]] && {
          error "Cannot mix filter types"
          return 1
        }
        type="exclude"
        ;;
      --file)
        [[ -n "$type" && "$type" != "files" ]] && {
          error "Cannot mix filter types"
          return 1
        }
        type="files"
        ;;
      *)
        error "Unknown filter flag: $flag"
        return 1
        ;;
    esac

    if [[ "$flag" == "--file" ]]; then
      pattern=$(printf '%s' "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')
    else
      pattern=$(glob_to_regex "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')
    fi

    patterns+=("\"$pattern\"")
  done

  if [[ ${#patterns[@]} -gt 0 ]]; then
    printf '{ %s = [ %s ]; }\n' "$type" "$(
      IFS=' '
      echo "${patterns[*]}"
    )"
  else
    echo "null"
  fi
}
