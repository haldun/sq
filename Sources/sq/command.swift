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
        let folderURL = URL(fileURLWithPath: folder)
        let index = try await makeCodeIndex(folder: folderURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: URL(fileURLWithPath: snapshotPath))
        try loadIntoDuckDB(snapshotPath: snapshotPath, databasePath: databasePath)
        print("Done. Open with: duckdb \(databasePath)")
    }
}

let duckDBBinaryPath = "/opt/homebrew/bin/duckdb"

func loadIntoDuckDB(snapshotPath: String, databasePath: String) throws {
    let maximumObjectSize = 10_000_000
    let sql = """
        DROP TABLE IF EXISTS functions;
        DROP TABLE IF EXISTS types;
        DROP TABLE IF EXISTS imports;

        CREATE TABLE functions AS
        SELECT f.name, f.file, f.line, f.kind, f.qualifiedParentType, f.visibility, f.isAsync, f.isStatic, f.isThrows FROM (
            SELECT unnest(functions) as f FROM read_json_auto('\(snapshotPath)', maximum_object_size = \(maximumObjectSize))
        );

        CREATE TABLE types AS
        SELECT f.name, f.qualifiedName, f.file, f.line, f.kind, f.visibility, f.conformances FROM (
            SELECT unnest(types) as f FROM read_json_auto('\(snapshotPath)', maximum_object_size = \(maximumObjectSize))
        );

        CREATE TABLE imports AS
        SELECT f.module, f.file FROM (
            SELECT unnest(imports) as f FROM read_json_auto('\(snapshotPath)', maximum_object_size = \(maximumObjectSize))
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
    var functions: [FunctionInfo]
    var imports: [ImportInfo]
    var types: [TypeInfo]
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
}

struct ImportInfo: Codable {
    let module: String
    let file: String
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

func makeCodeIndex(folder: URL) async throws -> CodeIndex {
    var index = CodeIndex(functions: [], imports: [], types: [])
    let fileManager = FileManager.default

    guard
        let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    else { return index }

    let swiftFiles =
        enumerator
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }

    return try await withThrowingTaskGroup(of: CodeIndex.self) { group in
        for fileURL in swiftFiles {
            group.addTask {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let visitor = IndexVisitor(fileName: fileURL.path, tree: tree)
                visitor.walk(tree)
                return CodeIndex(
                    functions: visitor.functions,
                    imports: visitor.imports,
                    types: visitor.types
                )
            }
        }
        for try await partial in group {
            index.functions.append(contentsOf: partial.functions)
            index.imports.append(contentsOf: partial.imports)
            index.types.append(contentsOf: partial.types)
        }
        return index
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

final class IndexVisitor: SyntaxVisitor {
    let fileName: String
    let locationConverter: SourceLocationConverter

    var functions: [FunctionInfo] = []
    var imports: [ImportInfo] = []
    var types: [TypeInfo] = []

    private var typeStack: [String] = []
    private var currentQualifiedType: String? { typeStack.isEmpty ? nil : typeStack.joined(separator: ".") }

    init(fileName: String, tree: SourceFileSyntax) {
        self.fileName = fileName
        self.locationConverter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // Handle imports
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let module = node.path.map { $0.name.text }.joined(separator: ".")
        imports.append(.init(module: module, file: fileName))
        return .visitChildren
    }

    // Handle functions
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        handleFunctionDecl(
            node, name: node.name.text, kind: typeStack.isEmpty ? .function : .method)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        handleFunctionDecl(node, name: "init", kind: .`init`)
    }

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
                isThrows: node.signature.effectSpecifiers?.throwsClause != nil
            )
        )
        return .visitChildren
    }

    // Handle types
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        handle(node: node, kind: .struct)
    }
    override func visitPost(_ node: StructDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        handle(node: node, kind: .class)
    }
    override func visitPost(_ node: ClassDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        handle(node: node, kind: .enum)
    }
    override func visitPost(_ node: EnumDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        handle(node: node, kind: .actor)
    }
    override func visitPost(_ node: ActorDeclSyntax) { handleTypeDeclPost() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        handle(node: node, kind: .protocol)
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { handleTypeDeclPost() }

    private func handle(node: TypeDeclSyntax, kind: TypeKind) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        let type = TypeInfo(
            name: node.name.text,
            qualifiedName: typeStack.joined(separator: "."),
            file: fileName,
            line: line(for: node),
            kind: kind,
            visibility: node.modifiers.visibility,
            conformances: node.inheritanceClause?.conformances ?? []
        )
        types.append(type)
        return .visitChildren
    }

    private func handleTypeDeclPost() { typeStack.removeLast() }

    private func line(for node: some SyntaxProtocol) -> Int {
        locationConverter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}

// helpers
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
