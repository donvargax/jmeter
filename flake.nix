{
  description = "Apache JMeter from source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Build JMeter from source using the existing nixpkgs pattern
        jmeter-from-source = pkgs.stdenv.mkDerivation rec {
          pname = "jmeter";
          version = "master-${self.shortRev or "dirty"}";

          src = self;

          nativeBuildInputs = with pkgs; [
            makeWrapper
            ant
            openjdk17
          ];

          buildInputs = with pkgs; [
            openjdk17
          ];

          # JMeter build process
          buildPhase = ''
            runHook preBuild

            export JAVA_HOME=${pkgs.openjdk17}
            export ANT_HOME=${pkgs.ant}

            # Download dependencies and build
            ant download_jars
            ant

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/{bin,lib,share/jmeter}

            # Copy the built JMeter
            cp -r bin/ $out/share/jmeter/
            cp -r lib/ $out/share/jmeter/
            cp -r extras/ $out/share/jmeter/
            cp -r docs/ $out/share/jmeter/
            cp -r printable_docs/ $out/share/jmeter/ || true
            cp -r licenses/ $out/share/jmeter/
            cp LICENSE $out/share/jmeter/
            cp README.md $out/share/jmeter/

            # Create wrapper script
            makeWrapper ${pkgs.openjdk17}/bin/java $out/bin/jmeter \
              --add-flags "-jar $out/share/jmeter/bin/ApacheJMeter.jar" \
              --set JAVA_HOME "${pkgs.openjdk17}" \
              --set JMETER_HOME "$out/share/jmeter"

            # Also create jmeter-server wrapper
            makeWrapper ${pkgs.openjdk17}/bin/java $out/bin/jmeter-server \
              --add-flags "-jar $out/share/jmeter/bin/ApacheJMeter.jar" \
              --add-flags "-s" \
              --set JAVA_HOME "${pkgs.openjdk17}" \
              --set JMETER_HOME "$out/share/jmeter"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Apache JMeter (from source)";
            longDescription = ''
              Apache JMeter is a 100% pure Java application designed to load test
              functional behavior and measure performance. This version is built
              from the latest source code.
            '';
            homepage = "https://jmeter.apache.org/";
            license = licenses.asl20;
            maintainers = [ ];
            platforms = platforms.unix;
            mainProgram = "jmeter";
          };
        };
      in
      {
        packages = {
          default = jmeter-from-source;
          jmeter = jmeter-from-source;
        };

        apps = {
          default = flake-utils.lib.mkApp {
            drv = jmeter-from-source;
            name = "jmeter";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            openjdk17
            ant
            gradle
          ];

          shellHook = ''
            echo "JMeter development environment"
            echo "Java: $(java -version 2>&1 | head -n1)"
            echo "Ant: $(ant -version | head -n1)"
          '';
        };
      });
}
