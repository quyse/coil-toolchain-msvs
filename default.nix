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
      packageVariantPred = packageVariant: let
        chipPred = !(packageVariant ? chip) || packageVariant.chip == "neutral" || packageVariant.chip == arch;
      in
        (if packageVariant ? productArch
          then pkgs.lib.toLower packageVariant.productArch == "neutral" || pkgs.lib.toLower packageVariant.productArch == arch || chipPred
          else chipPred
        ) &&
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
            meta = {
              # presuming everything from MS to be unfree
              license = pkgs.lib.licenses.unfree;
            };
          });
        depPred = depDesc:
          builtins.typeOf depDesc != "set" ||
          (!(depDesc ? type) ||
            (includeRecommended && depDesc.type == "Recommended") ||
            (includeOptional && depDesc.type == "Optional")) &&
          (!(depDesc ? when) || pkgs.lib.any (p: p == product) depDesc.when);
        depManifest = depPackageId: depDesc: packageManifests."${normalizeVsPackageId depPackageId}" {
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
    };

    packageManifests = pkgs.lib.mapAttrs packageManifest packages;

    # resolve dependencies and return manifest for set of packages
    resolve = { packageIds, arch, language, includeRecommended ? false, includeOptional ? false }: let
      dfsPackage = package: state: pkgs.lib.foldr dfsPackageVariant state package.variants;
      dfsPackageVariant = packageVariant: { visited, ... } @ state: if visited."${packageVariant.id}" or false
        then state
        else let
          depsResult = pkgs.lib.foldr dfsPackage (state // {
            visited = visited // {
              "${packageVariant.id}" = true;
            };
          }) packageVariant.dependencies;
        in state // {
          inherit (depsResult) visited;
          packageVariants = depsResult.packageVariants ++ [packageVariant];
        };
      packageVariants = (pkgs.lib.foldr dfsPackage {
        visited = {};
        packageVariants = [];
      } (map (packageId: packageManifests."${normalizeVsPackageId packageId}" {
        inherit arch language includeRecommended includeOptional;
      }) (packageIds ++ [product]))).packageVariants;
      vsSetupExe = {
        "Microsoft.VisualStudio.Product.BuildTools" = vsBuildToolsExe;
        "Microsoft.VisualStudio.Product.Community" = vsCommunityExe;
      }."${product}";
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
        ${builtins.concatStringsSep "" (map (packageVariant: packageVariant.layoutScript) packageVariants)}
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
      meta = {
        license = pkgs.lib.licenses.unfree;
      };
    };

    vsCommunityExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/vs_community.exe") url sha256 name;
      meta = {
        license = pkgs.lib.licenses.unfree;
      };
    };

    vsInstallerExe = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${uriPrefix}/installer") url sha256 name;
      meta = {
        license = pkgs.lib.licenses.unfree;
      };
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
            "D:\\vslayout\\vs_setup.exe --quiet --wait --noWeb --noUpdateInstaller --norestart"
          ];
          valid_exit_codes = [
            0
            3010 # success but reboot required
          ];
        }
      ];
      meta = {
        license = pkgs.lib.licenses.unfree;
      };
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

  vsDisk = { versionMajor, versionPreview ? false, product, workloads }: (vsPackages {
    inherit versionMajor versionPreview;
    product = vsProducts."${product}";
  }).disk {
    packageIds = map (workload: vsWorkloads."${workload}") workloads;
    includeRecommended = true;
  };

  vs17BuildToolsCppDisk = vsDisk { versionMajor = 17; versionPreview = true; product = "buildTools"; workloads = ["vcTools"]; };
  vs16BuildToolsCppDisk = vsDisk { versionMajor = 16; product = "buildTools"; workloads = ["vcTools"]; };
  vs15BuildToolsCppDisk = vsDisk { versionMajor = 15; product = "buildTools"; workloads = ["vcTools"]; };
  vs17CommunityCppDisk = vsDisk { versionMajor = 17; versionPreview = true; product = "community"; workloads = ["nativeDesktop"]; };
  vs16CommunityCppDisk = vsDisk { versionMajor = 16; product = "community"; workloads = ["nativeDesktop"]; };
  vs15CommunityCppDisk = vsDisk { versionMajor = 15; product = "community"; workloads = ["nativeDesktop"]; };

  fixeds = pkgs.lib.importJSON ./fixeds.json;

  touch = {
    inherit
      vs17BuildToolsCppDisk
      vs16BuildToolsCppDisk
      vs15BuildToolsCppDisk
      # vs17CommunityCppDisk # does not work yet
      vs16CommunityCppDisk
      vs15CommunityCppDisk
    ;
  };
}
