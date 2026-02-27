import ArgumentParser
import Foundation
import QuartzCore
import SwiftParser
import SwiftSyntax

@main
struct SQ: AsyncParsableCommand {
    @Argument(help: "Path to the Swift codebase to index")
    var folder: String

    @Option(name: .long, help: "Path to write the snapshot JSON")
    var snapshotPath: String = "./snapshot.json"

    @Option(name: .long, help: "Path to write the DuckDB database")
    var databasePath: String = "./sq.db"

    mutating func run() async throws {
        let start = CACurrentMediaTime()
        defer {
            print(
                String(
                    format: "Done in %.2fms. Open with: duckdb \(databasePath)", (CACurrentMediaTime() - start) * 1000.0
                )
            )
        }
        let folderURL = URL(fileURLWithPath: folder)
        let index = try await makeCodeIndex(folder: folderURL)
        let encoder = JSONEncoder()
        let data = try encoder.encode(index)
        try data.write(to: URL(fileURLWithPath: snapshotPath))
        try loadIntoDuckDB(snapshotPath: snapshotPath, databasePath: databasePath)
    }
}

let duckDBBinaryPath = "/opt/homebrew/bin/duckdb"

func loadIntoDuckDB(snapshotPath: String, databasePath: String) throws {
    let maximumObjectSize = 10_000_000
    // @todo generate this SQL from the Codable structs to avoid manually keeping it in sync with the Swift model.
    // Tried macros and protocols but neither is really worth it. Macros are heavy and require a separate target, and the protocol
    // approach just moves the problem rather than fixing it.
    let sql = """
        DROP TABLE IF EXISTS functions;
        CREATE TABLE functions AS
        SELECT f.name, f.file, f.line, f.kind, f.qualifiedParentType, f.visibility, f.isAsync, f.isStatic, f.isThrows,
               f.isFromExtension, f.nodeCount
        FROM (
            SELECT unnest(functions) as f FROM read_json_auto('\(snapshotPath)')
        );

        DROP TABLE IF EXISTS imports;
        CREATE TABLE imports AS
        SELECT f.module, f.file FROM (
            SELECT unnest(imports) as f FROM read_json_auto('\(snapshotPath)', maximum_object_size = \(maximumObjectSize))
        );

        DROP TABLE IF EXISTS properties;
        CREATE TABLE properties AS
        SELECT f.name, f.file, f.line, f.kind, f.qualifiedParentType, f.visibility, f.isStatic, f.isComputed, f.typeAnnotation, f.isFromExtension FROM (
            SELECT unnest(properties) as f FROM read_json_auto('\(snapshotPath)')
        );

        DROP TABLE IF EXISTS types;
        CREATE TABLE types AS
        SELECT f.name, f.qualifiedName, f.file, f.line, f.kind, f.visibility, f.conformances FROM (
            SELECT unnest(types) as f FROM read_json_auto('\(snapshotPath)', maximum_object_size = \(maximumObjectSize))
        );

        DROP TABLE IF EXISTS extensions;
        CREATE TABLE extensions AS
        SELECT f.extendedType, f.file, f.line, f.conformances FROM (
            SELECT unnest(extensions) as f FROM read_json_auto('\(snapshotPath)')
        );
        """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: duckDBBinaryPath)
    process.arguments = [databasePath]

    let pipe = Pipe()
    process.standardInput = pipe

    try process.run()
    pipe.fileHandleForWriting.write(sql.data(using: .utf8)!)
    pipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "DuckDB", code: Int(process.terminationStatus))
    }
}

struct CodeIndex: Codable {
    var extensions: [ExtensionInfo] = []
    var functions: [FunctionInfo] = []
    var imports: [ImportInfo] = []
    var properties: [PropertyInfo] = []
    var types: [TypeInfo] = []
}

enum FunctionKind: String, Codable {
    case function
    case method
    case `init`
    case `subscript`
    case `deinit`
}

enum Visibility: String, Codable {
    case `fileprivate`
    case `internal`
    case `open`
    case `private`
    case `public`
}

struct FunctionInfo: Codable {
    let name: String
    let file: String
    let line: Int
    let kind: FunctionKind
    let qualifiedParentType: String?
    let visibility: Visibility
    let isAsync: Bool
    let isStatic: Bool
    let isThrows: Bool
    let isFromExtension: Bool
    let nodeCount: Int
}

struct ImportInfo: Codable {
    let module: String
    let file: String
}

enum PropertyKind: String, Codable {
    case `let`
    case `var`
}

