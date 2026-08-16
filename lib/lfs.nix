{
  lib,
  name ? "nix-hug",
}:

rec {
  repoTypes = {
    model = {
      prefix = "";
      api = "models";
    };
    dataset = {
      prefix = "datasets/";
      api = "datasets";
    };
    space = {
      prefix = "spaces/";
      api = "spaces";
    };
  };

  applyFilter =
    filter: files:
    if filter == null then
      files
    else if builtins.isFunction filter then
      lib.filter filter files
    else if filter ? include then
      lib.filter (f: lib.any (pattern: builtins.match pattern f.path != null) filter.include) files
    else if filter ? exclude then
      lib.filter (f: lib.all (pattern: builtins.match pattern f.path == null) filter.exclude) files
    else if filter ? files then
      lib.filter (f: lib.elem f.path filter.files) files
    else
      throw "${name}: filters must be a predicate or contain include, exclude, or files.";

  validFilter =
    filter:
    filter == null
    || builtins.isFunction filter
    || (
      builtins.isAttrs filter
      && builtins.length (builtins.attrNames filter) == 1
      && lib.elem (builtins.head (builtins.attrNames filter)) [
        "exclude"
        "files"
        "include"
      ]
    );

  validLfsFile =
    file:
    !lib.hasPrefix "/" file.path
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" file.path);

  validateLfsFiles =
    files:
    assert lib.assertMsg (lib.all validLfsFile files)
      "${name}: every LFS entry needs a relative path that stays inside the output.";
    files;

  lfsHash =
    oid:
    builtins.convertHash {
      hash = oid;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  escapeUrlPath = path: lib.concatStringsSep "/" (map lib.escapeURL (lib.splitString "/" path));
}
