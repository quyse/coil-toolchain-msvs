{ pkgs ? import <nixpkgs> {}
, toolchain
, lib ? pkgs.lib
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
}: let

  windows = toolchain.windows {
    inherit pkgs;
  };

in rec {
  # Nix-based package downloader for Visual Studio
  # inspiration: https://github.com/mstorsjo/msvc-wine/blob/master/vsdownload.py
  vsPackages = { versionMajor, versionPreview ? false, product }: rec {

    uriPrefix = "https://aka.ms/vs/${toString versionMajor}/${if versionPreview then "pre" else "release"}";

    channelUri = "${uriPrefix}/channel";
    channelManifest = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${channelUri}") url sha256 name;
    };
    channelManifestJSON = lib.importJSON channelManifest;

    manifestDesc = lib.head (lib.findSingle (c: c.type == "Manifest") null null channelManifestJSON.channelItems).payloads;
    # size, sha256 are actually wrong for manifest (facepalm)
    # manifest = pkgs.fetchurl {
    #   inherit (manifestDesc) url sha256;
    # };
    manifest = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${manifestDesc.url}") url sha256 name;
    };
    manifestJSON = lib.importJSON manifest;

    packages = lib.groupBy (package: normalizeVsPackageId package.id) manifestJSON.packages;

    packageManifest = packageId: package:
      { arch
      , language
      , includeRecommended
      , includeOptional
      }: let
      packageVariantPred = packageVariant: let
        chipPred = !(packageVariant ? chip) || packageVariant.chip == "neutral" || packageVariant.chip == arch;
      in
        (if packageVariant ? productArch
          then lib.toLower packageVariant.productArch == "neutral" || lib.toLower packageVariant.productArch == arch || chipPred
          else chipPred
        ) &&
        (!(packageVariant ? language) || packageVariant.language == "neutral" || packageVariant.language == language);
      packageVariants = lib.filter packageVariantPred package;
      name = "${packageId}-${arch}-${language}${if includeRecommended then "-rec" else ""}${if includeOptional then "-opt" else ""}";
      packageVariantManifest = packageVariant: let
        payloadManifest = payload: let
          fileName = lib.replaceStrings ["\\"] ["/"] payload.fileName;
        in lib.nameValuePair
          (if packageVariant.type == "Vsix" then "payload.vsix" else fileName)
          (pkgs.fetchurl {
            name = lib.strings.sanitizeDerivationName (baseNameOf fileName);
            inherit (payload) url sha256;
            meta = {
              # presuming everything from MS to be unfree
              license = lib.licenses.unfree;
            };
          });
        depPred = depDesc:
          builtins.typeOf depDesc != "set" ||
          (!(depDesc ? type) ||
            (includeRecommended && depDesc.type == "Recommended") ||
            (includeOptional && depDesc.type == "Optional")) &&
          (!(depDesc ? when) || lib.any (p: p == product) depDesc.when);
        depManifest = depKey: depDesc: let
          depPackageId = normalizeVsPackageId (depDesc.id or depKey);
        in packageManifests."${depPackageId}" {
          arch = depDesc.chip or arch;
          inherit language;
          includeRecommended = false;
          includeOptional = false;
        };
      in rec {
        id = "${packageVariant.id},version=${packageVariant.version}" +
          (if packageVariant.chip or null != null then ",chip=${packageVariant.chip}" else "") +
          (if packageVariant.language or null != null then ",language=${packageVariant.language}" else "") +
          (if packageVariant.branch or null != null then ",branch=${packageVariant.branch}" else "") +
          (if packageVariant.productArch or null != null then ",productarch=${packageVariant.productArch}" else "") +
          (if packageVariant.machineArch or null != null then ",machinearch=${packageVariant.machineArch}" else "");
        # map of payloads, fileName -> fetchurl derivation
        payloads = lib.pipe (packageVariant.payloads or []) [
          (map payloadManifest)
          lib.listToAttrs
        ];
        # list of dependencies (package manifests)
        dependencies = lib.pipe (packageVariant.dependencies or {}) [
          (lib.filterAttrs (_dep: depPred))
          (lib.mapAttrsToList depManifest)
        ];
        layoutScript = let
          dir = id;
          directories = lib.pipe payloads [
            (lib.mapAttrsToList (fileName: _payload:
              dirOf "${dir}/${fileName}"
            ))
            lib.unique
            (lib.sort (a: b: a < b))
          ];
        in ''
          ${lib.optionalString (lib.length directories > 0) "mkdir -p ${lib.escapeShellArgs directories}"}
          ${lib.concatStrings (lib.mapAttrsToList (fileName: payload: ''
            ln -s ${payload} ${lib.escapeShellArg "${dir}/${fileName}"}
          '') payloads)}
        '';
      };
    in rec {
      id = "${packageId}-${arch}-${language}";
      variants = map packageVariantManifest packageVariants;
    };

    packageManifests = lib.mapAttrs packageManifest packages;

    # resolve dependencies and return manifest for set of packages
    resolve = { packageIds, arch, language, includeRecommended ? false, includeOptional ? false }: let
      dfsPackage = package: state: lib.foldr dfsPackageVariant state package.variants;
      dfsPackageVariant = packageVariant: { visited, ... } @ state: if visited."${packageVariant.id}" or false
        then state
        else let
          depsResult = lib.foldr dfsPackage (state // {
            visited = visited // {
              "${packageVariant.id}" = true;
            };
          }) packageVariant.dependencies;
        in state // {
          inherit (depsResult) visited;
          packageVariants = depsResult.packageVariants ++ [packageVariant];
        };
      packageVariants = (lib.foldr dfsPackage {
        visited = {};
        packageVariants = [];
      } (map (packageId: packageManifests."${normalizeVsPackageId packageId}" {
        inherit arch language includeRecommended includeOptional;
      }) (packageIds ++ [product]))).packageVariants;
      layoutJson = pkgs.writeText "layout.json" (builtins.toJSON {
        inherit channelUri;
        channelId = channelManifestJSON.info.manifestName;
        productId = product;
        installChannelUri = ".\\ChannelManifest.json";
        installCatalogUri = ".\\Catalog.json";
        add = map (packageId: "${packageId}${lib.optionalString includeRecommended ";includeRecommended"}${lib.optionalString includeOptional ";includeOptional"}") packageIds;
        addProductLang = [language];
      });
    in {
      layoutScript = ''
        ${lib.concatStringsSep "" (map (packageVariant: packageVariant.layoutScript) packageVariants)}
        ln -s ${channelManifest} ChannelManifest.json
        ln -s ${manifest} Catalog.json
        ln -s ${layoutJson} Layout.json
        ln -s ${layoutJson} Response.json
        ln -s ${vsSetupExe} vs_setup.exe
        ln -s ${vsInstallerExe} vs_installer.opc
      '';
    };

    vsSetupExeDesc = lib.head (lib.findSingle (c: c.type == "Bootstrapper") null null channelManifestJSON.channelItems).payloads;
    vsSetupExe = pkgs.fetchurl {
      inherit (vsSetupExeDesc) url sha256;
      name = vsSetupExeDesc.fileName;
    };

    vsInstallerExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/installer") url sha256 name;
      meta = {
        license = lib.licenses.unfree;
      };
    };

    disk = { packageIds, arch ? "x64", language ? "en-US", includeRecommended ? false, includeOptional ? false }: windows.runPackerStep {
      name = "msvs-${toString versionMajor}-${product}";
      disk = windows.initialDisk {};
      extraMount = "work";
      extraMountOut = false;
      beforeScript = ''
        mkdir -p work/vslayout
        cd work/vslayout
        ${(resolve {
          inherit packageIds arch language includeRecommended includeOptional;
        }).layoutScript}
        cd ../..
      '';
      provisioners = [
        {
          type = "powershell";
          inline = [
            "D:\\vslayout\\vs_setup.exe --quiet --wait --noWeb --noUpdateInstaller --norestart"
          ];
          valid_exit_codes = [
            0
            3010 # success but reboot required
          ];
        }
      ];
      meta = {
        license = lib.licenses.unfree;
      };
    };

  };

  normalizeVsPackageId = lib.toLower;

  vsProducts = {
    buildTools = "Microsoft.VisualStudio.Product.BuildTools";
    community = "Microsoft.VisualStudio.Product.Community";
  };
  vsWorkloads = {
    vcTools = "Microsoft.VisualStudio.Workload.VCTools";
    nativeDesktop = "Microsoft.VisualStudio.Workload.NativeDesktop";
    universal = "Microsoft.VisualStudio.Workload.Universal";
  };

  vsDisk = { versionMajor, versionPreview ? false, product, workloads }: (vsPackages {
    inherit versionMajor versionPreview;
    product = vsProducts."${product}";
  }).disk {
    packageIds = map (workload: vsWorkloads."${workload}") workloads;
    includeRecommended = true;
  };

  trackedVersions = [
    { versionMajor = 17; versionPreview = true; }
    { versionMajor = 16; }
    { versionMajor = 15; }
  ];

  trackedProducts = [
    { product = "buildTools"; workloads = ["vcTools"]; }
    { product = "community"; workloads = ["nativeDesktop"]; }
  ];

  trackedVariants = lib.concatMap (version: map (product: version // product) trackedProducts) trackedVersions;

  trackedDisks = lib.pipe trackedVariants [
    (map (variant: lib.nameValuePair
      "vs${toString variant.versionMajor}${variant.product}Disk"
      (vsDisk variant)
    ))
    lib.listToAttrs
  ];

  updateFixedsManifests = let
    changes = lib.pipe trackedVersions [
      (map (version: let
        packages = vsPackages (version // { product = null; });
      in lib.nameValuePair (toString version.versionMajor) {
        url = packages.manifestDesc.url;
        comment = packages.channelManifestJSON.info.productDisplayVersion;
      }))
      lib.listToAttrs
    ];
    changeForObj = obj: let
      commentParts = lib.splitString "." (obj.comment or "");
    in changes."${lib.head commentParts}" or null;
    newFixeds = fixeds // {
      fetchurl = lib.mapAttrs' (url: obj: let
        change = changeForObj obj;
      in if change != null then lib.nameValuePair change.url (obj // {
        inherit (change) comment;
      }) else lib.nameValuePair url obj) fixeds.fetchurl;
    };
    newFixedsFile = pkgs.writeText "fixeds.json" (builtins.toJSON newFixeds);
    totalComment = lib.pipe fixeds.fetchurl [
      lib.attrValues
      (map (obj: let
        change = changeForObj obj;
      in if change != null && change.comment != obj.comment
        then "msvs ${change.comment}"
        else null
      ))
      (lib.filter (comment: comment != null))
      (lib.sort lib.versionOlder)
      (lib.concatStringsSep ", ")
    ];
  in pkgs.runCommand "updateFixedsManifests" {} ''
    mkdir $out
    cp ${newFixedsFile} $out/fixeds.json
    echo ${lib.escapeShellArg (if totalComment == "" then "update fixeds" else totalComment)} > $out/.git-commit
  '';

  autoUpdateScript = pkgs.writeShellScript "toolchain_msvs_auto_update" ''
    set -e
    shopt -s dotglob
    cp --no-preserve=mode ${fixedsFile} ./fixeds.json
    ${toolchain.refreshFixedsScript}
    if ! cmp -s ${fixedsFile} ./fixeds.json
    then
      NEW_FIXEDS=$(nix-build -QA updateFixedsManifests ${./default.nix} --arg toolchain null --arg fixedsFile ./fixeds.json --no-out-link)
      cp --no-preserve=mode ''${NEW_FIXEDS:?failed to get new fixeds}/* ./
      ${toolchain.refreshFixedsScript}
    fi
  '';

  touch = trackedDisks // {
    inherit autoUpdateScript;
  };
}
