{ pkgs
, toolchain
}: let

  windows = toolchain.windows {
    inherit pkgs;
  };

in rec {
  # Nix-based package downloader for Visual Studio
  # inspiration: https://github.com/mstorsjo/msvc-wine/blob/master/vsdownload.py
  vsPackages = { versionMajor, versionPreview ? false, product }: let

    uriPrefix = "https://aka.ms/vs/${toString versionMajor}/${if versionPreview then "pre" else "release"}";

    channelUri = "${uriPrefix}/channel";
    channelManifest = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${channelUri}") url sha256 name;
    };
    channelManifestJSON = builtins.fromJSON (builtins.readFile channelManifest);

    manifestDesc = builtins.head (pkgs.lib.findSingle (c: c.type == "Manifest") null null channelManifestJSON.channelItems).payloads;
    # size, sha256 are actually wrong for manifest (facepalm)
    # manifest = pkgs.fetchurl {
    #   inherit (manifestDesc) url sha256;
    # };
    manifest = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${manifestDesc.url}") url sha256 name;
    };
    manifestJSON = builtins.fromJSON (builtins.readFile manifest);

    packages = pkgs.lib.groupBy (package: normalizeVsPackageId package.id) manifestJSON.packages;

    packageManifest = packageId: package:
      { arch
      , language
      , includeRecommended
      , includeOptional
      }: let
      packageVariantPred = packageVariant:
        (!(packageVariant ? chip) || packageVariant.chip == "neutral" || packageVariant.chip == arch) &&
        (!(packageVariant ? language) || packageVariant.language == "neutral" || packageVariant.language == language);
      packageVariants = builtins.filter packageVariantPred package;
      name = "${packageId}-${arch}-${language}${if includeRecommended then "-rec" else ""}${if includeOptional then "-opt" else ""}";
      packageVariantManifest = packageVariant: let
        payloadManifest = payload: let
          fileName = builtins.replaceStrings ["\\"] ["/"] payload.fileName;
        in pkgs.lib.nameValuePair
          (if packageVariant.type == "Vsix" then "payload.vsix" else fileName)
          (pkgs.fetchurl {
            name = pkgs.lib.strings.sanitizeDerivationName (baseNameOf fileName);
            inherit (payload) url sha256;
          });
        depPred = depDesc:
          builtins.typeOf depDesc != "set" ||
          (!(depDesc ? type) ||
            (includeRecommended && depDesc.type == "Recommended") ||
            (includeOptional && depDesc.type == "Optional")) &&
          (!(depDesc ? when) || pkgs.lib.any (p: p == product) depDesc.when);
        depManifest = depPackageId: depDesc: packageManifests.${normalizeVsPackageId depPackageId} {
          arch = depDesc.chip or arch;
          inherit language;
          includeRecommended = false;
          includeOptional = false;
        };
      in rec {
        id = "${packageVariant.id},version=${packageVariant.version}" +
          (if packageVariant.chip or null != null then ",chip=${packageVariant.chip}" else "") +
          (if packageVariant.language or null != null then ",language=${packageVariant.language}" else "");
        # map of payloads, fileName -> fetchurl derivation
        payloads = builtins.listToAttrs (map payloadManifest (packageVariant.payloads or []));
        # list of dependencies (package manifests)
        dependencies = pkgs.lib.mapAttrsToList depManifest (pkgs.lib.filterAttrs (_dep: depPred) (packageVariant.dependencies or {}));
        layoutScript = let
          dir = id;
          directories = pkgs.lib.sort (a: b: a < b) (pkgs.lib.unique (
            pkgs.lib.mapAttrsToList (fileName: _payload:
              dirOf "${dir}/${fileName}"
            ) payloads
          ));
          directoriesStr = builtins.concatStringsSep " " (map (directory: pkgs.lib.escapeShellArg directory) directories);
        in ''
          ${if directoriesStr != "" then "mkdir -p ${directoriesStr}" else ""}
          ${builtins.concatStringsSep "" (pkgs.lib.mapAttrsToList (fileName: payload: ''
            ln -s ${payload} ${pkgs.lib.escapeShellArg "${dir}/${fileName}"}
          '') payloads)}
        '';
      };
    in rec {
      id = "${packageId}-${arch}-${language}";
      variants = map packageVariantManifest packageVariants;
      layoutScript = builtins.concatStringsSep "" (map (variant: variant.layoutScript) variants);
    };

    packageManifests = pkgs.lib.mapAttrs packageManifest packages;

    # resolve dependencies and return manifest for set of packages
    resolve = { packageIds, arch, language, includeRecommended ? false, includeOptional ? false }: let
      dfs = package: { visited, packages } @ args: if visited.${package.id} or false
        then args
        else let
          depPackages = pkgs.lib.concatMap (variant: variant.dependencies) package.variants;
          depsResult = pkgs.lib.foldr dfs {
            visited = visited // {
              "${package.id}" = true;
            };
            inherit packages;
          } depPackages;
        in {
          visited = depsResult.visited;
          packages = depsResult.packages ++ [package];
        };
      packages = (pkgs.lib.foldr dfs {
        visited = {};
        packages = [];
      } (map (packageId: packageManifests.${packageId} {
        inherit arch language includeRecommended includeOptional;
      }) (map normalizeVsPackageId (packageIds ++ [product])))).packages;
      vsSetupExe = {
        "Microsoft.VisualStudio.Product.BuildTools" = vsBuildToolsExe;
        "Microsoft.VisualStudio.Product.Community" = vsCommunityExe;
      }.${product};
      layoutJson = pkgs.writeText "layout.json" (builtins.toJSON {
        inherit channelUri;
        channelId = channelManifestJSON.info.manifestName;
        productId = product;
        installChannelUri = ".\\ChannelManifest.json";
        installCatalogUri = ".\\Catalog.json";
        add = map (packageId: "${packageId}${pkgs.lib.optionalString includeRecommended ";includeRecommended"}${pkgs.lib.optionalString includeOptional ";includeOptional"}") packageIds;
        addProductLang = [language];
      });
    in {
      layoutScript = ''
        ${builtins.concatStringsSep "" (map (package: package.layoutScript) packages)}
        ln -s ${channelManifest} ChannelManifest.json
        ln -s ${manifest} Catalog.json
        ln -s ${layoutJson} Layout.json
        ln -s ${layoutJson} Response.json
        ln -s ${vsSetupExe} vs_setup.exe
        ln -s ${vsInstallerExe} vs_installer.opc
      '';
    };

    # bootstrapper (vs_Setup.exe) - not sure what it is for
    # vsSetupExeDesc = builtins.head (pkgs.lib.findSingle (c: c.type == "Bootstrapper") null null channelManifestJSON.channelItems).payloads;
    # vsSetupExe = pkgs.fetchurl {
    #   inherit (vsSetupExeDesc) url sha256;
    # };

    vsBuildToolsExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/vs_buildtools.exe") url sha256 name;
    };

    vsCommunityExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/vs_community.exe") url sha256 name;
    };

    vsInstallerExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/installer") url sha256 name;
    };

    disk = { packageIds, arch ? "x64", language ? "en-US", includeRecommended ? false, includeOptional ? false }: windows.runPackerStep {
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
          type = "windows-shell";
          inline = [
            ("D:\\vslayout\\vs_setup.exe --quiet --wait --noweb --norestart" +
              (builtins.concatStringsSep "" (map (packageId: " --add ${packageId}") packageIds)) +
              (pkgs.lib.optionalString includeRecommended " --includeRecommended") +
              (pkgs.lib.optionalString includeOptional " --includeOptional"))
          ];
        }
      ];
    };

  in {
    inherit packageManifests resolve disk;
  };

  normalizeVsPackageId = pkgs.lib.toLower;

  vsProducts = {
    buildTools = "Microsoft.VisualStudio.Product.BuildTools";
    community = "Microsoft.VisualStudio.Product.Community";
  };
  vsWorkloads = {
    vcTools = "Microsoft.VisualStudio.Workload.VCTools";
    nativeDesktop = "Microsoft.VisualStudio.Workload.NativeDesktop";
    universal = "Microsoft.VisualStudio.Workload.Universal";
  };

  vsDisk = { versionMajor, product, workloads }: (vsPackages {
    inherit versionMajor;
    product = vsProducts."${product}";
  }).disk {
    packageIds = map (workload: vsWorkloads."${workload}") workloads;
    includeRecommended = true;
  };

  vs16BuildToolsCppDisk = vsDisk { versionMajor = 16; product = "buildTools"; workloads = ["vcTools"]; };
  vs15BuildToolsCppDisk = vsDisk { versionMajor = 15; product = "buildTools"; workloads = ["vcTools"]; };
  vs16CommunityCppDisk = vsDisk { versionMajor = 16; product = "community"; workloads = ["nativeDesktop"]; };
  vs15CommunityCppDisk = vsDisk { versionMajor = 15; product = "community"; workloads = ["nativeDesktop"]; };

  fixeds = builtins.fromJSON (builtins.readFile ./fixeds.json);
}
