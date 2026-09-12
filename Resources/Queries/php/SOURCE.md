# tree-sitter-php queries

`highlights.scm` and `injections-text.scm` are **byte-for-byte copies** of the
upstream files. Do not edit them.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-php |
| Tag | v0.24.2 |
| Commit | `5b5627faaa290d89eb3d01b9bf47c3bb9e797dea` |
| Copied | 2026-09-12 |
| Licence | MIT, copyright Josh Vera, GitHub; Max Brunsfeld, Amaan Qureshi, Christian Frøystad, Caleb White — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

## Why v0.24.2, and why it is the first ABI 15 grammar here

Every other grammar in this app is ABI 14, and `../bash/SOURCE.md` argues
against taking a 0.25 tag precisely to avoid a second compatibility surface.
PHP is the exception, and the reason is a parse failure rather than a
preference.

**v0.23.12, the newest ABI 14 tag, cannot parse an enum that declares a
constant** — ordinary PHP 8.1:

    enum Suit: string {
        case Hearts = 'H';
        const Wild = self::Hearts;
    }

Measured across a real Drupal 10 tree, that is 6 of the 6 files containing such
an enum, two of them in the site's own `web/modules/custom`, with up to 24.6% of
a file swallowed by `ERROR` nodes. v0.24.2 parses all six. Upstream's fix is a
one-line grammar change, but master is ABI 15 only, so no ABI 14 tag will ever
carry it — nor the PHP 8.4 and 8.5 fixes after it.

The cost, measured rather than assumed. v0.24.2 adopted the grammar's new
reserved-words rules, and that rejects a few names that are legal PHP:
`const FALSE` (and `TRUE`, `MIXED`, `ITERABLE`, `VOID`), `"$obj->class"`-style
keyword properties inside double-quoted strings, and a global
`function readonly()`. Across 45,818 files of WordPress, Drupal 9 and Drupal 10
that is 5 files, each losing 8–29 characters to an `ERROR` node — except
WordPress's small `readonly.php`, which loses 16% of itself. Against that,
v0.24.2 leaves 336 characters inside `ERROR` nodes across Drupal 10 where
v0.23.12 leaves 4,146.

Core tree-sitter is pinned at 0.25.10, which accepts ABI 13 through 15. If it
were ever pinned below 0.25, `ts_parser_set_language` would refuse this grammar
and `.php` files would quietly open plain; every other language would still
work.

Speed is identical between the two tags (~0.18 ms/KB on near-cap Drupal files),
and the package adds about 1.06 MB to the arm64 binary unstripped. It builds two
grammars, `php` and `php_only`; only `tree_sitter_php()` is referenced, so the
second is dead-stripped from the app, though it is still compiled.

## Predicates

`#match?` twice (the `^_?[A-Z][A-Z\d_]+$` constant guess and the `__MAGIC__`
one), `#eq?` twice (`__construct`, and `this`), and `#any-of?` once:

    (named_type (name) @type.builtin (#any-of? @type.builtin "static" "self"))

All are evaluated. The `#any-of?` one matters more than its single use
suggests: unevaluated it would pass unconditionally, and 41,448 ordinary class
names in the Drupal corpus — `FormStateInterface`, `ContainerInterface`,
`Request` — would be captured as builtin types.

## The HTML injection

`injections-text.scm` is three lines, and the third is the whole reason PHP
needed work in `SyntaxParser` rather than just a new enum case:

    ((text) @injection.content
     (#set! injection.language "html")
     (#set! injection.combined))

`injection.combined` means every `(text)` node in the file is **one** injected
document, not one per fragment. A PHP template opens a `<div>` above a `<?php`
and closes it below the matching `?>`; parsed fragment-by-fragment that is a
stream of unbalanced tags. The parser therefore gives the HTML child all of the
text ranges at once through `ts_parser_set_included_ranges`, which is also why
the child reads the document's own buffer and needs no offset shifting.

Upstream's `injections.scm` is deliberately **not** vendored. It injects
`phpdoc` into comments and names a heredoc's language after its terminator
(`<<<SQL`), and this app has neither grammar; vendoring it would add a file
whose every pattern resolves to nothing.

## Keeping it in step with upstream

On a version bump, re-copy both files and diff. The query and the pin move
together: v0.23.12's `highlights.scm` does not compile against the v0.24.2
grammar, and the reverse fails too, both with `TSQueryErrorNodeType`.
`QueryContractTests` asserts the capture-name set is exactly the nineteen names
below.

    @comment  @constant  @constant.builtin  @constructor  @function
    @function.builtin  @function.method  @keyword  @module  @module.builtin
    @number  @operator  @property  @string  @tag  @type  @type.builtin
    @variable  @variable.builtin

## Captures

| Capture | Treatment | Why |
| --- | --- | --- |
| `@variable` | `property` | **not** the blanket identifier capture it is elsewhere: PHP variables carry a `$`, so this is exactly `$foo`. Over 45,000 corpus files it collides only with `@property`, over the identical range, and both map to the same kind |
| `@variable.builtin` | `keyword` | `self::`, `static::` and `parent::`. It also captures the bare `this` inside `$this`, but the `@variable` over the whole `$this` covers it, so that one is never seen |
| `@function.builtin` | `keyword` | `array`, `list`, `exit` — language constructs, not functions |
| `@function.method` | `function` | as Java: this query has no `@property` over the same range to agree with |
| `@type`, `@type.builtin` | `type` | a type name; the shared row is CSS's unit |
| `@constructor` | `type` | `__construct` and the class name in `new Foo` |
| `@module`, `@module.builtin` | `type`, `keyword` | a namespace reads as a type; its `namespace` keyword as a keyword |
| `@operator` | `punctuation` via the shared row | only ever the `$` of a variable, and always inside the `@variable` that covers it |

Nothing is deliberately unmapped: all nineteen names carry a colour.
