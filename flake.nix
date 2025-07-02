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
            openjdk21  # Match official JMeter which uses JDK 21
          ];

          buildInputs = with pkgs; [
            openjdk21  # Match official JMeter which uses JDK 21
          ];

          # JMeter build process
          buildPhase = ''
            runHook preBuild

            export JAVA_HOME=${pkgs.openjdk21}

            echo "=== Building JMeter with Gradle ==="
            chmod +x gradlew
            ./gradlew build --no-daemon --no-build-cache -Djava.awt.headless=true

            echo "=== Creating distribution ==="
            ./gradlew createDist --no-daemon --no-build-cache

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out

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

                # Copy everything like official derivation
                cd "$JMETER_DIR"

                # Remove Windows scripts like official derivation
                rm -f bin/*.bat bin/*.cmd

                # Copy everything to output
                cp -R * $out/
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

            # Fix keytool path like official derivation
            if [ -f "$out/bin/create-rmi-keystore.sh" ]; then
              substituteInPlace $out/bin/create-rmi-keystore.sh --replace \
                "keytool -genkey" \
                "${pkgs.openjdk21}/bin/keytool -genkey"
            fi

            # Prefix scripts with jmeter like official derivation
            for i in heapdump.sh mirror-server mirror-server.sh shutdown.sh stoptest.sh create-rmi-keystore.sh; do
              if [ -f "$out/bin/$i" ]; then
                mv $out/bin/$i $out/bin/jmeter-$i
                wrapProgram $out/bin/jmeter-$i \
                  --prefix PATH : "${pkgs.openjdk21}/bin"
              fi
            done

            # Wrap main jmeter scripts like official derivation
            if [ -f "$out/bin/jmeter" ]; then
              wrapProgram $out/bin/jmeter --set JAVA_HOME "${pkgs.openjdk21}"
            fi
            if [ -f "$out/bin/jmeter.sh" ]; then
              wrapProgram $out/bin/jmeter.sh --set JAVA_HOME "${pkgs.openjdk21}"
            fi

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
            openjdk21  # Match official JMeter
            gradle
          ];

          shellHook = ''
            echo "JMeter development environment"
            echo "Java: $(java -version 2>&1 | head -n1)"
            echo "Gradle: $(gradle --version | head -n1)"
          '';
        };
      });
}
