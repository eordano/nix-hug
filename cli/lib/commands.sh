# shellcheck shell=bash
# shellcheck source=/dev/null
source "${NIX_HUG_LIB_DIR}/hash.sh"
# shellcheck source=/dev/null
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

prepopulate_lfs_store_paths() {
  local store_path="$1"
  local file_tree="${2:-}"

  if [[ -z "$file_tree" && -f "$store_path/.nix-hug-filetree.json" ]]; then
    file_tree=$(<"$store_path/.nix-hug-filetree.json")
  fi
  [[ -z "$file_tree" ]] && return 0

  local lfs_paths
  lfs_paths=$(echo "$file_tree" | jq -r '.[] | select(has("lfs")) | .path') || return 0
  [[ -z "$lfs_paths" ]] && return 0

  info "Registering LFS files for nix build..."
  while IFS= read -r lfs_path; do
    [[ -z "$lfs_path" ]] && continue
    local lfs_file="$store_path/$lfs_path"
    if [[ -f "$lfs_file" ]]; then
      nix-store --add-fixed sha256 "$lfs_file" >/dev/null 2>&1 || true
    fi
  done <<<"$lfs_paths"
}

write_vendor_file() {
  local dir="$1" filename="$2" label="$3" content="$4"

  mkdir -p "$dir" || {
    error "Could not create vendor directory: $dir"
    return 1
  }

  local dest="${dir%/}/${filename}"
  printf '%s\n' "$content" >"$dest" || {
    error "Could not write $dest"
    return 1
  }

  info "$label: $dest"

  case "$dest" in
    /* | ./* | ../*) echo "$dest" ;;
    *) echo "./$dest" ;;
  esac
}

vendor_file_tree() {
  local dir="$1" bare_repo_path="$2" repo_id="$3" rev="$4"

  local tree
  tree=$(get_repo_files_fast "$repo_id" "$rev") || return 1

  write_vendor_file "$dir" "${bare_repo_path//\//--}.json" "Vendored file tree" "$tree"
}

vendor_git_lfs_files() {
  local dir="$1" org="$2" repo="$3" git_url="$4" rev="$5"

  info "Discovering LFS pointers..."
  local list
  list=$(discover_git_lfs_files "$git_url" "$rev") || {
    error "Could not list LFS files for $git_url"
    return 1
  }

  write_vendor_file "$dir" "git--${org}--${repo}.json" "Vendored LFS list" "$list"
}

parse_repo_args() {
  local help_fn="$1" default_ref="$2"
  shift 2
  _url=""
  _ref="$default_ref"
  _filters=()
  _help_shown=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --ref)
        require_arg "${2:-}" "--ref" || return 1
        _ref="$2"
        shift 2
        ;;
      --include | --exclude | --file)
        require_arg "${2:-}" "$1" || return 1
        _filters+=("$1" "$2")
        shift 2
        ;;
      --help | -h)
        "$help_fn"
        _help_shown=1
        return 0
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        _url="$1"
        shift
        ;;
    esac
  done
}

cmd_fetch() {
  local url=""
  local ref="main"
  local filters=()
  local dry_run=false
  local lfs_url_override=""
  local vendor_dir=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --ref)
        require_arg "${2:-}" "--ref" || return 1
        ref="$2"
        shift 2
        ;;
      --lfs-url)
        require_arg "${2:-}" "--lfs-url" || return 1
        lfs_url_override="$2"
        shift 2
        ;;
      --vendor)
        require_arg "${2:-}" "--vendor" || return 1
        vendor_dir="$2"
        shift 2
        ;;
      --include | --exclude | --file)
        require_arg "${2:-}" "$1" || return 1
        filters+=("$1" "$2")
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --help | -h)
        show_fetch_help
        return 0
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        url="$1"
        shift
        ;;
    esac
  done

  [[ -z "$url" ]] && {
    error "No repository URL specified"
    return 1
  }

  if is_git_url "$url"; then
    cmd_fetch_git "$url" "$ref" "$dry_run" "$lfs_url_override" "$vendor_dir" "${filters[@]}"
    return $?
  fi

  [[ -n "$lfs_url_override" ]] && { warn "--lfs-url is only used with git+ URLs"; }

  resolve_repo "$url" || return 1
  # shellcheck disable=SC2154  # set by resolve_repo
  local repo_id="$_repo_id" repo_type="$_repo_type"
  # shellcheck disable=SC2154
  local bare_repo_path="$_bare_repo_path"
  # shellcheck disable=SC2154
  info "Retrieving information for $_display_name ($ref)..."

  local filter_json
  filter_json=$(create_filter_json_fast "${filters[@]}") || return 1
  [[ "$filter_json" != "null" ]] && info "Using filters: $filter_json"

  info "Resolving revision..."
  local resolved_rev
  resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

  info "Discovering file tree hash..."
  local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev?recursive=true"
  local file_tree_hash
  file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
    error "Failed to discover hash for file tree"
    return 1
  }
  debug "File tree hash: $file_tree_hash"

  local type="${repo_type%s}"

  local tree_path="" git_repo_hash=""
  if [[ -n "$vendor_dir" ]]; then
    tree_path=$(vendor_file_tree "$vendor_dir" "$bare_repo_path" "$repo_id" "$resolved_rev") || return 1
  else
    suggest_vendor
  fi

  info "Discovering git checkout hash (this clones pointers only)..."
  local git_repo_url="https://huggingface.co/${repo_type}/${bare_repo_path}.git"
  [[ "$type" == "model" ]] && git_repo_url="https://huggingface.co/${bare_repo_path}.git"
  git_repo_hash=$(discover_git_repo_hash "$git_repo_url" "$resolved_rev") || {
    error "Failed to discover git checkout hash"
    return 1
  }
  debug "Git repo hash: $git_repo_hash"

  if [[ "$dry_run" == "true" ]]; then
    local files
    files=$(get_repo_files_fast "$repo_id" "$resolved_rev") || return 1

    local filtered_files
    if [[ ${#filters[@]} -gt 0 ]]; then
      filtered_files=$(filter_files_json "$files" "${filters[@]}")
    else
      filtered_files=$(echo "$files" | jq '[.[] | select(.type != "directory")]')
    fi

    local nix_expr
    nix_expr=$(format_fetch_call "" "nix-hug-lib" "$type" "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash" "$tree_path" "$git_repo_hash")

    if [[ ${#filters[@]} -gt 0 ]]; then
      display_filtered_files "$files" "${filters[@]}"
    else
      display_files "$filtered_files" "Files that would be fetched:"
    fi
    echo
    printf '%b\n' "${BOLD}Nix expression:${NC}"
    echo
    echo "$nix_expr"
    return 0
  fi

  info "Building ${type}..."
  build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$type" "$tree_path" "$git_repo_hash" || return 1
}

cmd_fetch_git() {
  local url="$1" ref="$2" dry_run="$3" lfs_url_override="$4" vendor_dir="$5"
  shift 5
  local filters=("$@")

  parse_git_url "$url" || return 1
  # shellcheck disable=SC2154
  local git_url="$_git_url"
  local lfs_url="${lfs_url_override:-$_git_lfs_url}"
  local git_ref="${_git_ref:-$ref}"
  # shellcheck disable=SC2154
  local org="$_git_org" repo="$_git_repo"

  if [[ -z "$lfs_url" ]]; then
    error "Could not derive LFS URL. Use --lfs-url to specify it."
    return 1
  fi

  info "Fetching git repo: $org/$repo ($git_ref)..."

  local filter_json
  filter_json=$(create_filter_json_fast "${filters[@]}") || return 1
  [[ "$filter_json" != "null" ]] && info "Using filters: $filter_json"

  info "Resolving revision..."
  local resolved_rev
  resolved_rev=$(resolve_git_ref "$git_ref" "$git_url") || return 1

  local lfs_path="" lfs_json="" git_repo_hash=""
  if [[ -n "$vendor_dir" ]]; then
    lfs_path=$(vendor_git_lfs_files "$vendor_dir" "$org" "$repo" "$git_url" "$resolved_rev") || return 1
  else
    suggest_vendor
    info "Discovering LFS pointers..."
    lfs_json=$(discover_git_lfs_files "$git_url" "$resolved_rev") || {
      error "Failed to discover LFS pointers"
      return 1
    }
  fi

  info "Discovering git checkout hash (this clones pointers only)..."
  git_repo_hash=$(discover_git_repo_hash "$git_url" "$resolved_rev") || {
    error "Failed to discover git checkout hash"
    return 1
  }

  if [[ "$dry_run" == "true" ]]; then
    local nix_expr
    nix_expr=$(format_git_fetch_call "" "nix-hug-lib" "$git_url" "$resolved_rev" "$lfs_url" "$filter_json" "$lfs_path" "$git_repo_hash" "$lfs_json")
    printf '%b\n' "${BOLD}Nix expression:${NC}"
    echo
    echo "$nix_expr"
    return 0
  fi

  local store_path

  info "Building..."
  local expr
  expr=$(generate_git_fetch_expr "$git_url" "$resolved_rev" "$lfs_url" "$filter_json" "$lfs_path" "$git_repo_hash" "$lfs_json")

  local build_output
  build_output=$(build_with_expr "$expr" "Build") || {
    error "Failed to build git repo"
    return 1
  }

  store_path=$(extract_store_path "$build_output") || {
    error "Could not find store path in build output"
    debug "Build output was: $build_output"
    return 1
  }

  ok "Downloaded to: $store_path"
  generate_git_usage_example "$git_url" "$resolved_rev" "$lfs_url" "$filter_json" "$lfs_path" "$git_repo_hash" "$lfs_json"
}

cmd_ls() {
  parse_repo_args show_ls_help main "$@" || return 1
  [[ -n "$_help_shown" ]] && return 0
  local url="$_url" ref="$_ref"
  local filters=("${_filters[@]}")

  [[ -z "$url" ]] && {
    error "No repository URL specified"
    return 1
  }

  resolve_repo "$url" || return 1
  local files
  files=$(get_repo_files_fast "$_repo_id" "$ref") || return 1

  if [[ ${#filters[@]} -gt 0 ]]; then
    display_filtered_files "$files" "${filters[@]}"
  else
    display_files "$files" "Files in $_display_name:"
  fi
}

build_and_report() {
  local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"
  local type="${5:-model}"
  local tree_path="${6:-}" git_repo_hash="${7:-}"
  local label="${type^}"

  local bare_repo_path
  bare_repo_path=$(get_bare_repo_path "$repo_id")

  local store_path

  local expr
  expr=$(generate_fetch_expr "$type" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$tree_path" "$git_repo_hash")

  local build_output
  build_output=$(build_with_expr "$expr" "Build") || {
    error "Failed to build ${type}"
    return 1
  }

  store_path=$(extract_store_path "$build_output") || {
    error "Could not find store path in build output"
    debug "Build output was: $build_output"
    return 1
  }

  ok "$label downloaded to: $store_path"
  generate_usage_example "$type" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$tree_path" "$git_repo_hash"
}

cmd_export() {
  parse_repo_args show_export_help main "$@" || return 1
  [[ -n "$_help_shown" ]] && return 0
  local url="$_url" ref="$_ref"
  local filters=("${_filters[@]}")

  [[ -z "$url" ]] && {
    error "No repository URL specified"
    show_export_help
    return 1
  }

  if [[ ${#filters[@]} -eq 0 && "$ref" == "main" ]] && parse_bare_repo "$url" 2>/dev/null; then
    local store_path=""
    # shellcheck disable=SC2154  # set by parse_bare_repo
    if store_path=$(find_store_path_by_repo "$_org" "$_repo"); then
      local basename="${store_path##*/}"
      local name="${basename#*-}"
      local rev="${name: -40}"
      local type_label="model"
      [[ "$name" == hf-dataset-* ]] && type_label="dataset"

      info "Found in Nix store: $store_path"
      export_to_hf_cache "$store_path" "$_org/$_repo" "$type_label" "$rev" || return 1
      ok "Store path: $store_path"
      return 0
    fi
  fi

  resolve_repo "$url" || return 1
  local repo_id="$_repo_id" bare_repo_path="$_bare_repo_path"
  info "Exporting $_display_name ($ref)..."

  local filter_json
  filter_json=$(create_filter_json_fast "${filters[@]}") || return 1

  local resolved_rev
  resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

  local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev?recursive=true"
  local file_tree_hash
  file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
    error "Failed to discover hash for file tree"
    return 1
  }

  if [[ "$_repo_type" == "spaces" ]]; then
    error "export handles models and datasets; the HF cache has no layout for spaces"
    return 1
  fi
  local type_label="${_repo_type%s}"

  local store_path=""
  parse_bare_repo "$bare_repo_path" || return 1
  local _check_store_name="hf-${type_label}-${_org}-${_repo}-${resolved_rev}"
  if store_path=$(find_valid_store_path "$_check_store_name"); then
    debug "Found existing store path: $store_path"
  fi

  if [[ -z "$store_path" ]]; then
    info "Discovering git checkout hash (this clones pointers only)..."
    local git_repo_url="https://huggingface.co/${_repo_type}/${bare_repo_path}.git"
    [[ "$type_label" == "model" ]] && git_repo_url="https://huggingface.co/${bare_repo_path}.git"
    local git_repo_hash
    git_repo_hash=$(discover_git_repo_hash "$git_repo_url" "$resolved_rev") || {
      error "Failed to discover git checkout hash"
      return 1
    }

    local expr
    expr=$(generate_fetch_expr "$type_label" "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash" "" "$git_repo_hash")

    local build_output
    build_output=$(build_with_expr "$expr" "Build") || {
      error "Failed to build $type_label"
      return 1
    }

    if ! store_path=$(extract_store_path "$build_output"); then
      error "Could not find store path in build output"
      return 1
    fi
  fi

  export_to_hf_cache "$store_path" "$bare_repo_path" "$type_label" "$resolved_rev" || return 1
  ok "Store path: $store_path"
}

