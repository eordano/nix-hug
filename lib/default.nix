{
  pkgs ? null,
  lib ? pkgs.lib,
  fetchurl ? pkgs.fetchurl,
  fetchgit ? pkgs.fetchgit,
  runCommand ? pkgs.runCommand,
  writeText ? pkgs.writeText,
  linkFarm ? pkgs.linkFarm,
  upstreamFetchFromHuggingFace ? if pkgs == null then null else pkgs.fetchFromHuggingFace or null,
}:

let
  inherit (builtins) readFile fromJSON;

  inherit (import ./lfs.nix { inherit lib; })
    repoTypes
    applyFilter
    validateLfsFiles
    lfsHash
    escapeUrlPath
    ;

  fetchFromHuggingFace = import ./fetch-from-hugging-face.nix {
    inherit
      lib
      fetchurl
      fetchgit
      runCommand
      upstreamFetchFromHuggingFace
      ;
  };

  repoIdPrefixes = [
    "https://huggingface.co/datasets/"
    "http://huggingface.co/datasets/"
    "https://huggingface.co/spaces/"
    "http://huggingface.co/spaces/"
    "hf-datasets:"
    "hf-spaces:"
    "datasets/"
    "spaces/"
    "https://huggingface.co/"
    "http://huggingface.co/"
    "hf:"
  ];

  mkRepoId =
    url:
    let
      matched = lib.findFirst (p: lib.hasPrefix p url) null repoIdPrefixes;
      cleaned = if matched == null then url else lib.removePrefix matched url;

      parts = lib.splitString "/" cleaned;
    in
    if (builtins.length parts) < 2 then
      throw "Invalid repository URL '${url}'"
    else
      {
        org = builtins.elemAt parts 0;
        repo = builtins.elemAt parts 1;
        repoId = "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
      };

  getRepoInfo =
    {
      org,
      repo,
      rev ? null,
      tag ? null,
      repoInfoHash ? null,
      fileTreeHash,
      repoType ? "model",
      fileTree ? null,
    }:
    let
      repoId = "${org}/${repo}";
      apiBase = "https://huggingface.co/api/${repoTypes.${repoType}.api}";

      revIsCommitHash = rev != null && builtins.match "[0-9a-f]{40}" rev != null;

      # Every URL keys off the commit hash whenever there is one, never off the
      # tag. That is what makes the "comment out the tag line" remedy below a
      # real one: fileTreeHash and the LFS URLs do not depend on the tag, so
      # removing it changes nothing else and no other hash has to be refreshed.
      # Going through checkedRev rather than rev is deliberate: it forces the
      # drift check before any URL is built, so a moved tag reports the
      # actionable error below instead of whatever 404 or hash mismatch the
      # first-forced fetch would have produced.
      ref =
        if revIsCommitHash then
          (if tag != null then checkedRev else rev)
        else if tag != null then
          tag
        else
          rev;

      isCommitHash = tag == null && revIsCommitHash;

      repoInfoUrl =
        if tag != null then "${apiBase}/${repoId}/revision/${tag}" else "${apiBase}/${repoId}";

      repoInfoFetch = builtins.fetchurl {
        url = repoInfoUrl;
        sha256 = repoInfoHash;
      };

      # A tag with no commit-hash rev has nothing to fall back on, and the fetch
      # above runs during EVALUATION: every `nix eval` that touches this model
      # pays a network round-trip, which is exactly what pinning by commit hash
      # exists to avoid.
      warnBareTag =
        x:
        if tag != null && !revIsCommitHash then
          builtins.trace ''
            nix-hug: tag="${tag}" for ${repoId} is used without a commit-hash rev.
            The revision API is then fetched during EVALUATION (builtins.fetchurl), so
            every `nix eval` importing this model pays a network round-trip, and there
            is no local pin to fall back on when the tag moves.
            Pass rev = "<40-char sha>" next to the tag: nix-hug then builds from the rev
            and treats the tag purely as a drift check.'' x
        else
          x;

      # tag + rev, but no repoInfoHash: nothing to compare against, so the tag
      # is inert rather than a check. Say so instead of silently ignoring it.
      warnUncheckedTag =
        x:
        if tag != null && revIsCommitHash && repoInfoHash == null then
          builtins.trace ''
            nix-hug: tag="${tag}" for ${repoId} cannot be verified without repoInfoHash,
            so it is not checked against rev="${rev}". Run `nix-hug fetch ${repoId} --ref ${tag}`
            to get one, or drop the tag line.'' x
        else
          x;

      repoInfoFetched =
        if repoInfoHash == null then
          null
        else if tag != null then
          repoInfoFetch
        else if revIsCommitHash then
          null
        else
          builtins.trace ''
            nix-hug: rev="${rev}" is not a commit hash. This is DEPRECATED and will stop working in a future release.
            Run `nix-hug fetch ${repoId}` to get a pinned expression with a commit hash.'' repoInfoFetch;

      repoInfoData = if repoInfoFetched != null then fromJSON (readFile repoInfoFetched) else null;

      upstreamRev =
        if repoInfoData != null then (repoInfoData.sha or repoInfoData.commit or null) else null;

      # The rev is the pin; the tag is a canary. If upstream moved the tag off
      # the pinned commit, stop -- building anyway would quietly produce
      # something other than what the tag now names.
      checkedRev =
        if upstreamRev != null && upstreamRev != rev then
          throw ''
            nix-hug: tag="${tag}" for ${repoId} has moved upstream.
              pinned rev : ${rev}
              tag now at : ${upstreamRev}
            Pick one:
              * keep rev ${rev} and drop or comment out the `tag = "${tag}";` line.
                No hash needs refreshing -- every weight FOD is unchanged, so nothing
                re-downloads; the model just re-links once. Do this when you meant to
                stay on this commit and the tag moving is upstream's business.
              * move to ${upstreamRev}: set rev to it, then refresh repoInfoHash,
                fileTreeHash and gitRepoHash with
                `nix-hug fetch ${repoId} --ref ${tag}`. Do this when you meant to
                follow the tag.''
        else
          rev;

      resolvedRev = warnBareTag (
        warnUncheckedTag (
          if tag != null && revIsCommitHash then
            checkedRev
          else if isCommitHash then
            rev
          else if repoInfoData != null then
            (repoInfoData.sha or repoInfoData.commit or ref)
          else if tag != null then
            throw ''
              nix-hug: resolving tag="${tag}" for ${repoId} needs the revision API, so it requires repoInfoHash.
              Run `nix-hug fetch ${repoId} --ref ${tag}` to generate a pinned expression, or pass rev with a commit hash.''
          else
            throw ''
              nix-hug: rev="${rev}" is not a commit hash and no repoInfoHash was provided.
              Run `nix-hug fetch ${repoId}` to generate a pinned expression.''
        )
      );

      fileTreeData =
        if fileTree != null then
          fileTree
        else
          fromJSON (
            readFile (
              builtins.fetchurl {
                url = "${apiBase}/${repoId}/tree/${ref}?recursive=true";
                sha256 = fileTreeHash;
              }
            )
          );

    in
    {
      inherit
        org
        repo
        repoId
        ref
        resolvedRev
        repoInfoFetched
        ;
      lfsFiles = lib.filter (f: f ? lfs) fileTreeData;
    };

  fetchRepo =
    {
      repoId ? null,
      url ? null,
      repoType ? "model",
      rev ? null,
      tag ? null,
      filters ? null,
      repoInfoHash ? null,
      fileTreeHash,
      fileTree ? null,
      gitRepoHash ? null,
      derivationHash ? null,
    }:
    assert lib.assertMsg (repoTypes ? ${repoType})
      "nix-hug: repoType must be one of ${lib.concatStringsSep ", " (builtins.attrNames repoTypes)}, got \"${repoType}\".";
    assert lib.assertMsg (
      repoId == null || url == null
    ) "nix-hug: pass either repoId or url, not both.";
    assert lib.assertMsg (repoId != null || url != null) "nix-hug: repoId is required.";
    # rev and tag together is the recommended shape, not an error: the rev is the
    # pin the build uses, the tag is checked against it and reported if upstream
    # moved. Only "neither" is a mistake.
    assert lib.assertMsg (rev != null || tag != null) "nix-hug: pass rev, tag, or both.";
    assert lib.assertMsg (gitRepoHash != null) ''
      nix-hug: gitRepoHash is required; the non-LFS checkout is a fixed-output derivation.
      Run `nix-hug fetch ${if repoId != null then repoId else url}` to generate a pinned expression.'';
    let
      parsed = mkRepoId (if repoId != null then repoId else url);
      typeApi = repoTypes.${repoType}.api;

      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit
          rev
          tag
          repoInfoHash
          fileTreeHash
          fileTree
          repoType
          ;
      };

      fileTreeSource =
        if fileTree != null then
          fetchurl {
            url = "https://huggingface.co/api/${typeApi}/${repoInfo.repoId}/tree/${repoInfo.ref}?recursive=true";
            sha256 = fileTreeHash;
            name = "nix-hug-filetree.json";
          }
        else
          builtins.fetchurl {
            url = "https://huggingface.co/api/${typeApi}/${repoInfo.repoId}/tree/${repoInfo.ref}?recursive=true";
            sha256 = fileTreeHash;
          };
    in
    fetchFromHuggingFace {
      inherit
        filters
        repoType
        ;
      repoId = repoInfo.repoId;
      rev = repoInfo.resolvedRev;
      backend = "lfs";
      hash = gitRepoHash;
      lfsFiles = repoInfo.lfsFiles;
      name = "hf-${repoType}-${repoInfo.org}-${repoInfo.repo}-${repoInfo.resolvedRev}";
      passthru = {
        inherit (parsed) org repo repoId;
        inherit repoType;
        revision = repoInfo.resolvedRev;
      };
      extraCommands = ''
        ${
          if repoInfo.repoInfoFetched != null then
            "cp ${repoInfo.repoInfoFetched} $out/.nix-hug-repoinfo.json"
          else
            ''echo '{"id":"${repoInfo.repoId}","sha":"${repoInfo.resolvedRev}"}' > $out/.nix-hug-repoinfo.json''
        }

        cp ${fileTreeSource} $out/.nix-hug-filetree.json
      '';
    };

  mkTypedFetcher =
    repoType: args:
    assert lib.assertMsg (!(args ? repoType) || args.repoType == repoType)
      "nix-hug: this fetcher presets repoType = \"${repoType}\"; drop the conflicting repoType = \"${args.repoType}\" or call the matching fetcher.";
    fetchRepo (args // { inherit repoType; });

  fetchModel = mkTypedFetcher "model";
  fetchDataset = mkTypedFetcher "dataset";
  fetchSpace = mkTypedFetcher "space";

  listFilesRecursive =
    base:
    let
      go =
        dir:
        lib.concatLists (
          lib.mapAttrsToList (
            name: type:
            let
              full = "${dir}/${name}";
            in
            if type == "directory" then
              go full
            else if type == "regular" then
              [
                {
                  absPath = full;
                  relPath = builtins.unsafeDiscardStringContext (lib.removePrefix "${base}/" full);
                }
              ]
            else
              [ ]
          ) (builtins.readDir dir)
        );
    in
    go base;

  parseLfsPointer =
    path:
    let
      content = readFile path;
    in
    if !(lib.hasPrefix "version https://git-lfs.github.com/spec/v1" content) then
      null
    else
      let
        lines = lib.splitString "\n" content;
        oidLine = lib.findFirst (l: lib.hasPrefix "oid sha256:" l) null lines;
      in
      if oidLine == null then null else lib.removePrefix "oid sha256:" oidLine;

  discoverLfsFiles =
    gitRepo:
    let
      base = toString gitRepo;
      files = listFilesRecursive base;
      withOid = map (f: {
        path = f.relPath;
        oid = parseLfsPointer f.absPath;
      }) files;
    in
    map (f: {
      inherit (f) path;
      lfs.oid = f.oid;
    }) (lib.filter (f: f.oid != null) withOid);

  fetchGitLfsFiles =
    { url, rev }:
    discoverLfsFiles (
      builtins.fetchGit {
        inherit url rev;
      }
    );

  fetchGitLFS =
    {
      url,
      rev,
      lfsUrl,
      name ? null,
      filters ? null,
      lfsFiles ? null,
      gitRepoHash ? null,
    }:
    assert lib.assertMsg (gitRepoHash != null && lfsFiles != null) ''
      nix-hug: fetchGitLFS needs both gitRepoHash and lfsFiles; the checkout is a fixed-output
      derivation, and reading it for pointers would make evaluation import-from-derivation.
      Run `nix-hug fetch git+${url}` to generate a pinned expression.'';
    let
      gitRepo = fetchgit {
        inherit url rev;
        hash = gitRepoHash;
        fetchLFS = false;
      };

      allLfsFiles = validateLfsFiles lfsFiles;
      filteredLfsFiles = applyFilter filters allLfsFiles;

      effectiveLfsUrl =
        if builtins.isFunction lfsUrl then lfsUrl else (r: p: "${lfsUrl}/${r}/${escapeUrlPath p}");

      lfsDerivations = map (file: {
        inherit (file) path;
        drv = fetchurl {
          url = effectiveLfsUrl rev file.path;
          hash = lfsHash file.lfs.oid;
        };
      }) filteredLfsFiles;

      urlParts = lib.splitString "/" (lib.removeSuffix ".git" url);
      partsLen = builtins.length urlParts;
      derivedName =
        if partsLen >= 2 then
          "git-${builtins.elemAt urlParts (partsLen - 2)}-${builtins.elemAt urlParts (partsLen - 1)}-${rev}"
        else
          "git-repo-${rev}";
      effectiveName = if name != null then name else derivedName;
    in
    runCommand effectiveName
      {
        passthru = {
          revision = rev;
          gitUrl = url;
          selectedLfsFiles = filteredLfsFiles;
        };
      }
      ''
        mkdir -p $out
        cp -rT ${gitRepo} $out/
        chmod -R +w $out

        ${builtins.concatStringsSep "\n" (
          map (lfsFile: ''
            mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf lfsFile.path)}
            ln -sfn ${lfsFile.drv} "$out"/${lib.escapeShellArg lfsFile.path}
          '') lfsDerivations
        )}
      '';

  buildCache =
    {
      models ? [ ],
      datasets ? [ ],
      hash ? null,
    }:
    let
      taggedModels = map (item: {
        inherit item;
        isDataset = false;
      }) models;
      taggedDatasets = map (item: {
        inherit item;
        isDataset = true;
      }) datasets;
      allTagged = taggedModels ++ taggedDatasets;

      itemInfos = map (
        tagged:
        let
          item = tagged.item;
          inherit (item) org repo revision;
          isDataset = tagged.isDataset;
        in
        {
          inherit
            item
            org
            repo
            revision
            isDataset
            ;
          hubPath = if isDataset then "datasets--${org}--${repo}" else "models--${org}--${repo}";
          fullRepoId = "${if isDataset then "dataset" else "model"}:${org}/${repo}";
        }
      ) allTagged;
    in
    (
      if hash != null then
        builtins.trace "nix-hug: buildCache 'hash' parameter is deprecated and ignored. It can be safely removed."
      else
        lib.id
    )
      (
        linkFarm "hf-hub-cache" (
          lib.concatMap (info: [
            {
              name = "${info.hubPath}/snapshots/${info.revision}";
              path = info.item;
            }
            {
              name = "${info.hubPath}/refs/main";
              path = writeText "hf-ref-main" info.revision;
            }
          ]) itemInfos
        )
      );

in
{
  inherit
    fetchModel
    fetchDataset
    fetchSpace
    fetchFromHuggingFace
    fetchGitLFS
    fetchGitLfsFiles
    buildCache
    applyFilter
    ;
  meta = {
    description = "A library for fetching Hugging Face models, datasets and spaces";
    maintainers = [ ];
  };
  version = {
    lib = "6.0.0";
    api = 1;
  };
}
