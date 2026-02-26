# sq

A simple tool for querying Swift codebases using SQL. It parses your Swift source files using SwiftSyntax, indexes them into a DuckDB database, and lets you explore functions, types, and imports with plain SQL queries.

## Usage

Index a Swift codebase:
```bash
swift run sq /path/to/your/swift/project
```

Then open the database and query:
```bash
duckdb sq.db
```

## Limitations

- For classes the superclass and protocol conformances are both stored in `conformances` field.
- No support for scoped imports (e.g. `import struct Foundation.URL`)
- No call graph
- Generic parameter clauses and constraints (e.g. `Foo<T: Codable>`) are not indexed.
- No type resolution, sq works purely at the syntax level via SwiftSyntax.
- Local variables inside function bodies are excluded. Only type-level and file-level declarations are indexed.
- Qualified names like `Foo.Bar.Baz` are supported, but the parent type of a method defined in an extension may not match the qualified name of the original type if defined in a different file.
- Complex patterns like `let (x, y) =` are skipped

## Examples

```
-- Types with the most methods
SELECT parentType, COUNT(*) as count
FROM functions
WHERE kind = 'method'
GROUP BY parentType
ORDER BY 2 DESC
LIMIT 10;

-- All public throwing functions
SELECT name, parentType, file
FROM functions
WHERE visibility = 'public' AND isThrows = true;

-- Files with the most types
SELECT file, COUNT(*) as count
FROM types
GROUP BY file
ORDER BY 2 DESC
LIMIT 10;

-- All free functions (not methods)
SELECT name, file, line
FROM functions
WHERE parentType IS NULL;

-- Breakdown by type kind
SELECT kind, COUNT(*) as count
FROM types
GROUP BY kind
ORDER BY 2 DESC;

-- Which types conform to a specific protocol
SELECT name, qualifiedName, kind
FROM types
WHERE list_contains(conformances, 'Equatable');

-- All async throwing public methods
SELECT name, qualifiedParentType, file, line
FROM functions
WHERE isAsync = true AND isThrows = true AND visibility = 'public';

-- Types that conform to multiple protocols
SELECT name, qualifiedName, conformances
FROM types
WHERE len(conformances) > 2
ORDER BY len(conformances) DESC;

-- All inits in the codebase
SELECT name, qualifiedParentType, visibility, file, line
FROM functions
WHERE kind = 'init'
ORDER BY qualifiedParentType;

-- Methods defined in extensions (parent type defined in a different file)
SELECT f.name, f.qualifiedParentType, f.file
FROM functions f
LEFT JOIN types t ON t.qualifiedName = f.qualifiedParentType AND t.file = f.file
WHERE t.name IS NULL AND f.qualifiedParentType IS NOT NULL;

-- Globals
SELECT name, kind, typeAnnotation, file, line
FROM properties
WHERE qualifiedParentType IS NULL;

-- Most common type annotations
SELECT typeAnnotation, COUNT(*) as count
FROM properties
WHERE typeAnnotation IS NOT NULL
GROUP BY typeAnnotation
ORDER BY 2 DESC
LIMIT 10;

-- All computed properties
SELECT name, qualifiedParentType, typeAnnotation
FROM properties
WHERE isComputed = true;

-- Types with the most properties
SELECT qualifiedParentType, COUNT(*) as count
FROM properties
WHERE qualifiedParentType IS NOT NULL
GROUP BY qualifiedParentType
ORDER BY 2 DESC
LIMIT 10;

-- All static properties
SELECT name, qualifiedParentType, typeAnnotation
FROM properties
WHERE isStatic = true;

-- Public vars
SELECT name, qualifiedParentType, typeAnnotation, isComputed
FROM properties
WHERE visibility = 'public' AND kind = 'var'
ORDER BY qualifiedParentType;

-- Types that have no stored properties (only computed)
SELECT qualifiedParentType
FROM properties
WHERE qualifiedParentType IS NOT NULL
GROUP BY qualifiedParentType
HAVING COUNT(*) = SUM(CASE WHEN isComputed THEN 1 ELSE 0 END);

-- Types that are extended in multiple files (fragmented across codebase)
SELECT extendedType, COUNT(DISTINCT file) as file_count
FROM extensions
GROUP BY extendedType
ORDER BY 2 DESC
LIMIT 10;

-- Extensions that add protocol conformances
SELECT extendedType, conformances, file
FROM extensions
WHERE len(conformances) > 0;

-- All methods added via extensions
SELECT name, qualifiedParentType, file, line
FROM functions
WHERE isFromExtension = true AND kind = 'method'
ORDER BY qualifiedParentType;

-- Types that only have their methods defined in extensions (no methods in main declaration)
SELECT DISTINCT f.qualifiedParentType
FROM functions f
WHERE f.isFromExtension = true
AND f.qualifiedParentType NOT IN (
    SELECT qualifiedParentType FROM functions
    WHERE isFromExtension = false AND kind = 'method'
);

-- Files that are purely extensions (no type declarations)
SELECT DISTINCT e.file
FROM extensions e
WHERE e.file NOT IN (SELECT DISTINCT file FROM types);
```
