{
  lib,
  fetchurl,
  fetchgit,
  runCommand,
  upstreamFetchFromHuggingFace ? null,
}:

let
  inherit
    (import ./lfs.nix {
      inherit lib;
      name = "fetchFromHuggingFace";
    })
    repoTypes
    applyFilter
    validFilter
    validLfsFile
    lfsHash
    escapeUrlPath
    ;
in

lib.makeOverridable (
  args@{
    repoId,
    tag ? null,
    rev ? null,
    name ? "source",
    domain ? "huggingface.co",
    repoType ? "model",
    backend ? "xet",
    lfsFiles ? null,
    filters ? null,
    passthru ? { },
    meta ? { },
    extraCommands ? "",
    rootDir ? "",
    sparseCheckout ? null,
    ...
  }:

  if lfsFiles == null then
    assert lib.assertMsg (filters == null) "fetchFromHuggingFace: filters requires lfsFiles.";
    assert lib.assertMsg (
      upstreamFetchFromHuggingFace != null
    ) "fetchFromHuggingFace: aggregate mode requires nixpkgs' upstream fetcher.";
    upstreamFetchFromHuggingFace (
      removeAttrs args [
        "extraCommands"
        "filters"
        "lfsFiles"
        "derivationHash"
      ]
    )
  else
    assert lib.assertMsg (lib.xor (tag == null) (
      rev == null
    )) "fetchFromHuggingFace requires one of either rev or tag to be provided (not both).";
    assert lib.assertMsg (
      repoTypes ? ${repoType}
    ) "fetchFromHuggingFace: repoType must be model, dataset, or space.";
    assert lib.assertMsg (
      backend == "lfs"
    ) "fetchFromHuggingFace: split LFS mode requires backend = \"lfs\".";
    assert lib.assertMsg (
      builtins.match "[^/]+(/[^/]+)?" repoId != null
    ) "fetchFromHuggingFace: repoId must be \"repo\" or \"owner/repo\".";
    assert lib.assertMsg (validFilter filters)
      "fetchFromHuggingFace: filters must be a predicate or contain exactly one of include, exclude, or files.";
    assert lib.assertMsg (
      rootDir == "" && sparseCheckout == null
    ) "fetchFromHuggingFace: split LFS mode does not support rootDir or sparseCheckout.";
    assert lib.assertMsg (lib.all validLfsFile lfsFiles)
      "fetchFromHuggingFace: every LFS entry needs a relative path that stays inside the output.";
    assert lib.assertMsg (
      (args.hash or args.sha256 or null) != null
    ) "fetchFromHuggingFace: split LFS mode requires hash for the non-LFS git checkout.";
    let
      baseUrl = "https://${domain}/${repoTypes.${repoType}.prefix}${repoId}";
      gitRepoUrl = "${baseUrl}.git";
      ref = if tag != null then tag else rev;

      fetchGitArgs =
        removeAttrs args [
          "backend"
          "derivationHash"
          "domain"
          "extraCommands"
          "filters"
          "lfsFiles"
          "meta"
          "name"
          "passthru"
          "repoId"
          "repoType"
        ]
        // {
          url = gitRepoUrl;
          fetchLFS = false;
        };

      gitRepo = fetchgit fetchGitArgs;

      selectedLfsFiles = applyFilter filters lfsFiles;
      lfsDerivations = map (file: {
        inherit (file) path;
        blob = fetchurl {
          url = "${baseUrl}/resolve/${ref}/${escapeUrlPath file.path}";
          hash = lfsHash file.lfs.oid;
        };
      }) selectedLfsFiles;
    in
    runCommand name
      (
        {
          passthru = {
            inherit
              gitRepo
              gitRepoUrl
              repoId
              repoType
              selectedLfsFiles
              ;
          }
          // passthru;
        }
        // lib.optionalAttrs (meta != { }) { inherit meta; }
      )
      ''
        mkdir -p $out

        cp -rT ${gitRepo} $out/
        chmod -R +w $out

        ${lib.concatMapStringsSep "\n" (file: ''
          mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf file.path)}
          ln -sfn ${file.blob} "$out"/${lib.escapeShellArg file.path}
        '') lfsDerivations}

        ${extraCommands}
      ''
)