export_to_hf_cache() {
  local store_path="$1"
  local bare_repo_path="$2"
  local type_label="$3"
  local resolved_rev="$4"

  local hf_cache
  hf_cache=$(resolve_hf_cache_dir)

  parse_bare_repo "$bare_repo_path" || return 1
  local org="$_org" repo="$_repo"

  local filetree="$store_path/.nix-hug-filetree.json"
  if [[ ! -f "$filetree" ]]; then
    error "Store path missing .nix-hug-filetree.json: $store_path"
    return 1
  fi

  local snapshot_dir repo_dir
  snapshot_dir=$(init_hf_cache_snapshot "$hf_cache" "$type_label" "$org" "$repo" "$resolved_rev")
  repo_dir="$(dirname "$(dirname "$snapshot_dir")")"
  mkdir -p "$repo_dir/blobs"

  local entries
  entries=$(jq -r '.[] | select(.type != "directory") | select(.path | startswith(".nix-hug-") | not)
        | [.path, (if .lfs then .lfs.oid else .oid end)] | @tsv' "$filetree")

  while IFS=$'\t' read -r fpath blob_hash; do
    [[ -z "$fpath" ]] && continue

    if [[ ! -f "$repo_dir/blobs/$blob_hash" ]]; then
      cp -L "$store_path/$fpath" "$repo_dir/blobs/$blob_hash"
    fi

    local snap_file="$snapshot_dir/$fpath"
    mkdir -p "$(dirname "$snap_file")"

    local depth rel_prefix="../.."
    depth=$(echo "$fpath" | tr -cd '/' | wc -c)
    local i
    for ((i = 0; i < depth; i++)); do
      rel_prefix="../$rel_prefix"
    done

    ln -sf "$rel_prefix/blobs/$blob_hash" "$snap_file"
  done <<<"$entries"

  ok "Exported to HF cache: $repo_dir"
  info "Snapshot: $snapshot_dir"
}

cmd_import() {
  parse_repo_args show_import_help "" "$@" || return 1
  [[ -n "$_help_shown" ]] && return 0
  local url="$_url" ref="$_ref"
  local filters=("${_filters[@]}")

  import_from_hf_cache "$url" "$ref" "${filters[@]}"
}

import_from_hf_cache() {
  local repo_id="${1:-}"
  local ref="${2:-}"
  shift 2 || true
  local filters=()
  [[ $# -gt 0 ]] && filters=("$@")

  if [[ -z "$repo_id" ]]; then
    error "No repository URL specified"
    show_import_help
    return 1
  fi

  parse_bare_repo "$repo_id" || return 1
  # shellcheck disable=SC2154  # set by parse_bare_repo
  local org="$_org" repo="$_repo" type_hint="$_type_hint"

  local hf_cache
  hf_cache=$(resolve_hf_cache_dir)

  local cache_repo_dir="" detected_type="" candidate
  for candidate in ${type_hint:+"$type_hint"} models datasets; do
    if [[ -d "$hf_cache/${candidate}--${org}--${repo}" ]]; then
      cache_repo_dir="$hf_cache/${candidate}--${org}--${repo}"
      detected_type="${candidate%s}"
      break
    fi
  done

  if [[ -z "$cache_repo_dir" ]]; then
    error "Repository $org/$repo not found in HF cache at $hf_cache"
    error "Expected: $hf_cache/models--${org}--${repo} or $hf_cache/datasets--${org}--${repo}"
    return 1
  fi

  debug "Found $detected_type in cache: $cache_repo_dir"

  local resolved_rev=""
  if [[ -n "$ref" ]]; then
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      resolved_rev="$ref"
    elif [[ -f "$cache_repo_dir/refs/$ref" ]]; then
      resolved_rev=$(cat "$cache_repo_dir/refs/$ref")
    else
      error "Ref '$ref' not found in $cache_repo_dir/refs/"
      local available
      available=$(for f in "$cache_repo_dir/refs/"*; do [[ -f "$f" ]] && printf '%s, ' "${f##*/}"; done)
      [[ -n "$available" ]] && error "Available refs: ${available%, }"
      return 1
    fi
  else
    if [[ -f "$cache_repo_dir/refs/main" ]]; then
      resolved_rev=$(cat "$cache_repo_dir/refs/main")
    else
      local snapshots=()
      for s in "$cache_repo_dir/snapshots/"*/; do
        local _s="${s%/}"
        [[ -d "$s" ]] && snapshots+=("${_s##*/}")
      done
      if [[ ${#snapshots[@]} -eq 1 ]]; then
        resolved_rev="${snapshots[0]}"
      elif [[ ${#snapshots[@]} -eq 0 ]]; then
        error "No snapshots found in $cache_repo_dir/snapshots/"
        return 1
      else
        error "No 'main' ref found and multiple snapshots exist. Use --ref to specify."
        error "Available revisions: ${snapshots[*]}"
        return 1
      fi
    fi
  fi

  local snapshot_dir="$cache_repo_dir/snapshots/$resolved_rev"
  if [[ ! -d "$snapshot_dir" ]]; then
    error "Snapshot directory not found: $snapshot_dir"
    return 1
  fi

  local store_name="hf-${detected_type}-${org}-${repo}-${resolved_rev}"

  local filter_json="null"
  if [[ ${#filters[@]} -gt 0 ]]; then
    filter_json=$(create_filter_json_fast "${filters[@]}") || filter_json="null"
  fi

  local api_file_tree="" file_tree_hash=""
  info "Fetching file tree..."
  api_file_tree=$(get_repo_files_fast "${detected_type}s/${org}/${repo}" "$resolved_rev" 2>/dev/null) || true
  if [[ -n "$api_file_tree" ]]; then
    file_tree_hash=$(printf '%s' "$api_file_tree" |
      nix --extra-experimental-features 'nix-command' hash file \
        --type sha256 --sri --mode flat /dev/stdin 2>/dev/null) || file_tree_hash=""
  fi

  local store_path
  if store_path=$(find_valid_store_path "$store_name"); then

    ok "Already in Nix store: $store_path"
    if [[ -n "$file_tree_hash" ]]; then
      generate_usage_example "$detected_type" "$org/$repo" "$resolved_rev" "$filter_json" "$file_tree_hash"
    else
      info "Fetching hashes..."
      cmd_fetch "$org/$repo" --ref "$resolved_rev" "${filters[@]}" ||
        warn "revision $resolved_rev is not on the Hub; imported without a fetch expression"
    fi
    return 0
  fi

  info "Importing $org/$repo ($detected_type) rev ${resolved_rev:0:12}..."

  local tmp_dir
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nix-hug-from-cache.XXXXXX")

  if [[ ${#filters[@]} -gt 0 ]]; then
    local filter_type="" patterns=()
    for ((i = 0; i < ${#filters[@]}; i += 2)); do
      local kind="${filters[i]#--}"
      if [[ -n "$filter_type" && "$filter_type" != "$kind" ]]; then
        error "Cannot mix --include, --exclude, and --file filters"
        rm -rf "$tmp_dir"
        return 1
      fi
      filter_type="$kind"
      patterns+=("${filters[i + 1]}")
    done

    local copy_failures=0 copied=0
    while IFS= read -r -d '' file; do
      local relpath="${file#"$snapshot_dir"/}"
      local hit=false pat
      for pat in "${patterns[@]}"; do
        if [[ "$filter_type" == "file" ]]; then
          [[ "$relpath" == "$pat" ]] && {
            hit=true
            break
          }
        else
          # shellcheck disable=SC2254,SC2053  # intentional glob matching
          [[ "$relpath" == $pat || "${relpath##*/}" == $pat ]] && {
            hit=true
            break
          }
        fi
      done
      local matched="$hit"
      [[ "$filter_type" == "exclude" ]] && { [[ "$hit" == "true" ]] && matched=false || matched=true; }
      if [[ "$matched" == "true" ]]; then
        local dst="$tmp_dir/$relpath"
        mkdir -p "$(dirname "$dst")"
        if cp -L "$file" "$dst" 2>/dev/null; then
          copied=$((copied + 1))
        else
          warn "Could not copy $relpath (broken symlink or missing blob)"
          copy_failures=$((copy_failures + 1))
        fi
      fi
    done < <(find -L "$snapshot_dir" -type f -print0 2>/dev/null)

    if [[ $copied -eq 0 ]]; then
      error "No files to import (filters may have excluded everything, or all symlinks broken)"
      rm -rf "$tmp_dir"
      return 1
    fi
    [[ $copy_failures -gt 0 ]] && warn "$copy_failures file(s) could not be copied"
    info "Prepared $copied files..."
  else
    info "Copying files..."
    cp -rL "$snapshot_dir/." "$tmp_dir/"
  fi

  printf '{"id":"%s","sha":"%s"}' "$org/$repo" "$resolved_rev" >"$tmp_dir/.nix-hug-repoinfo.json"

  if [[ -n "$api_file_tree" ]]; then
    printf '%s' "$api_file_tree" >"$tmp_dir/.nix-hug-filetree.json"
  fi

  info "Adding to Nix store..."

  local store_path
  store_path=$(nix --extra-experimental-features 'nix-command' store add \
    --name "$store_name" "$tmp_dir") || true

  rm -rf "$tmp_dir"

  if [[ -z "$store_path" ]]; then
    error "Failed to add to Nix store"
    return 1
  fi

  prepopulate_lfs_store_paths "$store_path" "$api_file_tree"

  ok "Added to Nix store: $store_path"
  if [[ -n "$file_tree_hash" ]]; then
    generate_usage_example "$detected_type" "$org/$repo" "$resolved_rev" "$filter_json" "$file_tree_hash"
  else
    info "Fetching hashes..."
    cmd_fetch "$org/$repo" --ref "$resolved_rev" "${filters[@]}" ||
      warn "revision $resolved_rev is not on the Hub; imported without a fetch expression"
  fi
}

cmd_scan() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help | -h)
        show_scan_help
        return 0
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        error "Unexpected argument: $1"
        return 1
        ;;
    esac
  done

  local hf_cache
  hf_cache=$(resolve_hf_cache_dir)

  if [[ ! -d "$hf_cache" ]]; then
    info "HuggingFace cache not found at: $hf_cache"
    info "Models are typically cached in \$HF_HUB_CACHE or \$XDG_CACHE_HOME/huggingface/hub/"
    return 0
  fi

  local found=false

  info "Scanning $hf_cache"

  local -a row_repo=() row_type=() row_rev=() row_size=() row_files=() row_store=() row_refs=()
  local w_repo=10 w_type=4 w_rev=3 w_size=4 w_files=5 w_store=8

  local dir
  for dir in "$hf_cache"/{models,datasets}--*--*/; do
    [[ -d "$dir" ]] || continue

    local dirname="${dir%/}"
    dirname="${dirname##*/}"

    local type_prefix remainder org repo
    if [[ "$dirname" =~ ^(models|datasets)--(.+) ]]; then
      type_prefix="${BASH_REMATCH[1]}"
      remainder="${BASH_REMATCH[2]}"
    else
      debug "Skipping unrecognized directory: $dirname"
      continue
    fi

    if [[ "$remainder" =~ ^([^-]+(-[^-]+)*)--(.+)$ ]]; then
      org="${BASH_REMATCH[1]}"
      repo="${BASH_REMATCH[3]}"
    else
      debug "Could not parse org/repo from: $remainder"
      continue
    fi

    local type="${type_prefix%s}"
    local repo_id="$org/$repo"

    unset ref_map 2>/dev/null
    declare -A ref_map=()
    if [[ -d "$dir/refs" ]]; then
      local ref_file
      for ref_file in "$dir/refs/"*; do
        [[ -f "$ref_file" ]] || continue
        local ref_name ref_hash
        ref_name="${ref_file##*/}"
        ref_hash=$(<"$ref_file") || continue
        ref_map["$ref_hash"]+="${ref_name} "
      done
    fi

    if [[ ! -d "$dir/snapshots" ]]; then
      debug "No snapshots directory in: $dirname"
      continue
    fi

    local snap_dir
    for snap_dir in "$dir/snapshots/"*/; do
      [[ -d "$snap_dir" ]] || continue

      local rev="${snap_dir%/}"
      rev="${rev##*/}"

      if [[ ! "$rev" =~ ^[0-9a-f]{7,}$ ]]; then
        debug "Skipping non-hash snapshot: $rev"
        continue
      fi

      found=true

      local file_count total_bytes
      read -r file_count total_bytes < <(
        find -L "$snap_dir" -type f -printf '%s\n' 2>/dev/null |
          awk '{s+=$1; c++} END {print c+0, s+0}'
      )

      local ref_labels="" ref_name
      for ref_name in ${ref_map[$rev]:-}; do
        ref_labels+="${ref_labels:+, }\`${ref_name}\`"
      done

      local short_rev="${rev:0:12}"
      [[ ${#rev} -gt 12 ]] && short_rev="${short_rev}..."

      local in_store="NO"
      store_has_path "hf-${type}-${org}-${repo}-${rev}" && in_store="YES"

      row_repo+=("$repo_id")
      row_type+=("$type")
      row_rev+=("$short_rev")
      row_size+=("$(format_size "$total_bytes")")
      row_files+=("$file_count")
      row_store+=("$in_store")
      row_refs+=("$ref_labels")

      ((${#repo_id} > w_repo)) && w_repo=${#repo_id}
      ((${#type} > w_type)) && w_type=${#type}
      ((${#short_rev} > w_rev)) && w_rev=${#short_rev}
      ((${#row_size[-1]} > w_size)) && w_size=${#row_size[-1]}
      ((${#file_count} > w_files)) && w_files=${#file_count}
    done

    unset ref_map 2>/dev/null
  done

  if [[ "$found" != "true" ]]; then
    info "No models or datasets found in $hf_cache"
    return 0
  fi

  echo
  local fmt='%s%-*s  %-*s  %-*s  %*s  %*s  %*s  %s%s\n'
  # shellcheck disable=SC2059  # fmt is ours, and the widths are positional
  printf "$fmt" "$BOLD" \
    "$w_repo" "REPOSITORY" "$w_type" "TYPE" "$w_rev" "REV" \
    "$w_size" "SIZE" "$w_files" "FILES" "$w_store" "IN STORE" "REFS" "$NC"

  local i
  for i in "${!row_repo[@]}"; do
    # shellcheck disable=SC2059
    printf "$fmt" "" \
      "$w_repo" "${row_repo[i]}" "$w_type" "${row_type[i]}" "$w_rev" "${row_rev[i]}" \
      "$w_size" "${row_size[i]}" "$w_files" "${row_files[i]}" \
      "$w_store" "${row_store[i]}" "${row_refs[i]}" ""
  done
}

cmd_import_all() {
  local yes=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -y | --yes)
        yes=true
        shift
        ;;
      --help | -h)
        show_import_all_help
        return 0
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        error "Unexpected argument: $1"
        return 1
        ;;
    esac
  done

  local hf_cache
  hf_cache=$(resolve_hf_cache_dir)

  if [[ ! -d "$hf_cache" ]]; then
    info "HuggingFace cache not found at: $hf_cache"
    return 0
  fi

  local entries=()
  local types=() repo_ids=() revs=()

  for dir in "$hf_cache"/{models,datasets}--*--*/; do
    [[ -d "$dir" ]] || continue

    local dirname="${dir%/}"
    dirname="${dirname##*/}"

    local type_prefix remainder org repo
    if [[ "$dirname" =~ ^(models|datasets)--(.+) ]]; then
      type_prefix="${BASH_REMATCH[1]}"
      remainder="${BASH_REMATCH[2]}"
    else
      continue
    fi

    if [[ "$remainder" =~ ^([^-]+(-[^-]+)*)--(.+)$ ]]; then
      org="${BASH_REMATCH[1]}"
      repo="${BASH_REMATCH[3]}"
    else
      continue
    fi

    local type="${type_prefix%s}"

    [[ -d "$dir/snapshots" ]] || continue

    for snap_dir in "$dir/snapshots/"*/; do
      [[ -d "$snap_dir" ]] || continue
      local rev="${snap_dir%/}"
      rev="${rev##*/}"
      [[ "$rev" =~ ^[0-9a-f]{7,}$ ]] || continue

      if store_has_path "hf-${type}-${org}-${repo}-${rev}"; then
        continue
      fi

      types+=("$type")
      repo_ids+=("$org/$repo")
      revs+=("$rev")
    done
  done

  if [[ ${#repo_ids[@]} -eq 0 ]]; then
    info "Nothing to import -- all cached repos are already in the Nix store."
    return 0
  fi

  printf '%b\n' "${BOLD}Repositories to import:${NC}"
  echo
  for ((i = 0; i < ${#repo_ids[@]}; i++)); do
    printf "  %-9s %-42s %s\n" "${types[i]}" "${repo_ids[i]}" "${revs[i]:0:12}..."
  done
  echo
  info "${#repo_ids[@]} repository snapshot(s) will be imported."

  if [[ "$yes" != "true" ]]; then
    echo
    read -rp "Proceed? [y/N] " answer
    case "$answer" in
      [yY] | [yY][eE][sS]) ;;
      *)
        info "Aborted."
        return 0
        ;;
    esac
  fi

  local imported=0 failed=0
  for ((i = 0; i < ${#repo_ids[@]}; i++)); do
    echo
    if import_from_hf_cache "${repo_ids[i]}" "${revs[i]}"; then
      imported=$((imported + 1))
    else
      warn "Failed to import ${repo_ids[i]} rev ${revs[i]:0:12}"
      failed=$((failed + 1))
    fi
  done

  echo
  ok "Done: $imported imported, $failed failed."
}
