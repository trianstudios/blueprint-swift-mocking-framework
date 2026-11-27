import Foundation

struct IncompatibleImporterContext: Error, CustomStringConvertible {
    let path: String
    let reason: String

    var description: String {
        "\(path):1:1: error: BPM005: \(reason). Supply a compatible public Swift interface and importer context, "
            + "or use the protocol source or an adapter."
    }
}

struct InterfaceImporterContext: Codable {
    struct SDK: Codable, Equatable {
        let name: String
        let version: String
    }

    let schemaVersion: Int
    let compilerIdentity: String
    let targetTriple: String
    let swiftLanguageMode: String
    let defaultActorIsolation: String
    let upcomingFeatures: [String]
    let experimentalFeatures: [String]
    let objcInterop: Bool
    let sdk: SDK?
}

struct ImportedInterfaceInput {
    struct Inspection: Encodable {
        let module: String
        let path: String
        let interfaceFormatVersion: String
        let importer: InterfaceImporterContext
        let unavailableProducerContext: [String]
    }

    let module: String
    let path: String
    let text: String
    let context: InterfaceImporterContext
    let unavailableProducerContext: [String]
    let contextText: String
    let interfaceFormatVersion: String

    init(module: String, path: String, contextPath: String) throws {
        func incompatible(_ reason: String) -> IncompatibleImporterContext {
            IncompatibleImporterContext(path: path, reason: reason)
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "swiftinterface",
              !url.lastPathComponent.hasSuffix(".private.swiftinterface"),
              !url.lastPathComponent.hasSuffix(".package.swiftinterface") else {
            throw incompatible("Expected a public .swiftinterface file")
        }
        let contextSource: String
        let importer: InterfaceImporterContext
        do {
            contextSource = try String(contentsOfFile: contextPath, encoding: .utf8)
            importer = try JSONDecoder().decode(InterfaceImporterContext.self, from: Data(contextSource.utf8))
        } catch {
            throw incompatible("Cannot read a versioned importer context from \(contextPath): \(error)")
        }
        guard importer.schemaVersion == 1, !importer.compilerIdentity.isEmpty,
              importer.targetTriple.contains("-apple-macosx") else {
            throw incompatible("This interface profile requires importer context schema 1 and a macOS target triple")
        }
        guard importer.swiftLanguageMode == "6" else {
            throw incompatible("Swift language mode must be 6 in this interface profile")
        }
        guard importer.defaultActorIsolation == "nonisolated" else {
            throw incompatible("Default actor isolation must be nonisolated in this interface profile")
        }
        guard importer.upcomingFeatures.isEmpty, importer.experimentalFeatures.isEmpty else {
            throw incompatible("This interface profile requires no upcoming or experimental features")
        }
        if let sdk = importer.sdk, sdk.name != "macosx" || sdk.version.isEmpty {
            throw incompatible("The importer SDK must identify a macOS SDK and version")
        }

        let interface: String
        do {
            interface = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw incompatible("Cannot read the public Swift interface: \(error)")
        }

        // Only compiler-emitted prefix metadata applies. Never interpret comments in declarations.
        let header = interface.split(whereSeparator: \.isNewline).prefix(while: { $0.hasPrefix("// ") })
        func headerValue(_ field: String, required: Bool = true) throws -> String? {
            let key = "// \(field):"
            let values = header.filter { $0.hasPrefix(key) }.map {
                $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
            guard values.count == 1, let value = values.first, !value.isEmpty else {
                if !required && values.isEmpty { return nil }
                throw incompatible("Expected one \(field) field in the Swift interface header")
            }
            return value
        }
        guard let format = try headerValue("swift-interface-format-version"), format == "1.0" else {
            throw incompatible("Unsupported Swift interface format; expected 1.0")
        }
        guard let compiler = try headerValue("swift-compiler-version"), compiler == importer.compilerIdentity else {
            throw incompatible("The interface compiler identity does not match the explicit importer compiler identity")
        }
        let flags = try headerValue("swift-module-flags") ?? ""
        var declared: [String: String] = [:]
        var standalone = Set<String>()
        var tokens = flags.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let flag = tokens.popFirst() {
            switch flag {
            case "-target", "-module-name", "-default-isolation", "-sdk":
                guard let value = tokens.popFirst(), !value.hasPrefix("-"), declared.updateValue(value, forKey: flag) == nil else {
                    throw incompatible("Malformed or duplicate interface flag \(flag)")
                }
            case "-swift-version", "-language-mode":
                guard let value = tokens.popFirst(), declared.updateValue(value, forKey: "language") == nil else {
                    throw incompatible("Malformed or duplicate Swift language mode flag")
                }
            case "-enable-library-evolution", "-enable-objc-interop", "-disable-objc-interop":
                guard standalone.insert(flag).inserted else {
                    throw incompatible("Duplicate interface flag \(flag)")
                }
            default:
                throw incompatible("Interface flag \(flag) is outside the supported compiler context")
            }
        }
        guard declared["-module-name"] == module else {
            throw incompatible("Requested module '\(module)' differs from interface module '\(declared["-module-name"] ?? "unavailable")'")
        }
        guard declared["-target"] == importer.targetTriple else {
            throw incompatible("Importer target '\(importer.targetTriple)' differs from interface target '\(declared["-target"] ?? "unavailable")'")
        }
        guard declared["language"] == importer.swiftLanguageMode else {
            throw incompatible("The interface Swift language mode differs from the explicit importer language mode")
        }
        let isolation = declared["-default-isolation"]
        guard isolation == nil || isolation == importer.defaultActorIsolation else {
            throw incompatible("The interface default actor isolation differs from the explicit importer actor isolation")
        }
        let objc = importer.objcInterop ? "-enable-objc-interop" : "-disable-objc-interop"
        let otherObjc = importer.objcInterop ? "-disable-objc-interop" : "-enable-objc-interop"
        guard standalone.contains("-enable-library-evolution"),
              standalone.contains(objc), !standalone.contains(otherObjc) else {
            throw incompatible("The interface must enable library evolution and match the importer Objective-C interop mode")
        }
        if let producerSDK = declared["-sdk"] {
            let name = URL(fileURLWithPath: producerSDK).lastPathComponent
            guard let sdk = importer.sdk, name.lowercased() == "macosx\(sdk.version).sdk" else {
                throw incompatible("The declared producer SDK '\(name)' does not match the explicit importer SDK")
            }
        }

        if let ignorable = try headerValue("swift-module-flags-ignorable", required: false) {
            var metadata = ignorable.split(whereSeparator: \.isWhitespace).map(String.init)[...]
            var seen = Set<String>()
            while let flag = metadata.popFirst() {
                guard seen.insert(flag).inserted else {
                    throw incompatible("Duplicate interface metadata flag \(flag)")
                }
                switch flag {
                case "-formal-cxx-interoperability-mode=off":
                    break
                case "-interface-compiler-version":
                    guard let version = metadata.popFirst(),
                          let versionStart = importer.compilerIdentity.range(of: " version ")?.upperBound,
                          let compilerVersion = importer.compilerIdentity[versionStart...].split(whereSeparator: \.isWhitespace).first,
                          compilerVersion == version else {
                        throw incompatible("The reported interface compiler version differs from the importer identity")
                    }
                default:
                    throw incompatible("Cannot certify interface metadata flag \(flag) in this compiler context")
                }
            }
        }

        var unavailable = ["packageContext", "perFileSettings", "importSearchPaths", "conditionalDefinitions",
                           "upcomingFeatures", "experimentalFeatures"]
        if isolation == nil { unavailable.append("defaultActorIsolation") }
        if declared["-sdk"] == nil { unavailable.append("sdk") }
        self.module = module
        self.path = path
        text = interface
        context = importer
        contextText = contextSource
        interfaceFormatVersion = format
        unavailableProducerContext = unavailable.sorted()
    }

    func inspection(at reportedPath: String) -> Inspection {
        Inspection(module: module, path: reportedPath, interfaceFormatVersion: interfaceFormatVersion, importer: context,
                   unavailableProducerContext: unavailableProducerContext)
    }
}