struct PropertyInfo: Codable {
    let name: String
    let kind: PropertyKind
    let file: String
    let line: Int
    let qualifiedParentType: String?
    let visibility: Visibility
    let isStatic: Bool
    let isComputed: Bool
    let typeAnnotation: String?  // e.g. "String", "Int?" what's written in source
    let isFromExtension: Bool
}

enum TypeKind: String, Codable {
    case `actor`
    case `class`
    case `enum`
    case `protocol`
    case `struct`
}

struct TypeInfo: Codable {
    let name: String  // Bar
    let qualifiedName: String  // Foo.Bar
    let file: String
    let line: Int
    let kind: TypeKind
    let visibility: Visibility
    let conformances: [String]
}

struct ExtensionInfo: Codable {
    let extendedType: String  // whatever is written in source, preserving dots since we don't do type resolution
    let file: String
    let line: Int
    let conformances: [String]
}

func makeCodeIndex(folder: URL) async throws -> CodeIndex {
    var index = CodeIndex()
    let fileManager = FileManager.default

    guard
        let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    else { return index }

    let swiftFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }

    return try await withThrowingTaskGroup(of: CodeIndex.self) { group in
        for fileURL in swiftFiles {
            group.addTask {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let visitor = IndexVisitor(fileName: fileURL.path, tree: tree)
                visitor.walk(tree)
                return CodeIndex(
                    extensions: visitor.extensions,
                    functions: visitor.functions,
                    imports: visitor.imports,
                    properties: visitor.properties,
                    types: visitor.types
                )
            }
        }
        for try await partial in group {
            index.extensions.append(contentsOf: partial.extensions)
            index.functions.append(contentsOf: partial.functions)
            index.imports.append(contentsOf: partial.imports)
            index.properties.append(contentsOf: partial.properties)
            index.types.append(contentsOf: partial.types)
        }
        return index
    }
}

final class IndexVisitor: SyntaxVisitor {
    let fileName: String
    let locationConverter: SourceLocationConverter
    var functions: [FunctionInfo] = []
    var imports: [ImportInfo] = []
    var properties: [PropertyInfo] = []
    var types: [TypeInfo] = []
    var extensions: [ExtensionInfo] = []

    private enum Scope {
        case type(String)
        case `extension`
    }

    private var scopeStack: [Scope] = []
    private var currentQualifiedType: String? {
        let names = scopeStack.compactMap { scope in
            if case .type(let name) = scope { return name }
            return nil
        }
        return names.isEmpty ? nil : names.joined(separator: ".")
    }
    private var functionDepth = 0
    private func enterFunction() { functionDepth += 1 }
    private func exitFunction() { functionDepth -= 1 }
    private var isInExtension: Bool {
        if case .extension = scopeStack.last { return true }
        return false
    }

