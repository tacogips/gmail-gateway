{
  description = "mail-gateway Swift development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        version = lib.removeSuffix "\n" (builtins.readFile ./VERSION);

        commandNames = [
          "mail-gateway-reader"
          "mail-gateway-draft"
          "mail-gateway-sender"
        ];

        runtimePackages =
          with pkgs;
          [
            gh
            git
            go-task
            swiftlint
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [
            swift
          ];

        devOnlyPackages = with pkgs; [
          gitleaks
        ];

        preCommitCheck = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            gitleaks = {
              enable = true;
              name = "gitleaks";
              entry = "${pkgs.lib.getExe pkgs.gitleaks} git --pre-commit --redact --staged --verbose";
              language = "system";
              pass_filenames = false;
            };
          };
        };

        devPackages = runtimePackages ++ devOnlyPackages ++ preCommitCheck.enabledPackages;

        buildSwiftCommand =
          commandName:
          pkgs.stdenvNoCC.mkDerivation {
            pname = commandName;
            inherit version;
            src = lib.cleanSource ./.;

            nativeBuildInputs = lib.optionals pkgs.stdenv.isLinux [
              pkgs.swift
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              export XDG_CACHE_HOME="$TMPDIR/xdg-cache"
              export XDG_CONFIG_HOME="$TMPDIR/xdg-config"
              mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

              cp -R "$src" source
              chmod -R u+w source
              cd source

              if [ -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift ]; then
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
                export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
                export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
                export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
              fi

              swift build --disable-sandbox -c release --product ${lib.escapeShellArg commandName}
              bin_path="$(swift build --disable-sandbox -c release --product ${lib.escapeShellArg commandName} --show-bin-path)"

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin"
              cp "$bin_path/${commandName}" "$out/bin/${commandName}"

              runHook postInstall
            '';
          };

        commandPackages = lib.genAttrs commandNames buildSwiftCommand;
      in
      {
        packages =
          commandPackages
          // {
            default = commandPackages.mail-gateway-reader;
            dev-tools = pkgs.buildEnv {
              name = "mail-gateway-dev-tools";
              paths = devPackages;
              pathsToLink = [ "/bin" ];
            };
          };

        apps =
          lib.mapAttrs
            (commandName: package: {
              type = "app";
              program = "${package}/bin/${commandName}";
            })
            commandPackages
          // {
            default = {
              type = "app";
              program = "${commandPackages.mail-gateway-reader}/bin/mail-gateway-reader";
            };
          };

        checks.pre-commit-check = preCommitCheck;

        devShells.default = pkgs.mkShell {
          packages = devPackages;

          shellHook = ''
            ${preCommitCheck.shellHook}

            echo "mail-gateway Swift development environment ready"
            echo "Swift version: $(swift --version 2>/dev/null | head -n 1 || echo 'not available')"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
            echo "SwiftLint version: $(swiftlint version 2>/dev/null || echo 'not available')"
            echo "Gitleaks version: $(gitleaks version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
