#compdef nix-hug

_nix_hug_cached_repos() {
    local hf_cache="${HF_HUB_CACHE:-${HF_HOME:+$HF_HOME/hub}}"
    hf_cache="${hf_cache:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub}"
    [[ -d "$hf_cache" ]] || return

    local -a repos
    local dir
    for dir in "$hf_cache"/{models,datasets}--*--*/; do
        [[ -d "$dir" ]] || continue
        local name="${dir%/}"
        name="${name##*/}"
        local type="${name%%--*}"
        name="${name#${type}--}"
        repos+=("${name/--//}:$type")
    done
    _describe -t repos 'cached repository' repos
}

_nix_hug() {
    local -a commands global_opts repo_opts
    commands=(
        'fetch:Fetch a Hugging Face repo into the Nix store'
        'ls:List files in a Hugging Face repo'
        'export:Export model/dataset from Nix store to HF cache'
        'import:Import model/dataset from HF cache to Nix store'
        'import-all:Import all cached models/datasets into Nix store'
        'scan:Scan Hugging Face cache directory'
    )
    global_opts=(
        '--debug[Enable debug output]'
        '--help[Show help]'
        '--version[Show version]'
    )
    repo_opts=(
        '--ref[Git ref]:ref:'
        '--include[Include filter pattern]:pattern:'
        '--exclude[Exclude filter pattern]:pattern:'
        '--file[Filter file]:file:_files'
        '--help[Show help]'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'nix-hug command' commands
        _arguments -s $global_opts
        return
    fi

    case "$words[2]" in
        fetch) _arguments -s $repo_opts \
            '--lfs-url[LFS download URL prefix, for git+ URLs]:url:' \
            '--vendor[Vendor the file tree into DIR for offline evaluation]:dir:_files -/' \
            '--dry-run[Show what would be fetched]' ;;
        ls | export) _arguments -s $repo_opts ;;
        import) _arguments -s $repo_opts '1:repository:_nix_hug_cached_repos' ;;
        import-all) _arguments -s {-y,--yes}'[Skip confirmation prompt]' '--help[Show help]' ;;
        scan) _arguments -s '--help[Show help]' ;;
    esac
}

_nix_hug "$@"
