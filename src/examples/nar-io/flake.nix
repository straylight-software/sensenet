{
  description = "nar.io - Nix Binary Cache Landing Site + Admin Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-shell = {
      url = "github:aciceri/agenix-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      purescript-overlay,
      agenix,
      agenix-shell,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ purescript-overlay.overlays.default ];
        pkgs = import nixpkgs { inherit system overlays; };

        # Scan secrets directory for .age files
        secretsDir = ./secrets/secrets;

        isAgeFile = name: builtins.match ".*\\.age$" name != null;

        sanitizeName =
          file: builtins.replaceStrings [ ".age" "-" "." " " ] [ "" "_" "_" "_" ] file |> pkgs.lib.toUpper;

        scanSecrets =
          dir:
          let
            contents = builtins.readDir dir;
            processFile =
              name: type:
              if type == "regular" && isAgeFile name then
                [
                  {
                    name = sanitizeName name;
                    value.file = dir + "/${name}";
                  }
                ]
              else if type == "directory" then
                scanSecrets (dir + "/${name}")
              else
                [ ];
          in
          builtins.concatLists (pkgs.lib.mapAttrsToList processFile contents);

        agenixSecrets =
          if builtins.pathExists secretsDir then builtins.listToAttrs (scanSecrets secretsDir) else { };

        # Generate shell hook that exports decrypted secrets
        secretsShellHook = agenix-shell.lib.installationScript system {
          secrets = agenixSecrets;
        };

        # PureScript build - using FOD for network access
        pursOutput = pkgs.stdenv.mkDerivation {
          name = "nar-io-purs";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            purescript
            spago-unstable
            esbuild
            nodejs_20
            git
            cacert
          ];

          # Allow network access for spago to fetch registry
          __noChroot = true;
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          buildPhase = ''
            export HOME=$TMPDIR
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

            # Fetch and build
            spago build

            # Bundle with esbuild
            esbuild output/Main/index.js \
              --bundle \
              --minify \
              --format=esm \
              --outfile=main.js
          '';

          installPhase = ''
            mkdir -p $out
            cp main.js $out/
          '';
        };

        # CSS build - use tailwindcss directly, skip npm
        cssOutput = pkgs.stdenv.mkDerivation {
          name = "nar-io-css";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            nodejs_20
            tailwindcss
          ];

          # Allow network for any postcss plugins
          __noChroot = true;

          buildPhase = ''
            export HOME=$TMPDIR
            tailwindcss -i ./src/styles.css -o styles.css --minify
          '';

          installPhase = ''
            mkdir -p $out
            cp styles.css $out/
          '';
        };

        # Final site
        site = pkgs.stdenv.mkDerivation {
          name = "nar-io-site";
          src = ./public;

          buildPhase = ''
            mkdir -p $out
            cp -r $src/* $out/
            cp ${pursOutput}/main.js $out/
            cp ${cssOutput}/styles.css $out/
          '';

          installPhase = "true";
        };

      in
      {
        packages = {
          default = site;
          purs = pursOutput;
          css = cssOutput;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # PureScript
            purescript
            spago-unstable
            purs-tidy

            # Node/JS
            nodejs_20
            nodePackages.npm
            esbuild

            # Secrets management
            agenix.packages.${system}.default
            age
            rage
            ssh-to-age

            # Dev tools
            just
            watchexec
            direnv
          ];

          shellHook = ''
            echo "> nar.io dev shell"
            echo ""

            # Export decrypted secrets as environment variables
            ${secretsShellHook}

            echo "Commands:"
            echo "  nix build        - Build the site"
            echo "  nix run          - Build and serve locally"
            echo "  spago build      - Compile PureScript"
            echo "  npm run dev      - Start Vite dev server"
            echo ""
            echo "Secrets:"
            echo "  agenix -e secrets/secrets/<name>.age  - Edit a secret"
            echo "  agenix -r secrets/secrets.nix         - Rekey all secrets"
            echo ""
          '';
        };

        # Secrets management shell
        devShells.secrets = pkgs.mkShell {
          name = "nar-io-secrets";

          buildInputs = with pkgs; [
            agenix.packages.${system}.default
            age
            rage
            ssh-to-age
            jq
          ];

          shellHook = ''
            echo "> nar.io secrets shell"
            echo ""
            echo "Commands:"
            echo "  agenix -e secrets/secrets/<name>.age  - Edit/create a secret"
            echo "  agenix -r secrets/secrets.nix         - Rekey all secrets"
            echo ""
            cd secrets 2>/dev/null || true
          '';
        };

        apps = {
          # nix run — serve built site
          default = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "serve-nar-io" ''
                echo "> nar.io // serving on http://localhost:8000"
                ${pkgs.python3}/bin/python -m http.server 8000 -d ${site}
              ''
            );
          };

          # nix run .#preview — build and serve with vite
          preview =
            let
              previewScript = pkgs.writeShellApplication {
                name = "preview-nar-io";
                runtimeInputs = with pkgs; [
                  purescript
                  spago-unstable
                  esbuild
                  nodejs_20
                ];
                text = ''
                  echo "> nar.io // preview"
                  echo ""

                  echo "// spago build"
                  spago build

                  echo "// esbuild bundle"
                  esbuild output/Main/index.js \
                    --bundle \
                    --format=esm \
                    --outfile=public/main.js

                  echo "// tailwind"
                  npx tailwindcss -i ./src/styles.css -o ./public/styles.css

                  echo ""
                  echo "// vite on http://localhost:3000"
                  npx vite --port 3000
                '';
              };
            in
            {
              type = "app";
              program = "${previewScript}/bin/preview-nar-io";
            };
        };
      }
    );
}
