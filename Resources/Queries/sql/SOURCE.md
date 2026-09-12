# tree-sitter-sql queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/DerekStride/tree-sitter-sql |
| Branch | `gh-pages` (generated sources) |
| Commit | `593a5ecc5dc3889890d8b24ba8fa7487ee01bfe5`, the deploy of main `b7057b7` |
| Copied | 2026-09-12 |
| Licence | MIT, copyright 2021 Derek Stride — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

## Why a revision rather than a tag

This is the only dependency here pinned by revision, and the only one from
outside the tree-sitter organisation. Both follow from how the project is
published. **The tags do not contain a generated `parser.c`** — but their own
`Package.swift` lists `src/parser.c` in its sources, so a tag cannot build at
all. Upstream generates the parser in CI and pushes it to the `gh-pages`
branch, one `deploy: <main sha>` commit per change. That branch keeps its
history rather than being force-replaced, so a revision pin stays fetchable;
checked before pinning.

The manifest there declares `swift-tree-sitter` for its test target only, and
SwiftPM prunes it: resolving adds one pin, not two.

## Size

`parser.c` is 41.6 MB of source and **11.2 MB of compiled parse tables per
architecture** — seven times the largest grammar otherwise in the app
(TypeScript's TSX at 1.5 MB) and about double the whole app binary before it.
A universal build carries it twice. That is the price of a grammar that covers
several dialects at once, and it was accepted knowingly.

## Dialect: what it does and does not parse

The grammar leans ANSI and PostgreSQL. Hand-written SQL — `CREATE TABLE`,
`SELECT … JOIN … GROUP BY … HAVING`, `UPDATE`, window functions — parses
cleanly.

**mysqldump and phpMyAdmin exports largely do not.** Measured over 25 real dump
files, 24 contained parse errors, and the constructs responsible are the ones
every dump begins with:

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=... */;   -- MySQL's versioned comments
    START TRANSACTION;
    `col` varchar(255) COLLATE utf8mb4_unicode_ci    -- COLLATE in a column definition
    ) ENGINE=InnoDB AUTO_INCREMENT=5                 -- table options
    LOCK TABLES `users` WRITE;

One 268 KB phpMyAdmin export parsed as a single error node covering the whole
file. In practice most dumps are far larger than the size cap and are left
plain anyway; a small one will show keywords and strings with errors scattered
through it. This is recorded as known behaviour, not a bug to be fixed here.

No alternative grammar helps: `m-novikov/tree-sitter-sql` targets PostgreSQL
explicitly and `dhcmrlchtdj/tree-sitter-sqlite` targets SQLite. There is no
MySQL-dialect grammar and none under the tree-sitter organisation.

## Predicates, and the one translation this app performs

`#match?` twice, and **they are Lua patterns, not regular expressions**:

    ((literal) @number (#match? @number "^[-+]?%d+$"))
    ((literal) @float  (#match? @float  "^[-+]?%d*\.%d*$"))

This query is written for Neovim, whose `#match?` takes a Lua pattern, where a
character class is `%d` rather than `\d`. Read as ICU — which is what
`NSRegularExpression` speaks — `%d` matches a literal per cent sign followed by
`d`, so neither predicate would ever match. That is not a missing colour but a
wrong one: `(literal)` is captured as `@string` as well, so every number in the
file would colour red as a string.

So `SyntaxParser.icuPattern(from:)` translates Lua's character classes when a
pattern contains `%`. No other vendored query's `#match?` pattern contains one,
so nothing else is affected. The `.scm` itself stays a byte-for-byte copy,
which is the rule this app does not break.

## Keeping it in step with upstream

On a bump, re-copy from the **`gh-pages`** branch, not from a tag — the tag's
`queries/highlights.scm` is older than the generated one (15 keyword lines
behind at v0.3.11). `QueryContractTests` asserts the capture-name set is exactly
the twenty-one names below.

    @attribute  @boolean  @comment  @conditional  @field  @float
    @function.call  @keyword  @keyword.operator  @number  @operator  @parameter
    @punctuation.bracket  @punctuation.delimiter  @spell  @storageclass  @string
    @type  @type.builtin  @type.qualifier  @variable

## Captures

Half of these names are Neovim's vocabulary and appear in no other query here.

| Capture | Treatment | Why |
| --- | --- | --- |
| `@conditional` | `keyword` | `CASE`, `WHEN`, `THEN`, `ELSE` |
| `@storageclass` | `keyword` | `TEMPORARY`, `MATERIALIZED`, `VOLATILE` |
| `@type.qualifier` | `keyword` | `UNIQUE`, `CASCADE`, `CHECK`, `IGNORE` |
| `@keyword.operator` | `keyword` via fallback | `AND`, `OR`, `NOT`, `IN`, `UNION` |
| `@field` | `property` | a column name |
| `@parameter` | `property` | a `$1` placeholder |
| `@variable` | `property` via the shared row | a relation or term alias |
| `@boolean`, `@float` | `constant` | literals, as `@number` already is |
| `@type`, `@type.builtin` | `type` | a table or object name, and the built-in types. The shared `type` row means CSS's unit, so it must be overridden |
| `@attribute` | `attribute` via the shared row | `DEFAULT`, `COLLATE`, `ENGINE`, `AUTO_INCREMENT` |
| `@function.call` | `function` via fallback | including index methods such as `btree` |
| `@spell` | **unmapped** | not a colour: Neovim's spell-check marker, captured over the same node as `@comment` |
