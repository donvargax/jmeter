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
            echo "Building JMeter with: ./gradlew createDist"

            # Follow the official instructions exactly:
            # ./gradlew createDist
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

            echo "=== Installing JMeter from official createDist output ==="

            # According to official docs, createDist copies all dependencies to lib/
            # and sets up the complete JMeter installation in the current directory

            # The createDist task creates a complete JMeter installation structure
            # in the source directory itself, as mentioned in the official docs:
            # "The following command would compile the application and enable you to
            # run jmeter from the bin directory"

            # Check if we have the expected JMeter structure
            if [ ! -d "bin" ] || [ ! -d "lib" ]; then
              echo "ERROR: Expected bin/ and lib/ directories not found after createDist"
              echo "Available directories:"
              ls -la
              exit 1
            fi

            echo "Found JMeter installation structure:"
            echo "Bin directory contents:"
            ls -la bin/
            echo "Lib directory contents (first 10):"
            ls lib/ | head -10

            # Copy the complete JMeter installation
            cp -R bin lib $out/

            # Copy other directories if they exist
            for dir in docs extras licenses printable_docs; do
              if [ -d "$dir" ]; then
                cp -R "$dir" $out/
              fi
            done

            # Remove Windows scripts
            rm -f $out/bin/*.bat $out/bin/*.cmd

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
          ];

          shellHook = ''
            echo "JMeter development environment (official build instructions)"
            echo "Build JDK: $(${pkgs.openjdk17}/bin/java -version 2>&1 | head -n1)"
            echo "Runtime JDK: $(${pkgs.openjdk21}/bin/java -version 2>&1 | head -n1)"
            echo ""
            echo "Official build commands:"
            echo "  ./gradlew build                    # Build and test"
            echo "  ./gradlew createDist               # Create distribution"
            echo "  ./gradlew runGui                   # Build and start GUI"
            echo "  ./gradlew build -Djava.awt.headless=true  # Headless build"
          '';
        };
      });
}
