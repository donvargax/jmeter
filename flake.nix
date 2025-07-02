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
            openjdk17
          ];

          buildInputs = with pkgs; [
            openjdk17
          ];

          # JMeter build process
          buildPhase = ''
            runHook preBuild

            export JAVA_HOME=${pkgs.openjdk17}

            echo "=== Building JMeter with Gradle ==="
            chmod +x gradlew
            ./gradlew build --no-daemon --no-build-cache -Djava.awt.headless=true

            echo "=== Creating distribution ==="
            ./gradlew createDist --no-daemon --no-build-cache

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/{bin,share/jmeter}

            echo "=== Looking for JMeter distribution ==="
            DIST_DIR="src/dist/build/distributions"

            if [ -d "$DIST_DIR" ]; then
              echo "Found distribution directory: $DIST_DIR"
              cd $DIST_DIR

              # Look for the distribution archive
              DIST_FILE=$(ls apache-jmeter-*.tgz 2>/dev/null | head -1)
              if [ -z "$DIST_FILE" ]; then
                DIST_FILE=$(ls apache-jmeter-*.tar.gz 2>/dev/null | head -1)
              fi

              if [ -n "$DIST_FILE" ]; then
                echo "Found distribution: $DIST_FILE"
                tar -xzf "$DIST_FILE"
                JMETER_DIR=$(ls -d apache-jmeter-*/ | head -1)
                echo "Extracted to: $JMETER_DIR"
                cp -r "$JMETER_DIR"* $out/share/jmeter/
              else
                echo "No distribution archive found in $DIST_DIR"
                ls -la
                exit 1
              fi
            else
              echo "Distribution directory not found: $DIST_DIR"
              echo "Available directories in src/dist/build:"
              ls -la src/dist/build/ || echo "src/dist/build/ not found"
              exit 1
            fi

            # Verify JMeter was installed correctly
            if [ ! -f "$out/share/jmeter/bin/ApacheJMeter.jar" ]; then
              echo "ApacheJMeter.jar not found, checking what was installed:"
              find $out/share/jmeter -name "*.jar" | head -10
              exit 1
            fi

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
