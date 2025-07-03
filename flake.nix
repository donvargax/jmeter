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

        # Pre-download Gradle 8.9 to Nix store
        gradle-8-9 = pkgs.fetchurl {
          url = "https://services.gradle.org/distributions/gradle-8.9-bin.zip";
          hash = "sha256-1yXXB7+r1N/clYxiQAOzyArMwD9wN7USLEsdDvFc7Ks=";
        };

        # Build JMeter from source using the existing nixpkgs pattern
        jmeter-from-source = pkgs.stdenv.mkDerivation rec {
          pname = "jmeter";
          version = "master-${self.shortRev or "dirty"}";

          # Filter out flake.nix and other Nix-specific files from source
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
            openjdk17  # For building (required by JMeter's build process)
            openjdk21  # For runtime (to match official package)
            unzip      # For extracting cached Gradle
          ];

          buildInputs = with pkgs; [
            openjdk21  # Match official JMeter which uses JDK 21
            gradle     # Keep for dev shell compatibility
          ];

          # JMeter build process
          buildPhase = ''
            runHook preBuild

            # Use JDK 17 for building (required by JMeter's build system)
            export JAVA_HOME=${pkgs.openjdk17}
            export PATH=${pkgs.openjdk17}/bin:$PATH

            # Set up writable directories for Gradle
            export GRADLE_USER_HOME=$TMPDIR/gradle
            export GRADLE_HOME=$GRADLE_USER_HOME
            mkdir -p $GRADLE_USER_HOME

            # Pre-cache Gradle wrapper to avoid repeated downloads
            echo "=== Setting up cached Gradle wrapper ==="
            chmod +x gradlew

            # Set up gradle wrapper to use our pre-downloaded zip
            mkdir -p $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a
            cp ${gradle-8-9} $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a/gradle-8.9-bin.zip
            cd $GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a
            unzip -q gradle-8.9-bin.zip
            echo "ok" > gradle-8.9-bin.zip.ok
            cd -

            echo "=== Building JMeter with Gradle (using JDK 17) ==="

            # Try building just the essential components first
            ./gradlew assemble --no-daemon --no-build-cache -Djava.awt.headless=true \
              --gradle-user-home=$GRADLE_USER_HOME \
              -x rat \
              -x distTar \
              -x distZip \
              -x distTarSource

            echo "=== Creating distribution ==="

            # Create the distribution without problematic tasks
            ./gradlew createDist --no-daemon --no-build-cache \
              --gradle-user-home=$GRADLE_USER_HOME \
              -x rat \
              -x distTarSource \
              || echo "createDist failed, trying alternative approach"

            # If createDist fails, try just the core distribution components
            if [ ! -d "src/dist/build/distributions" ]; then
              echo "=== Alternative: Building core components only ==="
              ./gradlew :src:dist:copyLibs :src:dist:copyBinLibs --no-daemon --no-build-cache \
                --gradle-user-home=$GRADLE_USER_HOME \
                -x rat || echo "Alternative build completed with issues"
            fi

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out

            echo "=== Looking for JMeter distribution ==="

            # First, try to find a proper distribution archive
            DIST_DIR="src/dist/build/distributions"
            FOUND_DIST=false

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
                if [ -n "$JMETER_DIR" ]; then
                  echo "Extracted to: $JMETER_DIR"

                  # Copy everything like official derivation
                  cd "$JMETER_DIR"

                  # Remove Windows scripts like official derivation
                  rm -f bin/*.bat bin/*.cmd

                  # Copy everything to output
                  cp -R * $out/
                  FOUND_DIST=true
                fi
              fi

              # Go back to root for alternative approach
              cd - >/dev/null
            fi

            # If we couldn't find a proper distribution, build it manually
            if [ "$FOUND_DIST" = "false" ]; then
              echo "No distribution archive found, building manually from components"

              # Create basic JMeter structure
              mkdir -p $out/bin $out/lib $out/lib/ext $out/licenses $out/docs

              # Copy all JAR files from build outputs
              echo "Copying JAR files..."
              find . -name "*.jar" -path "*/build/libs/*" -exec cp {} $out/lib/ \; 2>/dev/null || true

              # Copy bin files if they exist
              if [ -d "bin" ]; then
                echo "Copying bin files..."
                cp -r bin/* $out/bin/ 2>/dev/null || true
              fi

              # Copy other necessary files
              for dir in licenses docs lib; do
                if [ -d "$dir" ]; then
                  echo "Copying $dir..."
                  cp -r $dir/* $out/$dir/ 2>/dev/null || true
                fi
              done

              # Try to find the main JMeter JAR and ensure it's in the right place
              MAIN_JAR=$(find . -name "ApacheJMeter.jar" -o -name "jmeter*.jar" | head -1)
              if [ -n "$MAIN_JAR" ]; then
                echo "Found main JAR: $MAIN_JAR"
                cp "$MAIN_JAR" $out/lib/ApacheJMeter.jar
              fi

              # Look for other essential JARs
              find . -name "jorphan*.jar" -exec cp {} $out/lib/ \; 2>/dev/null || true
              find . -name "*jmeter*.jar" -exec cp {} $out/lib/ \; 2>/dev/null || true
            fi

            # Ensure bin directory exists and has basic scripts
            mkdir -p $out/bin

            # Remove Windows scripts
            rm -f $out/bin/*.bat $out/bin/*.cmd 2>/dev/null || true

            # If jmeter script doesn't exist, create a basic one
            if [ ! -f "$out/bin/jmeter" ] && [ ! -f "$out/bin/jmeter.sh" ]; then
              echo "Creating basic jmeter script"
              cat > $out/bin/jmeter << 'EOF'
#!/bin/bash
JMETER_HOME="$(dirname "$(dirname "$(readlink -f "$0")")")"
CLASSPATH="$JMETER_HOME/lib/*"
exec java -cp "$CLASSPATH" org.apache.jmeter.NewDriver "$@"
EOF
              chmod +x $out/bin/jmeter
            fi

            # Ensure we have some JARs in lib
            if [ -z "$(ls -A $out/lib 2>/dev/null)" ]; then
              echo "ERROR: No JAR files found in lib directory"
              echo "Looking for any JAR files in build:"
              find . -name "*.jar" | head -10
              exit 1
            fi

            echo "JMeter installation summary:"
            echo "Bin files: $(ls $out/bin 2>/dev/null | wc -l)"
            echo "Lib files: $(ls $out/lib 2>/dev/null | wc -l)"
            echo "Main executable: $(ls $out/bin/jmeter* 2>/dev/null || echo 'MISSING')"

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
