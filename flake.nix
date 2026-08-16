{
  description = "nix-hug - Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkCLI =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "nix-hug";
          version = "6.0.0";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./cli/nix-hug
              ./cli/completion.bash
              ./cli/completion.fish
              ./cli/completion.zsh
              ./cli/lib/common.sh
              ./cli/lib/commands.sh
              ./cli/lib/hash.sh
              ./cli/lib/nix-expr.sh
              ./cli/lib/ui.sh
              ./lib/default.nix
              ./lib/lfs.nix
              ./lib/fetch-from-hugging-face.nix
            ];
          };

          nativeBuildInputs = with pkgs; [ makeWrapper ];
          buildInputs = with pkgs; [
            bash
            jq
            nix
            cacert
            curl
            git
          ];

          installPhase = ''
            mkdir -p $out/bin $out/share/nix-hug/lib \
              $out/share/bash-completion/completions \
              $out/share/fish/vendor_completions.d \
              $out/share/zsh/site-functions

            cp cli/nix-hug $out/bin/
            chmod +x $out/bin/nix-hug

            cp lib/default.nix $out/share/nix-hug/lib/
            cp lib/lfs.nix $out/share/nix-hug/lib/
            cp lib/fetch-from-hugging-face.nix $out/share/nix-hug/lib/
            cp cli/lib/common.sh $out/share/nix-hug/lib/
            cp cli/lib/commands.sh $out/share/nix-hug/lib/
            cp cli/lib/hash.sh $out/share/nix-hug/lib/
            cp cli/lib/nix-expr.sh $out/share/nix-hug/lib/
            cp cli/lib/ui.sh $out/share/nix-hug/lib/

            cp cli/completion.bash $out/share/bash-completion/completions/nix-hug
            cp cli/completion.fish $out/share/fish/vendor_completions.d/nix-hug.fish
            cp cli/completion.zsh $out/share/zsh/site-functions/_nix-hug

            wrapProgram $out/bin/nix-hug \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.nix
                  pkgs.jq
                  pkgs.curl
                  pkgs.git
                ]
              } \
              --set NIX_HUG_LIB_DIR $out/share/nix-hug/lib \
              --set NIX_HUG_FLAKE_PATH ${
                builtins.path {
                  path = self.outPath;
                  name = "nix-hug-source";
                }
              }
          '';

          meta = with pkgs.lib; {
            description = "Declarative Hugging Face model management for Nix";
            longDescription = "Manages Hugging Face models in Nix with reproducible fetching, caching, and offline builds.";
            homepage = "https://github.com/eordano/nix-hug";
            license = licenses.mit;
            platforms = platforms.all;
            mainProgram = "nix-hug";
          };
        };

    in
    {
      packages = forAllSystems (
        pkgs:
        let
          nix-hug = mkCLI pkgs;
        in
        {
          inherit nix-hug;
          default = nix-hug;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nix
            jq
            bash
            shellcheck
            shfmt
            nixfmt
            curl
            (mkCLI pkgs)
          ];

          shellHook = ''
            export NIX_HUG_LIB_DIR=$PWD/cli/lib
            export PATH=$PWD/cli:$PATH
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${mkCLI pkgs}/bin/nix-hug";
          meta.description = "Declarative Hugging Face model management for Nix";
        };
      });

      formatter = forAllSystems (
        pkgs:
        pkgs.writeShellApplication {
          name = "nix-hug-fmt";
          runtimeInputs = with pkgs; [
            findutils
            nixfmt
            shfmt
          ];
          text = ''
            roots=("$@")
            if [ ''${#roots[@]} -eq 0 ]; then roots=("."); fi

            find "''${roots[@]}" -type f -name '*.nix' \
              -not -path '*/.git/*' -exec nixfmt {} +

            find "''${roots[@]}" -type f \( -name '*.sh' -o -name 'nix-hug' \) \
              -not -path '*/.git/*' -exec shfmt -w -i 2 -ci {} +
          '';
        }
      );

      lib = forAllSystems (pkgs: import ./lib { inherit pkgs; });

      checks = forAllSystems (
        pkgs:
        let
          nix-hug-lib = import ./lib { inherit pkgs; };
          narrow-lib = import ./lib {
            inherit (pkgs)
              lib
              fetchurl
              fetchgit
              runCommand
              writeText
              linkFarm
              ;
          };

          llamaId = "stas/tiny-random-llama-2";

          llama = {
            rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
            fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
            gitRepoHash = "sha256-SrdDsqK7grmWiB0nH4q78jUyGTta3ZX8UXuZCEhPwOw=";
          };

          llamaTree = { inherit (llama) rev fileTreeHash; };

          llamaModel = extra: nix-hug-lib.fetchModel (llama // { repoId = llamaId; } // extra);

          tiny-llama = nix-hug-lib.fetchModel (llama // { url = llamaId; });

          tiny-llama-repoid = llamaModel { };

          hello-space = nix-hug-lib.fetchSpace {
            repoId = "julien-c/hello-world";
            rev = "4884451c8783f0eb1416903f79b643c756aaaf9a";
            fileTreeHash = "sha256-byTXe33x1uGbldDjiZOnRoE1vyh7u31YnlqCjpxbI3I=";
            gitRepoHash = "sha256-BSuQDGU/jdMkfBmEZV9Sn523N27+0OzuxRBdEjfvdXQ=";
          };

          filtered-llama = llamaModel { filters.include = [ ".*\\.safetensors" ]; };

          predicate-filtered-llama = llamaModel {
            filters = file: pkgs.lib.hasSuffix ".safetensors" file.path;
          };

          model-cache = nix-hug-lib.buildCache {
            models = [ tiny-llama ];
          };

          vendored-git = nix-hug-lib.fetchGitLFS {
            inherit (llama) rev gitRepoHash;
            url = "https://huggingface.co/${llamaId}";
            lfsUrl = "https://huggingface.co/${llamaId}/resolve";
            lfsFiles = builtins.fromJSON (builtins.readFile ./tests/fixtures/tiny-llama-lfs.json);
            filters.include = [ ".*\\.safetensors" ];
          };

          split-llama = nix-hug-lib.fetchFromHuggingFace {
            repoId = llamaId;
            inherit (llama) rev;
            backend = "lfs";
            hash = llama.gitRepoHash;
            lfsFiles = builtins.fromJSON (builtins.readFile ./tests/fixtures/tiny-llama-lfs.json);
            filters = file: pkgs.lib.hasSuffix ".safetensors" file.path;
          };

          aggregateFetchArgs = {
            repoId = llamaId;
            inherit (llama) rev;
            backend = "lfs";
            hash = pkgs.lib.fakeHash;
          };

          unsafeLfsFiles = [
            {
              path = "weights/../../escape";
              lfs.oid = "0000000000000000000000000000000000000000000000000000000000000000";
            }
          ];

          mkPointerTest =
            name: repo: note:
            pkgs.runCommand name { } ''
              if head -c 64 ${repo}/model.safetensors | grep -qa 'git-lfs.github.com/spec'; then
                echo "selected weight is still an LFS pointer" >&2
                exit 1
              fi

              if ! head -c 64 ${repo}/tokenizer.model | grep -qa 'git-lfs.github.com/spec'; then
                echo "excluded weight was downloaded; the checkout must keep LFS pointers" >&2
                exit 1
              fi

              echo "${note}" > $out
            '';

          unsafe-vendored-git = builtins.tryEval (
            (nix-hug-lib.fetchGitLFS {
              url = "https://example.invalid/model.git";
              rev = "0000000000000000000000000000000000000000";
              lfsUrl = "https://example.invalid/model/resolve";
              lfsFiles = unsafeLfsFiles;
              gitRepoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            }).drvPath
          );

          unsafe-split = builtins.tryEval (
            (nix-hug-lib.fetchFromHuggingFace {
              repoId = "owner/model";
              rev = "0000000000000000000000000000000000000000";
              backend = "lfs";
              hash = pkgs.lib.fakeHash;
              lfsFiles = unsafeLfsFiles;
            }).drvPath
          );

          hashless-split = builtins.tryEval (
            (nix-hug-lib.fetchFromHuggingFace {
              repoId = "owner/model";
              rev = "0000000000000000000000000000000000000000";
              backend = "lfs";
              lfsFiles = [
                {
                  path = "model.safetensors";
                  lfs.oid = "0000000000000000000000000000000000000000000000000000000000000000";
                }
              ];
            }).drvPath
          );

          hashless-model = builtins.tryEval (
            (nix-hug-lib.fetchModel {
              repoId = llamaId;
              inherit (llama) rev fileTreeHash;
              fileTree = builtins.fromJSON (builtins.readFile ./tests/fixtures/tiny-llama-tree.json);
            }).drvPath
          );

          mistyped-repo-type = builtins.tryEval (
            (nix-hug-lib.fetchModel (
              llama
              // {
                repoId = llamaId;
                repoType = "dataset";
              }
            )).drvPath
          );

          hashless-git = builtins.tryEval (
            (nix-hug-lib.fetchGitLFS {
              url = "https://example.invalid/model.git";
              rev = "0000000000000000000000000000000000000000";
              lfsUrl = "https://example.invalid/model/resolve";
              lfsFiles = [ ];
            }).drvPath
          );
        in
        {
          cliFetchCacheTest =
            pkgs.runCommand "nix-hug-cli-fetch-cache-test" { nativeBuildInputs = [ pkgs.bash ]; }
              ''
                export NIX_HUG_LIB_DIR=${./cli/lib}
                source ${./cli/lib/common.sh}
                source ${./cli/lib/commands.sh}

                find_valid_store_path() {
                  echo /nix/store/stale-name-only-match
                  return 0
                }
                build_with_expr() {
                  touch "$TMPDIR/exact-build-used"
                  echo /nix/store/exact-filtered-output
                }
                generate_fetch_expr() { echo hub-expression; }
                generate_git_fetch_expr() { echo git-expression; }
                generate_usage_example() { :; }
                generate_git_usage_example() { :; }
                suggest_vendor() { :; }

                build_and_report \
                  models/org/repo \
                  0000000000000000000000000000000000000000 \
                  '{ include = [ ".*\\.safetensors" ]; }' \
                  sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
                  model
                test -e "$TMPDIR/exact-build-used"

                rm "$TMPDIR/exact-build-used"
                parse_git_url() {
                  _git_url=https://example.invalid/org/repo
                  _git_lfs_url=https://example.invalid/org/repo/resolve
                  _git_ref=""
                  _git_org=org
                  _git_repo=repo
                }
                resolve_git_ref() { echo 0000000000000000000000000000000000000000; }
                discover_git_lfs_files() { echo '[]'; }
                discover_git_repo_hash() { echo sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
                cmd_fetch_git \
                  git+https://example.invalid/org/repo \
                  main false "" "" \
                  --include '*.safetensors'
                test -e "$TMPDIR/exact-build-used"

                echo "filtered fetches use exact derivation checks" > $out
              '';

          filterApiTest =
            assert pkgs.lib.assertMsg (
              predicate-filtered-llama.drvPath == filtered-llama.drvPath
            ) "nix-hug: predicate and regex filters selected different derivations";
            assert pkgs.lib.assertMsg (
              map (file: file.path) predicate-filtered-llama.selectedLfsFiles == [ "model.safetensors" ]
            ) "nix-hug: selectedLfsFiles did not expose the filtered LFS set";
            assert pkgs.lib.assertMsg (
              !unsafe-vendored-git.success
            ) "nix-hug: an unsafe vendored LFS path reached a derivation";
            pkgs.runCommand "nix-hug-filter-api-test" { } ''
              echo "predicate filters, selectedLfsFiles and path validation passed" > $out
            '';

          fetchFromHuggingFaceTest =
            assert pkgs.lib.assertMsg (
              (nix-hug-lib.fetchFromHuggingFace aggregateFetchArgs).drvPath
              == (pkgs.fetchFromHuggingFace aggregateFetchArgs).drvPath
            ) "nix-hug: the library wrapper changed upstream aggregate fetches";
            assert pkgs.lib.assertMsg (
              map (file: file.path) split-llama.selectedLfsFiles == [ "model.safetensors" ]
            ) "nix-hug: fetchFromHuggingFace did not expose the selected split LFS files";
            assert pkgs.lib.assertMsg (
              !unsafe-split.success
            ) "nix-hug: fetchFromHuggingFace accepted an unsafe LFS path";
            assert pkgs.lib.assertMsg (
              !hashless-split.success
            ) "nix-hug: fetchFromHuggingFace split mode ran without a checkout hash";
            assert pkgs.lib.assertMsg (!hashless-model.success) "nix-hug: fetchModel ran without gitRepoHash";
            assert pkgs.lib.assertMsg (!hashless-git.success) "nix-hug: fetchGitLFS ran without gitRepoHash";
            assert pkgs.lib.assertMsg (
              !mistyped-repo-type.success
            ) "nix-hug: fetchModel silently overrode a conflicting repoType";
            mkPointerTest "nix-hug-fetch-from-hugging-face-test" split-llama
              "fetchFromHuggingFace delegates aggregate mode and extends split LFS mode";

          filterTest =
            mkPointerTest "nix-hug-filter-test" filtered-llama
              "filters materialise selected blobs and leave the rest as pointers";

          compatTest =
            let
              sameAs =
                name: a: b:
                if a == b then [ ] else [ "${name}: ${toString a} != ${toString b}" ];

              failures =
                sameAs "repoId-synonym" tiny-llama.drvPath tiny-llama-repoid.drvPath
                ++
                  sameAs "hf-prefix" tiny-llama.drvPath
                    (nix-hug-lib.fetchModel (llama // { url = "hf:stas/tiny-random-llama-2"; })).drvPath
                ++
                  sameAs "https-prefix" tiny-llama.drvPath
                    (nix-hug-lib.fetchModel (llama // { url = "https://huggingface.co/stas/tiny-random-llama-2"; }))
                    .drvPath
                ++
                  sameAs "narrow-interface" tiny-llama.drvPath
                    (narrow-lib.fetchModel (llama // { url = "stas/tiny-random-llama-2"; })).drvPath;
            in
            assert pkgs.lib.assertMsg (
              failures == [ ]
            ) "nix-hug: backwards-compatibility drift: ${builtins.concatStringsSep "; " failures}";
            pkgs.runCommand "nix-hug-compat-test" { } ''
              echo "pre-5.2 call shapes unchanged" > $out
            '';

          gitLfsTest =
            mkPointerTest "nix-hug-git-lfs-test" vendored-git
              "vendored git+LFS fetch filters without reading the checkout";

          spaceTest = pkgs.runCommand "nix-hug-space-test" { } ''
            test -f ${hello-space}/app.py
            test -f ${hello-space}/README.md
            test -f ${hello-space}/.nix-hug-filetree.json
            echo "space fetch passed" > $out
          '';

          buildCacheTest =
            pkgs.runCommand "nix-hug-buildcache-test"
              {
                buildInputs = [
                  (pkgs.python3.withPackages (
                    ps: with ps; [
                      transformers
                      torch
                    ]
                  ))
                ];
              }
              ''
                export HF_HUB_CACHE=${model-cache}
                export TRANSFORMERS_OFFLINE=1
                python3 -c "
                from transformers import AutoModelForCausalLM, AutoTokenizer
                import os
                cache = os.environ['HF_HUB_CACHE']
                snap = os.path.join(cache, 'models--stas--tiny-random-llama-2', 'snapshots')
                revs = os.listdir(snap)
                assert len(revs) == 1, f'Expected 1 snapshot, got {len(revs)}'
                path = os.path.join(snap, revs[0])
                model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True)
                tok = AutoTokenizer.from_pretrained(path, local_files_only=True)
                print(f'Model: {type(model).__name__}, Tokenizer: {type(tok).__name__}')
                print('buildCache test passed!')
                " 2>&1 | tee $out
              '';

        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          buildCacheVMTest = pkgs.testers.nixosTest {
            name = "nix-hug-buildcache-vm-test";

            nodes.machine =
              { pkgs, ... }:
              {
                virtualisation = {
                  memorySize = 2048;
                  diskSize = 8192;
                };
                environment.systemPackages = [
                  (pkgs.python3.withPackages (
                    ps: with ps; [
                      transformers
                      torch
                    ]
                  ))
                  (mkCLI pkgs)
                ];
                system.extraDependencies = [
                  model-cache
                  tiny-llama
                ];
              };

            testScript = ''
              start_all()
              machine.wait_for_unit("multi-user.target")
              machine.fail("ping -c 1 8.8.8.8")
              machine.fail("ping -c 1 huggingface.co")

              machine.succeed("""cat > /tmp/test-cache.py << 'PYEOF'
              from transformers import AutoModelForCausalLM, AutoTokenizer
              import os, sys
              cache = os.environ.get('HF_HUB_CACHE')
              if not cache: print("ERROR: HF_HUB_CACHE not set"); sys.exit(1)
              snap = os.path.join(cache, 'models--stas--tiny-random-llama-2', 'snapshots')
              revs = os.listdir(snap)
              assert len(revs) == 1, f'Expected 1 snapshot, got {len(revs)}'
              path = os.path.join(snap, revs[0])
              model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True)
              tok = AutoTokenizer.from_pretrained(path, local_files_only=True)
              print(f'Model: {type(model).__name__}, Tokenizer: {type(tok).__name__}')
              print('Model loaded successfully!')
              PYEOF""")

              output = machine.succeed("HF_HUB_CACHE=${model-cache} TRANSFORMERS_OFFLINE=1 python3 /tmp/test-cache.py")
              assert "Model loaded successfully!" in output
              print("buildCache VM test passed!")

              # Phase 1: Export from nix store to HF cache (offline, no network)
              machine.succeed("nix-hug export stas/tiny-random-llama-2 2>&1")

              # Phase 2: Verify blobs+symlinks structure
              machine.succeed("test -d /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/blobs")
              machine.succeed("test -f /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/refs/main")
              # Snapshot files must be symlinks pointing into blobs/
              machine.succeed("test -L /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/snapshots/*/config.json")

              # Phase 3: Verify Python/transformers loads from exported HF cache
              machine.succeed("""cat > /tmp/test-export.py << 'PYEOF'
              from transformers import AutoModelForCausalLM, AutoTokenizer
              model = AutoModelForCausalLM.from_pretrained('stas/tiny-random-llama-2', local_files_only=True)
              tok = AutoTokenizer.from_pretrained('stas/tiny-random-llama-2', local_files_only=True)
              print('Export cache load OK!')
              PYEOF""")
              output = machine.succeed("HF_HUB_CACHE=/root/.cache/huggingface/hub TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1 python3 /tmp/test-export.py")
              assert "Export cache load OK!" in output
              print("Export + HF cache load verified!")

              # Phase 4: Rename snapshot to a fake rev so import creates a NEW store path
              cache_dir = "/root/.cache/huggingface/hub/models--stas--tiny-random-llama-2"
              real_rev = machine.succeed(f"cat {cache_dir}/refs/main").strip()
              fake_rev = "0" * 40
              machine.succeed(f"mv {cache_dir}/snapshots/{real_rev} {cache_dir}/snapshots/{fake_rev}")
              machine.succeed(f"printf '%s' {fake_rev} > {cache_dir}/refs/main")

              # Phase 5: Import from the exported HF cache (creates new store path with fake rev)
              machine.succeed("HF_HUB_CACHE=/root/.cache/huggingface/hub nix-hug import stas/tiny-random-llama-2 2>&1")

              # Phase 6: Verify the new store path exists
              machine.succeed(f"nix-store --check-validity $(echo /nix/store/*-hf-model-stas-tiny-random-llama-2-{fake_rev})")
              print("Round-trip test passed!")
            '';
          };
        }
      );
    };
}
