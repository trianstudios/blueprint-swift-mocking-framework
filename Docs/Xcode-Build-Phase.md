# Xcode build phase

A Run Script phase can generate Blueprint Swift mocks for a selected native target. These instructions use one explicitly supplied Swift source module, one configuration file, and a prepared host generator. The native fixture exercises this setup on arm64 macOS 27.0.1 with Xcode 27.0 (27A266a), Swift 6 language mode, and a macOS 13 deployment target.

The source module must be available to the mock target as an ordinary Swift dependency. Link the BlueprintMocking runtime to the mock target. Prepare the host generator before building that target. The phase invokes the generator directly and publishes two Swift files from its schema 1 configuration. Scope the configuration's selections to the supplied source module.

## Install in one target

1. Copy [the phase script](../scripts/xcode/blueprint-build-phase.sh) into your project and prepare the host executable at a known absolute path. If the executable uses the selected toolchain's bundled SwiftParser and SwiftSyntax, declare both dylibs as phase inputs.
2. In an authored input `.xcfilelist`, add the list itself, the phase script, host executable, schema 1 configuration, and each `.swift` source supplied to the generator. Xcode expands build settings in these entries. The native fixture uses the following list.

   ~~~text
   $(SRCROOT)/Source Lists/BlueprintInputs.xcfilelist
   $(SRCROOT)/Services/Lookup.swift
   $(SRCROOT)/blueprint-mocking.json
   $(SRCROOT)/Tools/Run Génération.sh
   $(SRCROOT)/Tools/blueprint-generate
   $(TOOLCHAIN_DIR)/usr/lib/swift/host/libSwiftParser.dylib
   $(TOOLCHAIN_DIR)/usr/lib/swift/host/libSwiftSyntax.dylib
   ~~~

3. Create the output `.xcfilelist` with exactly these two entries.

   ~~~text
   $(TARGET_TEMP_DIR)/Blueprint/BlueprintMocks.generated.swift
   $(TARGET_TEMP_DIR)/Blueprint/BlueprintMockingIndex.generated.swift
   ~~~

4. Before **Compile Sources**, add a single Run Script phase named **Blueprint Mocking**. Attach the input and output lists in **Input File Lists** and **Output File Lists**. Enable **Based on dependency analysis** and keep `ENABLE_USER_SCRIPT_SANDBOXING` enabled. Set the source module and quote the paths. Xcode provides `TARGET_TEMP_DIR`, `SCRIPT_INPUT_FILE_LIST_COUNT`, `SCRIPT_INPUT_FILE_LIST_0`, `SCRIPT_OUTPUT_FILE_LIST_COUNT` and `SCRIPT_OUTPUT_FILE_LIST_0`.

   ~~~sh
   BLUEPRINT_MOCKING_SOURCE_MODULE=PhaseDomain \
   BLUEPRINT_MOCKING_TOOL="$SRCROOT/Tools/blueprint-generate" \
   BLUEPRINT_MOCKING_CONFIG="$SRCROOT/blueprint-mocking.json" \
   /bin/bash "$SRCROOT/Tools/Run Génération.sh"
   ~~~

5. Add both generated Swift file references to **Compile Sources**. In the project file, create one `PBXFileReference` with `sourceTree = TARGET_TEMP_DIR` and `path = "Blueprint/<file name>"` for each output, and add the two corresponding `PBXBuildFile` identifiers to the target's existing `PBXSourcesBuildPhase`. Keep user phase objects and their order. On setup again verify that the one Blueprint phase, two references, and two build file entries already exist. [The reviewed native fixture patch](../Fixtures/XcodePhaseProbe/install-phase.patch) shows the exact project changes.

`TARGET_TEMP_DIR/Blueprint` is a target-specific intermediate under DerivedData. Xcode 27.0's script sandbox permitted the generator's publication journal and temporary files there. The two Swift paths are the declared outputs. The same sandbox refused access to an undeclared input and a write into the authored project. The phase leaves project files untouched. Ordinary Xcode derived-data cleanup applies to its intermediates.

Update the authored input file list when the supplied source membership changes. The generator fingerprints the explicit module and paths and updates the generated index when entries are added or removed. Automatic membership discovery from project metadata, multiple configurations and schemes, conditional compiler context, and Objective-C setup are separate qualification work.

## Run the native fixture

Set `BLUEPRINT_VERIFY_XCODE_PHASE=1` when running the main verifier to include this fixture.

Prepare the native host generator and an arm64 `BlueprintMocking.o` plus `BlueprintMocking.swiftmodule` with the selected Xcode. This optional fixture reuses those prepared artifacts and invokes the actual generator inside Xcode. It compiles the small fixture domain, builds the original macOS project with script sandboxing, and runs its generated/mock-dependent executable.

~~~sh
python3 Fixtures/XcodePhaseProbe/verify.py \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --tool .build/prototype-tooling/generate \
  --runtime-products .build/out/Products/Debug \
  --evidence-dir .build/xcode-phase-evidence
~~~
