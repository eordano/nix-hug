{ pkgs }:

let
  inherit (builtins)
    fetchGit
    readFile
    fromJSON
    ;
  inherit (pkgs) fetchurl lib;
  inherit (lib) optionalAttrs;

  applyFilter =
    filter: files:
    if filter == null then
      files
    else
      let
        validFiles = lib.filter (f: f != null && builtins.isAttrs f && f ? path) files;

        lfsFiles = lib.filter (f: f ? lfs) validFiles;
        nonLfsFiles = lib.filter (f: !(f ? lfs)) validFiles;

        filteredFiles =
          if filter ? include then
            lib.filter (f: lib.any (pattern: builtins.match pattern f.path != null) filter.include) lfsFiles
            ++ nonLfsFiles
          else if filter ? exclude then
            lib.filter (f: !lib.any (pattern: builtins.match pattern f.path != null) filter.exclude) lfsFiles
            ++ nonLfsFiles
          else if filter ? files then
            lib.filter (f: lib.elem f.path filter.files) validFiles
          else
            validFiles;
      in
      filteredFiles;

  mkRepoId =
    url: isDataset:
    let
      # Handle different URL formats
      cleaned =
        if lib.hasPrefix "https://huggingface.co/datasets/" url then
          lib.removePrefix "https://huggingface.co/datasets/" url
        else if lib.hasPrefix "http://huggingface.co/datasets/" url then
          lib.removePrefix "http://huggingface.co/datasets/" url
        else if lib.hasPrefix "hf-datasets:" url then
          lib.removePrefix "hf-datasets:" url
        else if lib.hasPrefix "datasets/" url then
          lib.removePrefix "datasets/" url
        else if lib.hasPrefix "https://huggingface.co/" url then
          lib.removePrefix "https://huggingface.co/" url
        else if lib.hasPrefix "http://huggingface.co/" url then
          lib.removePrefix "http://huggingface.co/" url
        else if lib.hasPrefix "hf:" url then
          lib.removePrefix "hf:" url
        else
          url;

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
      rev,
      repoInfoHash ? null,
      fileTreeHash,
      isDataset ? false,
    }:
    let
      repoId = "${org}/${repo}";
      apiBase = "https://huggingface.co/api/${if isDataset then "datasets" else "models"}";
      isCommitHash = builtins.match "[0-9a-f]{40}" rev != null;

      # Legacy path: when rev is not a commit hash, fetch API to resolve it
      repoInfoFetched =
        if (!isCommitHash && repoInfoHash != null) then
          builtins.trace
            ''
              nix-hug: rev="${rev}" is not a commit hash. This is DEPRECATED and will stop working in a future release.
              Run `nix-hug fetch ${repoId}` to get a pinned expression with a commit hash.''
            (fetchurl {
              url = "${apiBase}/${repoId}";
              sha256 = repoInfoHash;
            })
        else
          null;

      repoInfoData = if repoInfoFetched != null then fromJSON (readFile repoInfoFetched) else null;

      resolvedRev =
        if isCommitHash then
          rev
        else if repoInfoData != null then
          (repoInfoData.sha or repoInfoData.commit or rev)
        else
          throw ''
            nix-hug: rev="${rev}" is not a commit hash and no repoInfoHash was provided.
            Run `nix-hug fetch ${repoId}` to generate a pinned expression.'';

      fileTreeData = fromJSON (
        readFile (fetchurl {
          url = "${apiBase}/${repoId}/tree/${rev}?recursive=true";
          sha256 = fileTreeHash;
        })
      );

    in
    {
      inherit
        org
        repo
        repoId
        rev
        resolvedRev
        repoInfoFetched
        ;
      files = lib.filter (f: (f.type or "") != "directory") fileTreeData;
      lfsFiles = lib.filter (f: f ? lfs) fileTreeData;
      nonLfsFiles = lib.filter (f: !(f ? lfs) && (f.type or "") != "directory") fileTreeData;
    };

  fetchRepo =
    isDataset:
    {
      url,
      rev,
      filters ? null,
      repoInfoHash ? null, # deprecated — kept for backward compat
      fileTreeHash,
      derivationHash ? null, # deprecated — kept for backward compat
    }:
    let
      parsed = mkRepoId url isDataset;
      typePrefix = if isDataset then "datasets/" else "";
      typeName = if isDataset then "dataset" else "model";
      typeApi = if isDataset then "datasets" else "models";

      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit
          rev
          repoInfoHash
          fileTreeHash
          isDataset
          ;
      };

      gitRepo = fetchGit {
        url = "https://huggingface.co/${typePrefix}${repoInfo.repoId}.git";
        rev = repoInfo.resolvedRev;
      };

      filteredLfsFiles = applyFilter filters repoInfo.lfsFiles;

      lfsDerivations = map (file: {
        name = file.path;
        drv = fetchurl {
          url = "https://huggingface.co/${typePrefix}${repoInfo.repoId}/resolve/${repoInfo.resolvedRev}/${file.path}";
          sha256 = file.lfs.oid;
        };
      }) filteredLfsFiles;
    in
    pkgs.runCommand "hf-${typeName}-${repoInfo.org}-${repoInfo.repo}-${repoInfo.resolvedRev}"
      (
        {
          passthru = {
            inherit (parsed) org repo;
            revision = repoInfo.resolvedRev;
          };
        }
        // optionalAttrs (derivationHash != null) {
          outputHash = derivationHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        }
      )
      ''
        mkdir -p $out

        cp -rT ${gitRepo} $out/
        chmod -R +w $out

        ${builtins.concatStringsSep "\n" (
          map (lfsFile: ''
            mkdir -p "$out/$(dirname "${lfsFile.name}")"
            ln -sf ${lfsFile.drv} "$out/${lfsFile.name}"
          '') lfsDerivations
        )}

        ${
          if repoInfo.repoInfoFetched != null then
            # Legacy: copy full API response (backward compat with old derivationHash)
            "cp ${repoInfo.repoInfoFetched} $out/.nix-hug-repoinfo.json"
          else
            ''echo '{"id":"${repoInfo.repoId}","sha":"${repoInfo.resolvedRev}"}' > $out/.nix-hug-repoinfo.json''
        }

        cp ${
          fetchurl {
            url = "https://huggingface.co/api/${typeApi}/${repoInfo.repoId}/tree/${rev}?recursive=true";
            sha256 = fileTreeHash;
          }
        } $out/.nix-hug-filetree.json
      '';

  fetchModel = fetchRepo false;
  fetchDataset = fetchRepo true;

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
                  # Strip store path context so relPath can be used in fetchurl URLs
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

  fetchGitLFS =
    {
      url,
      rev,
      lfsUrl,
      name ? null,
      filters ? null,
    }:
    let
      gitRepo = fetchGit { inherit url rev; };

      allLfsFiles = discoverLfsFiles gitRepo;
      filteredLfsFiles = applyFilter filters allLfsFiles;

      effectiveLfsUrl =
        if builtins.isFunction lfsUrl then lfsUrl else (r: p: "${lfsUrl}/${r}/${p}");

      lfsDerivations = map (file: {
        inherit (file) path;
        drv = fetchurl {
          url = effectiveLfsUrl rev file.path;
          sha256 = file.lfs.oid;
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
    pkgs.runCommand effectiveName {
      passthru = {
        revision = rev;
        gitUrl = url;
      };
    } ''
      mkdir -p $out
      cp -rT ${gitRepo} $out/
      chmod -R +w $out

      ${builtins.concatStringsSep "\n" (
        map (lfsFile: ''
          ln -sf ${lfsFile.drv} "$out/${lfsFile.path}"
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
        pkgs.linkFarm "hf-hub-cache" (
          lib.concatMap (info: [
            {
              name = "${info.hubPath}/snapshots/${info.revision}";
              path = info.item;
            }
            {
              name = "${info.hubPath}/refs/main";
              path = pkgs.writeText "hf-ref-main" info.revision;
            }
          ]) itemInfos
        )
      );

in
{
  inherit
    fetchModel
    fetchDataset
    fetchGitLFS
    buildCache
    applyFilter
    ;
  meta = {
    description = "A library for fetching Hugging Face models";
    maintainers = [ "nix-hug" ];
  };
  version = {
    lib = "5.0.0";
    api = 1;
  };
}
