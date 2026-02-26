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
```
