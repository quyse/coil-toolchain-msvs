{ pkgs ? import <nixpkgs> {}
, coil
, lib ? pkgs.lib
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
, versionsInfoFile ? ./versions.json
, versionsInfo ? lib.importJSON versionsInfoFile
}:

rec {
  # Nix-based package downloader for Visual Studio
  # inspiration: https://github.com/mstorsjo/msvc-wine/blob/master/vsdownload.py
  vsPackages = { version, versionPreview ? false }: rec {

    versionParts = lib.splitString "." version;
    versionMajor = lib.head versionParts;
    versionIsMajor = lib.length versionParts <= 1;

    uriPrefix = "https://aka.ms/vs/${versionMajor}/${if versionPreview then (if lib.versionAtLeast version "18" then "insiders" else "pre") else "release"}";

    channelUrl = if versionIsMajor
      then "${uriPrefix}/channel"
      else versionsInfo.channels."${version}"
    ;
    actualChannelUrl = fixeds.fetchurl."${channelUrl}".url;
    channelManifest = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${channelUrl}") url sha256 name;
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

    # resolve dependencies and return manifest for set of packages
    resolve = { product, packageIds, arch ? "x64", arch2 ? "x86", language ? "en-US", includeRecommended ? false, includeOptional ? false }: let
      packageManifest = packageId: package:
        { chip
        , productArch
        , machineArch
        }: let
        packageVariantPred = packageVariant: let
          packageVariantChip = lib.toLower (packageVariant.chip or "neutral");
          packageVariantProductArch = lib.toLower (packageVariant.productArch or "neutral");
          packageVariantMachineArch = lib.toLower (packageVariant.machineArch or "neutral");
        in
          (chip == "" || packageVariantChip == "neutral" || packageVariantChip == chip) &&
          (productArch == "" || packageVariantProductArch == "neutral" || packageVariantProductArch == productArch) &&
          (machineArch == "" || packageVariantMachineArch == "neutral" || packageVariantMachineArch == machineArch) &&
          (!(packageVariant ? language) || packageVariant.language == "neutral" || packageVariant.language == language);
        packageVariants = lib.filter packageVariantPred package;
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
            chip = lib.toLower (depDesc.chip or "");
            productArch = lib.toLower (depDesc.productArch or arch2);
            machineArch = lib.toLower (depDesc.machineArch or "");
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
              lib.attrNames
              (map (fileName: dirOf "${dir}/${fileName}"))
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
        id = "${packageId}-${chip}-${productArch}-${machineArch}";
        variants = map packageVariantManifest packageVariants;
      };

      packageManifests = lib.mapAttrs packageManifest packages;

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
        chip = arch;
        productArch = arch2;
        machineArch = arch;
      }) (packageIds ++ [product]))).packageVariants;
      layoutJson = pkgs.writeText "layout.json" (builtins.toJSON {
        channelUri = actualChannelUrl;
        channelId = channelManifestJSON.info.manifestName;
        productId = product;
        installChannelUri = ".\\ChannelManifest.json";
        installCatalogUri = ".\\Catalog.json";
        add = map (packageId: "${packageId}${lib.optionalString includeRecommended ";includeRecommended"}${lib.optionalString includeOptional ";includeOptional"}") packageIds;
        addProductLang = [language];
      });
    in rec {
      name = "msvs_${shortenProduct product}_${shortenWorkload (lib.head packageIds)}";
      version = channelManifestJSON.info.productSemanticVersion;

      layoutScript = ''
        ${lib.concatStrings (map (packageVariant: packageVariant.layoutScript) packageVariants)}
        ln -s ${channelManifest} ChannelManifest.json
        ln -s ${manifest} Catalog.json
        ln -s ${layoutJson} Layout.json
        ln -s ${layoutJson} Response.json
        ln -s ${vsSetupExe} vs_setup.exe
        ln -s ${vsInstallerExe} vs_installer.opc
      '';

      disk = coil.toolchain-windows.runPackerStep {
        name = "${name}_disk-${version}";
        disk = coil.toolchain-windows.initialDisk {};
        extraMount = "work";
        extraMountOut = false;
        beforeScript = ''
          mkdir -p work/vslayout
          cd work/vslayout
          ${layoutScript}
          cd ../..
        '';
        provisioners = [
          {
            type = "powershell";
            inline = [
              ''D:\work\vslayout\vs_setup.exe --quiet --wait --noWeb --noUpdateInstaller --norestart''
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

    products = lib.pipe manifestJSON.packages [
      (lib.filter (pkg: pkg.type == "Product"))
      (map (pkg: pkg.id))
    ];

    workloads = lib.pipe manifestJSON.packages [
      (lib.filter (pkg: pkg.type == "Workload"))
      (map (pkg: pkg.id))
    ];
  };

  normalizeVsPackageId = lib.toLower;

  shortenProduct = lib.removePrefix "Microsoft.VisualStudio.Product.";
  shortenWorkload = lib.removePrefix "Microsoft.VisualStudio.Workload.";

  trackedVersions = [
    { versionMajor = "18"; versionPreview = true; }
    { versionMajor = "17"; }
    { versionMajor = "16"; }
    { versionMajor = "15"; }
  ];

  trackedProducts = [
    {
      product = "Microsoft.VisualStudio.Product.BuildTools";
      packageIds = ["Microsoft.VisualStudio.Workload.VCTools"];
    }
    {
      product = "Microsoft.VisualStudio.Product.Community";
      packageIds = ["Microsoft.VisualStudio.Workload.NativeDesktop"];
    }
  ];

  trackedVariants = lib.concatMap (version: map (product: version // product) trackedProducts) trackedVersions;

  trackedDisks = lib.pipe trackedVariants [
    (map (variant: let
      resolved = (vsPackages {
        version = variant.versionMajor;
        versionPreview = variant.versionPreview or false;
      }).resolve {
        inherit (variant) product packageIds;
        includeRecommended = true;
      };
    in lib.nameValuePair resolved.name resolved.disk))
    lib.listToAttrs
  ];

  allManifests = lib.pipe versionsInfo.channels [
    (lib.mapAttrsToList (version: _channelUrl: let
      packages = vsPackages {
        inherit version;
      };
    in ''
      ${packages.channelManifest}
      ${packages.manifest}
    ''))
    lib.concatStrings
    (pkgs.writeText "msvs_manifests.txt")
  ];

  updateFixedsManifests = let
    latestMajorVersions = lib.pipe trackedVersions [
      (map (version: let
        packages = vsPackages {
          version = version.versionMajor;
          versionPreview = version.versionPreview or false;
        };
      in lib.nameValuePair version.versionMajor {
        versionPreview = version.versionPreview or false;
        channelUrl = packages.actualChannelUrl;
        manifestUrl = packages.manifestDesc.url;
        version = lib.head (lib.split " " packages.channelManifestJSON.info.productDisplayVersion);
      }))
      lib.listToAttrs
    ];
    changedMajorVersions = lib.foldl (latestVersions: obj: let
      objVersion = obj.comment or "";
      objVersionMajor = lib.head (lib.splitString "." objVersion);
      latestVersion = latestVersions."${objVersionMajor}" or {};
    in if latestVersion.version or null == objVersion
      then removeAttrs latestVersions [objVersionMajor]
      else latestVersions
    ) latestMajorVersions (lib.attrValues fixeds.fetchurl);
    changeForObj = obj: changedMajorVersions."${lib.head (lib.splitString "." (obj.comment or ""))}" or null;
    newFixeds = let
      keptFetchurls = lib.filterAttrs (url: obj: let
        change = changeForObj obj;
      in change == null || !(change.versionPreview or false)) fixeds.fetchurl;
      newFetchurlsChannels = lib.mapAttrs' (_versionMajor: { version, channelUrl, ... }: lib.nameValuePair channelUrl (fixeds.fetchurl."${channelUrl}" or {} // {
        comment = version;
      })) changedMajorVersions;
      newFetchurlsManifests = lib.mapAttrs' (_versionMajor: { version, manifestUrl, ... }: lib.nameValuePair manifestUrl (fixeds.fetchurl."${manifestUrl}" or {} // {
        comment = version;
      })) changedMajorVersions;
    in fixeds // {
      fetchurl = keptFetchurls // newFetchurlsChannels // newFetchurlsManifests;
    };
    newFixedsFile = pkgs.writeText "fixeds.json" (builtins.toJSON newFixeds);
    newVersionsInfo = versionsInfo // {
      channels = lib.pipe changedMajorVersions [
        (lib.filterAttrs (_versionMajor: { versionPreview, ... }: !versionPreview))
        (lib.mapAttrs' (_versionMajor: { version, channelUrl, ... }: lib.nameValuePair version channelUrl))
        (changes: versionsInfo.channels // changes)
      ];
    };
    newVersionsInfoFile = pkgs.runCommand "versions.json" {} ''
      ${pkgs.jq}/bin/jq -S < ${pkgs.writeText "versions.json" (builtins.toJSON newVersionsInfo)} > $out
    '';
    totalComment = lib.pipe changedMajorVersions [
      lib.attrValues
      (map ({ version, ... }: version))
      (lib.sort lib.versionOlder)
      (map (version: "msvs ${version}"))
      (lib.concatStringsSep ", ")
    ];
  in pkgs.runCommand "updateFixedsManifests" {} ''
    mkdir $out
    cp ${newFixedsFile} $out/fixeds.json
    cp ${newVersionsInfoFile} $out/versions.json
    echo ${lib.escapeShellArg (if totalComment == "" then "update fixeds" else totalComment)} > $out/.git-commit
  '';

  autoUpdateScript = pkgs.writeShellScript "toolchain_msvs_auto_update" ''
    set -eu
    shopt -s dotglob
    cp --no-preserve=mode ${fixedsFile} ./fixeds.json
    ${coil.toolchain.refreshFixedsScript}
    if ! cmp -s ${fixedsFile} ./fixeds.json
    then
      NEW_FIXEDS=$(nix-build --show-trace -QA updateFixedsManifests ${./default.nix} --arg coil null --arg fixedsFile ./fixeds.json --arg versionsInfoFile ${versionsInfoFile} --no-out-link)
      cp --no-preserve=mode ''${NEW_FIXEDS:?failed to get new fixeds}/* ./
      ${coil.toolchain.refreshFixedsScript}
    fi
  '';

  touch = trackedDisks // {
    inherit autoUpdateScript allManifests;
  };
}
