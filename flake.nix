{
  description = "Apache JMeter from source - Following official build instructions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Pre-download Gradle 8.9 to Nix store for caching
        gradle-8-9 = pkgs.fetchurl {
          url = "https://services.gradle.org/distributions/gradle-8.9-bin.zip";
          hash = "sha256-1yXXB7+r1N/clYxiQAOzyArMwD9wN7USLEsdDvFc7Ks=";
        };

        # JMeter built following official instructions
        jmeter-official = pkgs.stdenv.mkDerivation rec {
          pname = "jmeter";
          version = "master-${self.shortRev or "dirty"}";

          src = pkgs.lib.cleanSourceWith {
            src = self;
            filter = path: type:
              let baseName = baseNameOf path; in
              !(pkgs.lib.hasSuffix ".nix" baseName) &&
              !(baseName == "result") &&
              !(baseName == ".git") &&
              !(baseName == ".gitignore");
          };

          nativeBuildInputs = with pkgs; [
            makeWrapper
            openjdk17  # For building (as per official docs)
            unzip      # For Gradle cache
          ];

          buildInputs = with pkgs; [
            openjdk21  # For runtime
          ];

          buildPhase = ''
            runHook preBuild

            # Use JDK 17 for building as per official instructions
            export JAVA_HOME=${pkgs.openjdk17}
            export PATH=${pkgs.openjdk17}/bin:$PATH

            # Set up Gradle cache directory
            export GRADLE_USER_HOME=$TMPDIR/gradle
            mkdir -p $GRADLE_USER_HOME

            # Cache Gradle wrapper to avoid repeated downloads
            echo "=== Setting up cached Gradle wrapper ==="
            chmod +x gradlew

            # Set up gradle wrapper cache
            mkdir -p $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a
            cp ${gradle-8-9} $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a/gradle-8.9-bin.zip
            cd $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a
            unzip -q gradle-8.9-bin.zip
            echo "ok" > gradle-8.9-bin.zip.ok
            cd -

            echo "=== Following official JMeter build instructions ==="
            echo "Building JMeter with: ./gradlew createDist -Djava.awt.headless=true"

            # Follow the official instructions exactly:
            # ./gradlew createDist
            # with headless flag since we're in a build environment
            ./gradlew createDist \
              -Djava.awt.headless=true \
              --no-daemon \
              --gradle-user-home=$GRADLE_USER_HOME \
              --stacktrace

            echo "=== Build completed successfully ==="

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out

            echo "=== Installing JMeter from build output ==="

            # The createDist task completed successfully, but let's find where the artifacts are
            echo "Looking for distribution directories and files..."

            # Check multiple possible locations
            DIST_DIR=""
            for potential_dir in "src/dist/build/distributions" "build/distributions" "src/dist/build" "build"; do
              if [ -d "$potential_dir" ]; then
                echo "Found directory: $potential_dir"
                ls -la "$potential_dir"

                # Look for distribution files in this directory
                if ls "$potential_dir"/*jmeter*.{tgz,tar.gz,zip} 2>/dev/null; then
                  DIST_DIR="$potential_dir"
                  echo "Found distribution files in: $DIST_DIR"
                  break
                fi
              fi
            done

            # If no distribution found, look for the built library structure
            if [ -z "$DIST_DIR" ]; then
              echo "No distribution archive found. Looking for direct build output..."

              # Check if we have built JARs and can construct JMeter manually
              JAR_COUNT=$(find . -name "*.jar" -path "*/build/libs/*" | wc -l)
              echo "Found $JAR_COUNT built JAR files"

              if [ "$JAR_COUNT" -gt 5 ]; then
                echo "Sufficient JARs found. Installing JMeter manually from build output..."

                # Create JMeter directory structure
                mkdir -p $out/{bin,lib,lib/ext}

                # Copy all built JARs
                find . -name "*.jar" -path "*/build/libs/*" -exec cp {} $out/lib/ \;

                # Copy essential files from source if they exist
                if [ -d "bin" ]; then
                  cp -r bin/* $out/bin/ 2>/dev/null || true
                  rm -f $out/bin/*.bat $out/bin/*.cmd 2>/dev/null || true
                fi

                if [ -d "lib" ]; then
                  cp -r lib/* $out/lib/ 2>/dev/null || true
                fi

                # Create basic jmeter startup script if none exists
                if [ ! -f "$out/bin/jmeter" ] && [ ! -f "$out/bin/jmeter.sh" ]; then
                  echo "Creating basic jmeter script"
                  cat > $out/bin/jmeter << 'EOF'
#!/bin/bash
JMETER_HOME="$(dirname "$(dirname "$(readlink -f "$0")")")"
CLASSPATH="$JMETER_HOME/lib/*:$JMETER_HOME/lib/ext/*"
exec java -cp "$CLASSPATH" org.apache.jmeter.NewDriver "$@"
EOF
                  chmod +x $out/bin/jmeter
                fi

                echo "Manual installation completed"
              else
                echo "ERROR: Insufficient JAR files found. Build may have failed."
                echo "Available JARs:"
                find . -name "*.jar" | head -10
                exit 1
              fi
            fi

            cd "$DIST_DIR"
            echo "Found distribution directory with files:"
            ls -la

            # Look for distribution archive
            DIST_FILE=""
            for ext in tgz tar.gz zip; do
              DIST_FILE=$(ls apache-jmeter-*.$ext 2>/dev/null | head -1)
              if [ -n "$DIST_FILE" ]; then
                echo "Found distribution file: $DIST_FILE"
                break
              fi
            done

            if [ -z "$DIST_FILE" ]; then
              echo "ERROR: No distribution archive found"
              echo "Available files:"
              ls -la
              exit 1
            fi

            # Extract distribution
            case "$DIST_FILE" in
              *.tar.gz|*.tgz)
                tar -xzf "$DIST_FILE"
                ;;
              *.zip)
                unzip -q "$DIST_FILE"
                ;;
            esac

            # Find extracted directory
            JMETER_DIR=$(ls -d apache-jmeter-*/ 2>/dev/null | head -1)
            if [ -z "$JMETER_DIR" ]; then
              echo "ERROR: Could not find extracted JMeter directory"
              ls -la
              exit 1
            fi

            echo "Installing from: $JMETER_DIR"
            cd "$JMETER_DIR"

            # Remove Windows scripts (following nixpkgs jmeter pattern)
            rm -f bin/*.bat bin/*.cmd

            # Copy everything to output
            cp -R * $out/

            # Fix keytool path for create-rmi-keystore.sh if it exists
            if [ -f "$out/bin/create-rmi-keystore.sh" ]; then
              substituteInPlace $out/bin/create-rmi-keystore.sh --replace \
                "keytool -genkey" \
                "${pkgs.openjdk21}/bin/keytool -genkey"
            fi

            # Prefix utility scripts with jmeter- (following nixpkgs pattern)
            for script in heapdump.sh mirror-server mirror-server.sh shutdown.sh stoptest.sh create-rmi-keystore.sh; do
              if [ -f "$out/bin/$script" ]; then
                mv "$out/bin/$script" "$out/bin/jmeter-$script"
                wrapProgram "$out/bin/jmeter-$script" \
                  --prefix PATH : "${pkgs.openjdk21}/bin"
              fi
            done

            # Wrap main jmeter executables with JDK 21
            for script in jmeter jmeter.sh; do
              if [ -f "$out/bin/$script" ]; then
                wrapProgram "$out/bin/$script" \
                  --set JAVA_HOME "${pkgs.openjdk21}"
              fi
            done

            echo "=== Installation completed successfully ==="
            echo "JMeter installed to: $out"
            echo "Main executable: $out/bin/jmeter"
            echo "JAR files: $(find $out/lib -name "*.jar" 2>/dev/null | wc -l)"
            echo "Bin files: $(find $out/bin -type f 2>/dev/null | wc -l)"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Apache JMeter built from source using official instructions";
            longDescription = ''
              Apache JMeter is a 100% pure Java application designed to load test
              functional behavior and measure performance. This version is built
              from the latest source code following the official build instructions.
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
          default = jmeter-official;
          jmeter = jmeter-official;
        };

        apps = {
          default = flake-utils.lib.mkApp {
            drv = jmeter-official;
            name = "jmeter";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            openjdk17  # Build JDK
            openjdk21  # Runtime JDK
            gradle
          ];

          shellHook = ''
            echo "JMeter development environment (official build instructions)"
            echo "Build JDK: $(${pkgs.openjdk17}/bin/java -version 2>&1 | head -n1)"
            echo "Runtime JDK: $(${pkgs.openjdk21}/bin/java -version 2>&1 | head -n1)"
            echo ""
            echo "Official build commands:"
            echo "  ./gradlew build                    # Build and test"
            echo "  ./gradlew createDist               # Create distribution"
            echo "  ./gradlew build -Djava.awt.headless=true  # Headless build"
          '';
        };
      });
}