    init(fileName: String, tree: SourceFileSyntax) {
        self.fileName = fileName
        self.locationConverter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // Handle functions
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        enterFunction()
        return handleFunctionDecl(node, name: node.name.text, kind: currentQualifiedType == nil ? .function : .method)
    }
    override func visitPost(_ node: FunctionDeclSyntax) { exitFunction() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        enterFunction()
        return handleFunctionDecl(node, name: "init", kind: .`init`)
    }
    override func visitPost(_ node: InitializerDeclSyntax) { exitFunction() }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        enterFunction()
        functions.append(
            .init(
                name: "deinit",
                file: fileName,
                line: line(for: node),
                kind: .deinit,
                qualifiedParentType: currentQualifiedType,
                visibility: node.modifiers.visibility,
                isAsync: false,
                isStatic: false,
                isThrows: false,
                isFromExtension: false,
                nodeCount: node.totalNodeCount
            )
        )
        return .visitChildren
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) { exitFunction() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        enterFunction()
        // We cannot use `handleFunctionDecl` for subscripts, so special case here.
        functions.append(
            .init(
                name: "subscript",
                file: fileName,
                line: line(for: node),
                kind: .subscript,
                qualifiedParentType: currentQualifiedType,
                visibility: node.modifiers.visibility,
                isAsync: false,
                isStatic: node.modifiers.isStatic,
                isThrows: false,
                isFromExtension: isInExtension,
                nodeCount: node.totalNodeCount
            )
        )
        return .visitChildren
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { exitFunction() }

    private func handleFunctionDecl(
        _ node: some FunctionDeclSyntaxProtocol,
        name: String,
        kind: FunctionKind
    ) -> SyntaxVisitorContinueKind {
        functions.append(
            .init(
                name: name,
                file: fileName,
                line: line(for: node),
                kind: kind,
                qualifiedParentType: currentQualifiedType,
                visibility: node.modifiers.visibility,
                isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
                isStatic: node.modifiers.isStatic,
                isThrows: node.signature.effectSpecifiers?.throwsClause != nil,
                isFromExtension: isInExtension,
                nodeCount: node.totalNodeCount
            )
        )
        return .visitChildren
    }

    // Handle imports
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let module = node.path.map { $0.name.text }.joined(separator: ".")
        imports.append(.init(module: module, file: fileName))
        return .visitChildren
    }

    // Handle types
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { handle(node: node, kind: .struct) }
    override func visitPost(_ node: StructDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { handle(node: node, kind: .class) }
    override func visitPost(_ node: ClassDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { handle(node: node, kind: .enum) }
    override func visitPost(_ node: EnumDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { handle(node: node, kind: .actor) }
    override func visitPost(_ node: ActorDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { handle(node: node, kind: .protocol) }
    override func visitPost(_ node: ProtocolDeclSyntax) { handleTypeDeclPost() }

    private func handle(node: TypeDeclSyntax, kind: TypeKind) -> SyntaxVisitorContinueKind {
        scopeStack.append(.type(node.name.text))
        let type = TypeInfo(
            name: node.name.text,
            qualifiedName: currentQualifiedType!,  // we just added this one to the stack, so ! is fine here.
            file: fileName,
            line: line(for: node),
            kind: kind,
            visibility: node.modifiers.visibility,
            conformances: node.inheritanceClause?.conformances ?? []
        )
        types.append(type)
        return .visitChildren
    }

    private func handleTypeDeclPost() { scopeStack.removeLast() }

    private func line(for node: some SyntaxProtocol) -> Int {
        locationConverter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    // Handle properties
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Skip variables defined in the functions.
        guard functionDepth == 0 else { return .skipChildren }
        let kind: PropertyKind = node.bindingSpecifier.tokenKind == .keyword(.let) ? .let : .var
        for binding in node.bindings {
            // For now we just skip complex patterns like `let (x, y) =` and only handle simple cases
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            properties.append(
                .init(
                    name: name, kind: kind, file: fileName, line: line(for: node),
                    qualifiedParentType: currentQualifiedType, visibility: node.modifiers.visibility,
                    isStatic: node.modifiers.isStatic, isComputed: binding.accessorBlock != nil,
                    typeAnnotation: binding.typeAnnotation?.type.trimmedDescription,
                    isFromExtension: isInExtension
                )
            )
        }
        return .visitChildren
    }

    // Handle extensions

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        scopeStack.append(.extension)
        extensions.append(
            .init(
                extendedType: node.extendedType.trimmedDescription,
                file: fileName,
                line: line(for: node),
                conformances: node.inheritanceClause?.conformances ?? []
            )
        )
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        scopeStack.removeLast()
    }
}

// These protocols shorten the visitor code
protocol TypeDeclSyntax: DeclSyntaxProtocol {
    var name: TokenSyntax { get }
    var modifiers: DeclModifierListSyntax { get }
    var inheritanceClause: InheritanceClauseSyntax? { get }
}

extension StructDeclSyntax: TypeDeclSyntax {}
extension ClassDeclSyntax: TypeDeclSyntax {}
extension EnumDeclSyntax: TypeDeclSyntax {}
extension ActorDeclSyntax: TypeDeclSyntax {}
extension ProtocolDeclSyntax: TypeDeclSyntax {}

protocol FunctionDeclSyntaxProtocol: DeclSyntaxProtocol {
    var modifiers: DeclModifierListSyntax { get }
    var signature: FunctionSignatureSyntax { get }
}

extension FunctionDeclSyntax: FunctionDeclSyntaxProtocol {}
extension InitializerDeclSyntax: FunctionDeclSyntaxProtocol {}

extension DeclModifierListSyntax {
    var visibility: Visibility {
        for modifier in self {
            switch modifier.name.tokenKind {
            case .keyword(.public): return .public
            case .keyword(.private): return .private
            case .keyword(.fileprivate): return .fileprivate
            case .keyword(.open): return .open
            case .keyword(.internal): return .internal
            default: continue
            }
        }
        return .internal
    }

    var isStatic: Bool {
        contains { modifier in
            modifier.name.tokenKind == .keyword(.static)
                || modifier.name.tokenKind == .keyword(.class)
        }
    }
}

extension InheritanceClauseSyntax {
    var conformances: [String] {
        inheritedTypes.map { $0.type.trimmedDescription }
    }
}

extension SyntaxProtocol {
    var totalNodeCount: Int {
        tokens(viewMode: .sourceAccurate).reduce(0) { acc, _ in acc + 1 }
    }
}
