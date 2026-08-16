# nix-hug

[![CI](https://github.com/eordano/nix-hug/actions/workflows/ci.yml/badge.svg)](https://github.com/eordano/nix-hug/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/eordano/nix-hug?label=release&color=green)](https://github.com/eordano/nix-hug/releases/latest)
[![Flake](https://img.shields.io/badge/Nix-flake-5277C3?logo=nixos&logoColor=white)](flake.nix)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

Declarative Hugging Face model and dataset management for Nix. `nix-hug` pins
models to exact revisions, fetches only the files you need, builds
offline-compatible HuggingFace Hub caches, and supports importing from and
exporting to the local HuggingFace cache.

The CLI is used to download models into the nix store:

```bash
$ nix run github:eordano/nix-hug -- fetch MiniMaxAI/MiniMax-M2.5
nix-hug-lib.fetchModel {
  url = "MiniMaxAI/MiniMax-M2.5";
  rev = "abc123...";
  fileTreeHash = "sha256-...";
  gitRepoHash = "sha256-...";
};
```

The output can then be used in nix:

```nix
# Smoke test: an app that just loads the model in python
let
  minimax = nix-hug-lib.fetchModel {
    url = "MiniMaxAI/MiniMax-M2.5";
    rev = "abc123...";
    fileTreeHash = "sha256-...";
    gitRepoHash = "sha256-...";
  };
  cache = nix-hug-lib.buildCache {
    models = [ minimax ];
  };
  python = pkgs.python3.withPackages (p: [ p.transformers p.torch ]);
in
  pkgs.writeShellApplication {
    name = "say-minimax-inefficiently";
    runtimeInputs = [ python ];
    text = ''
      export HF_HUB_CACHE=${cache}
      export TRANSFORMERS_OFFLINE=1
      python -c "
        from transformers import AutoModelForCausalLM
        model = AutoModelForCausalLM.from_pretrained('MiniMaxAI/MiniMax-M2.5')
        print(model)
      "
    '';
  }
```

## Table of Contents

- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Installation](#installation)
- [CLI Reference](#cli-reference)
  - [fetch](#fetch)
  - [ls](#ls)
  - [export](#export)
  - [import](#import)
  - [import-all](#import-all)
  - [scan](#scan)
- [Nix Library](#nix-library)
  - [fetchModel / fetchDataset / fetchSpace](#fetchmodel--fetchdataset--fetchspace)
  - [What each combination costs](#what-each-combination-costs)
  - [Upgrading to 6.0 from 5.1](#upgrading-to-60-from-51)
  - [buildCache](#buildcache)
- [URL Formats](#url-formats)
- [Library interface](#library-interface)
- [Development](#development)
- [License](#license)

## Quick Start

Add nix-hug to your flake inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nix-hug.url = "github:eordano/nix-hug";
  };
}
```

Use the CLI to fetch a model. It resolves the revision, computes hashes, and
prints a Nix expression you can paste into your configuration:

```console
$ nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'
```

Use the output in your flake to build an offline HuggingFace Hub cache:

```nix
let
  nix-hug-lib = nix-hug.lib.${system};

  mistral = nix-hug-lib.fetchModel {
    url = "mistralai/Mistral-7B-Instruct-v0.3";
    rev = "abc123...";  # pinned commit hash from CLI output
    filters = { include = [ ".*\\.safetensors" ]; };
    fileTreeHash = "sha256-...";
    gitRepoHash = "sha256-...";
  };

  cache = nix-hug-lib.buildCache {
    models = [ mistral ];
  };
in
  pkgs.mkShell {
    HF_HUB_CACHE = cache;
    TRANSFORMERS_OFFLINE = "1";
  }
```

Running Python within this shell will find the model without network
access (the `transformers` lib reads the env variable `HF_HUB_CACHE`):

```python
from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained("mistralai/Mistral-7B-Instruct-v0.3")
```

## How It Works

`nix-hug` has two parts: a bash-based CLI, and a nix library. The CLI's `fetch`
subcommand resolves the git ref to a commit hash via the Hugging Face API. It
then fetches the repository's file tree metadata and computes a SHA256 hash of
how the directory structure for consumption by HuggingFace libraries will look
like. The output of the CLI is a Nix expression that pins that "`fileTreeHash`"
and stores the git ref.

When consuming it, the nix-based `lib` evaluates that expression, and executes
the same steps that the bash-based CLI does: `fetchgit` clones the Hugging Face
repository at the pinned revision and `gitRepoHash`, at build time rather than
evaluation time. This retrieves all small files (configs, tokenizer data, etc.)
but only LFS pointer files for large weights. For each LFS file then `fetchurl`
downloads it from HuggingFace's CDN using the LFS SHA256 OID as the content
hash. Filters can be provided to selectively download some of these large
files, in case the repository contains a lot of model files that you don't need
(for example, one might want only one particular large ".safetensors" file from
a repository that has also ONNX files, or many quantizations together in the
same repo). A derivation assembles the result: the git checkout with real model
files replacing the LFS pointers.

`buildCache` takes fetched models and datasets and arranges them into the
directory layout that HuggingFace Hub's Python libraries expect:

```txt
models--org--repo/
  refs/
    main            # contains the pinned commit hash
  snapshots/
    <rev>/          # the actual model files
```

Set `HF_HUB_CACHE` to this store path and any library that reads from the Hub
cache (`transformers`, `diffusers`, `sentence-transformers`) will find the
model without making network requests. Please note that `datasets` is known to
cause problems sometimes (contributions welcome).

Everything is content-addressed. The same inputs produce the same store paths.
Models can be shared across machines, cached in CI, and pinned in lockfiles
the same way as any other Nix dependency.

### HuggingFace cache integration

`nix-collect-garbage` removes store paths not referenced by a GC root. For
large models, re-downloading after collection is expensive. The `export`
command copies a model from the Nix store into the local HuggingFace cache
directory, and `import` copies it back. This uses the same directory layout
that `transformers`, `diffusers`, and other HF libraries read from. The cache
location is determined by `$HF_HUB_CACHE`, `$HF_HOME/hub`, or defaults to
`$XDG_CACHE_HOME/huggingface/hub/`.

## Installation

### As a flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nix-hug.url = "github:eordano/nix-hug";
  };

  outputs = { nixpkgs, nix-hug, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nix-hug-lib = nix-hug.lib.${system};

      my-model = nix-hug-lib.fetchModel {
        url = "stas/tiny-random-llama-2";
        rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
        fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
        gitRepoHash = "sha256-SrdDsqK7grmWiB0nH4q78jUyGTta3ZX8UXuZCEhPwOw=";
      };

      model-cache = nix-hug-lib.buildCache {
        models = [ my-model ];
      };
    in {
      packages.${system} = {
        inherit my-model model-cache;
        default = nix-hug.packages.${system}.default;
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ nix-hug.packages.${system}.default ];
      };
    };
}
```

### Run directly

```console
$ nix run github:eordano/nix-hug -- fetch mistralai/Mistral-7B-Instruct-v0.3
```

## CLI Reference

Global options:

- `--debug`: enable verbose logging
- `--version`: print version
- `--help`: show help

### `fetch`

Downloads a model or dataset from Hugging Face and prints a Nix expression
with pinned revision and hashes.

```console
$ nix-hug fetch <url> [options]
```

Options:

- `--ref REF`: git reference to resolve (default: `main`)
- `--include PATTERN`: include files matching a glob pattern
- `--exclude PATTERN`: exclude files matching a glob pattern
- `--file FILENAME`: include a specific file by name
- `--lfs-url URL`: LFS download URL prefix, for `git+` URLs whose LFS server
  differs from the git remote
- `--vendor DIR`: write the file tree, or the LFS pointer list for a `git+`
  URL, to `DIR` and emit an expression that evaluates without network access
  (see [Offline evaluation](#offline-evaluation))
- `--dry-run`: show what would be fetched without downloading

```console
# Fetch only safetensors weights
$ nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'

# Fetch a dataset
$ nix-hug fetch rajpurkar/squad --include '*.json'

# Fetch a single config file
$ nix-hug fetch google-bert/bert-base-uncased --file config.json

# Emit an expression that needs no network at evaluation time
$ nix-hug fetch openai-community/gpt2 --vendor ./trees
```

The CLI auto-detects whether a repository is a model or dataset by querying the
Hugging Face API.

### `ls`

Lists files in a repository without downloading anything. Accepts the same
filter options as `fetch`.

```console
$ nix-hug ls mistralai/Mistral-7B-Instruct-v0.3
$ nix-hug ls stanfordnlp/imdb --include '*.parquet'
```

### `export`

Fetches a model or dataset and copies it into the local HuggingFace cache
directory. This makes the model available to `transformers`, `diffusers`, and
other HF libraries, and preserves it outside the Nix store (surviving garbage
collection).

The cache location is determined by `$HF_HUB_CACHE`, `$HF_HOME/hub`, or
defaults to `$XDG_CACHE_HOME/huggingface/hub/`.

Accepts the same filter options as `fetch`.

```console
$ nix-hug export openai-community/gpt2
$ nix-hug export openai-community/gpt2 --include '*.safetensors'
```

### `import`

Imports a model or dataset from the local HuggingFace cache into the Nix store.
If you already have models downloaded by `transformers`, `diffusers`, or
`huggingface-cli`, this avoids re-downloading files that are already on disk.
Use `nix-hug scan` to see what's available before importing.

The imported store path has the same layout as `nix-hug fetch`, so the output
can be used with `buildCache` and `nix build`.

The cache location is determined by `$HF_HUB_CACHE`, `$HF_HOME/hub`, or
defaults to `$XDG_CACHE_HOME/huggingface/hub/`.

```console
$ nix-hug import <url> [options]
```

Options:

- `--ref REF`: match a specific revision
- `--include PATTERN`: include files matching a glob pattern
- `--exclude PATTERN`: exclude files matching a glob pattern
- `--file FILENAME`: include a specific file by name

```console
$ nix-hug import openai-community/gpt2
$ nix-hug import openai-community/gpt2 --include '*.safetensors'
```

### `import-all`

Imports every model and dataset found in the local HuggingFace cache into
the Nix store -- `import` for the whole cache in one pass.

```console
$ nix-hug import-all          # confirms before importing
$ nix-hug import-all --yes    # no confirmation prompt
```

### `scan`

Lists all models and datasets in the local HuggingFace cache. Useful for
discovering what's available before running `import`.

The cache location is determined by `$HF_HUB_CACHE`, `$HF_HOME/hub`, or
defaults to `$XDG_CACHE_HOME/huggingface/hub/`.

```console
$ nix-hug scan
```

Shows each cached repository with its type, revision, size, file count,
whether it's already in the Nix store, and any ref labels.

## Nix Library

The library is available as `nix-hug.lib.${system}` from the flake output.

### fetchModel / fetchDataset / fetchSpace

One function per Hub namespace. All three take the same arguments and return a
derivation.

```nix
nix-hug-lib.fetchModel {
  repoId = "stas/tiny-random-llama-2";
  rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
  fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
  gitRepoHash = "sha256-SrdDsqK7grmWiB0nH4q78jUyGTta3ZX8UXuZCEhPwOw=";
}

nix-hug-lib.fetchDataset {
  repoId = "rajpurkar/squad";
  rev = "abc123...";
  filters = file: pkgs.lib.hasSuffix ".json" file.path;
  fileTreeHash = "sha256-...";
  gitRepoHash = "sha256-...";
}

nix-hug-lib.fetchSpace {
  repoId = "julien-c/hello-world";
  rev = "4884451c8783f0eb1416903f79b643c756aaaf9a";
  fileTreeHash = "sha256-byTXe33x1uGbldDjiZOnRoE1vyh7u31YnlqCjpxbI3I=";
  gitRepoHash = "sha256-BSuQDGU/jdMkfBmEZV9Sn523N27+0OzuxRBdEjfvdXQ=";
}
```

Parameters:

- `repoId` (required): repository identifier (see [URL Formats](#url-formats)).
  Also accepted as `url`.
- `rev`: git commit hash (40 characters). Exactly one of `rev` or `tag` is
  required.
- `tag`: a named ref resolved through the API instead of a commit hash;
  requires `repoInfoHash`, whose response changes on its own. Prefer `rev`.
- `fileTreeHash` (required): SHA256 hash of the HF API file tree response
- `filters` (optional): predicate `file: bool`, or a filter object with
  `include`, `exclude`, or `files`
- `fileTree` (optional): pre-fetched tree endpoint response, as a Nix value. It
  makes evaluation need no network at all -- see [Offline
  evaluation](#offline-evaluation)
- `gitRepoHash` (required): hash for the non-LFS git checkout, which is a
  fixed-output derivation. `nix-hug fetch` always emits it
- `repoType` (optional): `"model"`, `"dataset"` or `"space"`, matching the
  nixpkgs vocabulary. Each function already presets it, so you rarely pass it.
- `repoInfoHash` (optional): SHA256 of the revision API response; only needed
  to resolve a `tag`

Predicates receive each LFS file as an attrset containing `path` and `lfs.oid`:

```nix
filters = file: pkgs.lib.hasSuffix ".safetensors" file.path;
```

The attrset form remains useful for generated expressions and JSON-backed
configuration:

```nix
filters.include = [ ".*\\.safetensors" ];
filters.exclude = [ "original/.*" ];
filters.files = [ "model.safetensors" ];
```

`include` and `exclude` use `builtins.match`, whose regular expressions match
the entire path. For example, `"safetensors"` does not match
`"model.safetensors"`; use `".*\\.safetensors"`. A literal dot is `\.` in the
regular expression and therefore `\\.` inside a Nix string. Only one of
`include`, `exclude`, or `files` is applied; prefer a predicate for combined or
more complex conditions.

#### Offline evaluation

`gitRepoHash` is always required, so the only eval-time fetch left is the file
tree; supply `fileTree` and evaluation performs no network access at all.
`nix-hug fetch --vendor DIR` writes the tree and emits the matching expression.

```nix
nix-hug-lib.fetchModel {
  repoId = "stas/tiny-random-llama-2";
  rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
  fileTree = builtins.fromJSON (builtins.readFile ./trees/stas--tiny-random-llama-2.json);
  fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
  gitRepoHash = "sha256-SrdDsqK7grmWiB0nH4q78jUyGTta3ZX8UXuZCEhPwOw=";
}
```

We suggest you keep the JSON beside the Nix file that reads it. CI asserts the
property by evaluating a vendored expression whose hashes are deliberately
wrong: it reaches a derivation instead of failing, which it could only do
without fetching. `--offline` does not prove this on its own, since
`builtins.fetchurl` ignores it.

Vendoring also decides how a stale hash is reported. The vendored tree goes
through `pkgs.fetchurl`, so a mismatch prints SRI (`sha256-mD+VYvxs...`), which
is what `determinate-nixd fix hashes` and similar auto-updaters expect. Without
`fileTree` the tree is fetched by `builtins.fetchurl`, which reports Nix's
legacy base32 (`sha256:0lpc2dci...`) regardless of the format you supplied.

#### Optional parameters and combination costs

Nothing is an import-from-derivation. Every combination below evaluates with
`allow-import-from-derivation = false`, because `builtins.fetchurl` is an
eval-time builtin, not a read of a built derivation. What varies is **eval-time
network**, decided by two independent choices: whether you pass `fileTree`, and
whether you pass `tag`.

| `rev` | `tag` | `fileTree` | fetched during evaluation               |
| ----- | ----- | ---------- | --------------------------------------- |
| yes   | --    | yes        | nothing                                 |
| yes   | --    | no         | file tree                               |
| yes   | yes   | yes        | revision API                            |
| yes   | yes   | no         | file tree + revision API                |
| --    | yes   | either     | revision API, + file tree if unvendored |

Two consequences are easy to miss.

**Vendoring combines with `tag`.** `fileTree` removes the need for a tree
fetch. Adding `tag` causes a network request to be needed to validate the tag
is present and it matches the fileTree hash. A tagged pin costs one eval-time
round-trip per model, and for that cost you get a check that upstream has not
been updated.

**Vendoring can cost a few seconds due to some local evaluation time
requirements, even on a warm store causes a perf hit**. Even on a fast CPU with
a fast connection, it easily costs more than a `builtins.fetchurl` that hits
the cache. Vendoring helps for offline evaluation, reproducibility and SRI
error reporting. On a cold store the ordering reverses, and it reverses further
once an evaluation imports dozens of models, because those fetches serialise.

Passing `fileTree` changes the derivation but not the download. Weights and
checkout are identical either way and the vendored form adds exactly one, the
`nix-hug-filetree.json` the build copies in. Switching a pin to or from
vendored re-links the assembly once and downloads nothing.

The same holds for adding `tag` to an existing `rev`: all fixed-output
derivations are unchanged and only the assembly moves, because the fetched
revision JSON is embedded in the output. A `tag` with no `repoInfoHash` cannot
be checked at all -- it is inert and warns rather than failing.

`filters` need the file list during evaluation, so they require `fileTree`, or
the tree fetch that stands in for it. Aggregate mode -- `fetchFromHuggingFace`
with no `lfsFiles` -- has no file list and so rejects `filters`, in exchange
for fetching the whole repository as one derivation with nothing evaluated.

#### Relationship to `pkgs.fetchFromHuggingFace`

`nix-hug.lib.${system}.fetchFromHuggingFace` extends nixpkgs'
[`fetchFromHuggingFace`](https://github.com/NixOS/nixpkgs/pull/506303). Calls
without `lfsFiles` delegate unchanged to the upstream aggregate `fetchgit` -- a
check asserts the two produce the same derivation. Calls with `lfsFiles` use
nix-hug's split mode: `hash` is required and addresses the Git checkout with
LFS pointers, while each selected LFS blob is fetched by its own OID. Split
mode never fetches at evaluation time.

```nix
nix-hug.lib.${system}.fetchFromHuggingFace {
  repoId = "openai/gpt-oss-120b";
  rev = "b5c939de8f754692c1647ca79fbf85e8c1e70f8a";
  backend = "lfs";
  hash = "sha256-..."; # Git checkout with LFS pointers
  lfsFiles = builtins.fromJSON (builtins.readFile ./gpt-oss-120b-lfs.json);
  filters = file: pkgs.lib.hasPrefix "original/" file.path;
}
```

`fetchModel`, `fetchDataset`, and `fetchSpace` delegate to this same extended
fetcher. Changing filters therefore needs no new hashes, widening a filter
downloads only newly selected blobs, and repositories sharing an OID share its
store path. For a whole repository under one hash, omit `lfsFiles` and it uses
upstream directly.

There is deliberately no overlay: shadowing `pkgs.fetchFromHuggingFace` would
silently change any package that later adopts it upstream, and calling this
export gives an identical derivation.

#### Upgrading to 6.0 from 5.1

`gitRepoHash` is now required, and it is the only breaking change -- hence the
major bump. The non-LFS checkout is a fixed-output derivation, so nothing is
fetched at evaluation time. In 5.1 a missing `gitRepoHash` silently fell back to
an eval-time `builtins.fetchGit`; now it is an error that names the repository.

`fetchModel`, `fetchDataset` and `url` stay and are not deprecated; `repoId`,
`repoType`, `tag`, `fetchSpace` and `fetchFromHuggingFace` are additions to
align with fetchFromHuggingFace semantics; `derivationHash` is accepted but
ignored.

For one expression, re-run `nix-hug fetch <repoId> --ref <rev>` and copy the
`gitRepoHash` line it prints. For many, discovering the hash directly is a
pointer-only clone; no re-downloads will be necessary.

```nix
pkgs.fetchgit {
  url = "https://huggingface.co/<repoId>.git";
  rev = "<rev>";
  fetchLFS = false;
  hash = pkgs.lib.fakeHash;
}
```

Build it and read the `got:` line. With more than a handful of pins, keep the
hashes in one JSON file beside the expressions and inject them by name, the way
`fileTree` is handled in [Offline evaluation](#offline-evaluation):

```nix
let
  gitRepoHashes = builtins.fromJSON (builtins.readFile ./githashes.json);
in
builtins.mapAttrs (
  name: def: nix-hug-lib.fetchModel (def // { gitRepoHash = gitRepoHashes.${name}; })
) modelDefs
```

Upgrading moves the assembly derivation paths, so each cache re-links once. It
does not re-download weights: LFS blobs are content-addressed by their OID, so
their store paths are unchanged.

### buildCache

Combines fetched models and datasets into a HuggingFace Hub-compatible cache
directory using symlinks (no data duplication).

```nix
nix-hug-lib.buildCache {
  models = [ my-model another-model ];
  datasets = [ my-dataset ];
}
```

Use the result as `HF_HUB_CACHE`:

```console
$ export HF_HUB_CACHE=/nix/store/...-hf-hub-cache
$ export TRANSFORMERS_OFFLINE=1
$ python your_script.py
```

## URL Formats

Models:

- `mistralai/Mistral-7B-Instruct-v0.3`
- `hf:mistralai/Mistral-7B-Instruct-v0.3`
- `https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3`

Datasets:

- `rajpurkar/squad`
- `hf-datasets:rajpurkar/squad`
- `datasets/rajpurkar/squad`
- `https://huggingface.co/datasets/rajpurkar/squad`

Spaces:

- `hf-spaces:julien-c/hello-world`
- `spaces/julien-c/hello-world`
- `https://huggingface.co/spaces/julien-c/hello-world`

A prefixed path is taken at its word. A bare `org/repo` is probed against the
Hugging Face API in order -- dataset, model, space -- so a model and a space
sharing a name resolve to the model; prefix it to get the other one.

Plain git remotes with LFS weights also work:

- `git+https://codeberg.org/org/model`
- `git+ssh://git@codeberg.org/org/model`

`fetch` accepts `--lfs-url URL` when the LFS server differs from the git
remote. These map to the library's `fetchGitLFS` function, which fetches LFS
blobs with `pkgs.fetchurl` at build time, as `fetchModel` does.

`fetchGitLFS` requires both `gitRepoHash` and `lfsFiles`: the checkout is a
`pkgs.fetchgit` fixed-output derivation, and reading it for pointers would make
evaluation import-from-derivation. `nix-hug fetch` discovers both and emits them
-- inline by default, or as a vendored JSON file under `--vendor`.

### Library interface

`lib/default.nix` now takes what it uses and arguments can be overriden:

```nix
{
  pkgs ? null,
  lib ? pkgs.lib,
  fetchurl ? pkgs.fetchurl,
  fetchgit ? pkgs.fetchgit,
  runCommand ? pkgs.runCommand,
  writeText ? pkgs.writeText,
  linkFarm ? pkgs.linkFarm,
  upstreamFetchFromHuggingFace ? if pkgs == null then null
    else pkgs.fetchFromHuggingFace or null
}:
```

`import ./lib { inherit pkgs; }` still works, `pkgs.callPackage ./lib { }`
works, and passing the original six by hand still supports split mode. Pass
`upstreamFetchFromHuggingFace` as well to expose aggregate delegation through
the narrow interface. Everything eval-time is spelled
`builtins.fetchurl`/`builtins.fetchGit` at the call site; the bare names are
the nixpkgs builders, which run at build time.
`lib/fetch-from-hugging-face.nix` has no eval-time fetch at all. A check
asserts the two call styles produce the same derivation.

`nix-hug.lib.${system}` is built from nix-hug's own nixpkgs. To avoid a second
nixpkgs in your closure:

```nix
inputs.nix-hug.inputs.nixpkgs.follows = "nixpkgs";
```

## Development

```console
$ nix develop
$ ./cli/nix-hug --help
```

Run the tests:

```console
$ nix flake check
```

## License

This software is provided free under the [MIT License](LICENSE.md).
