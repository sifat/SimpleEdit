import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("Shell parsing")
struct ShellParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .shell, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source, budget: 30).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Commands are functions and their flags are constants")
    func commandsAndFlags() throws {
        let found = try highlight("set -euo pipefail\nwc -l file | sort --numeric-sort")
        #expect(found.contains { $0 == ("set", .function) })
        #expect(found.contains { $0 == ("wc", .function) })
        #expect(found.contains { $0 == ("sort", .function) })
        #expect(found.contains { $0 == ("-euo", .constant) })
        #expect(found.contains { $0 == ("-l", .constant) })
        #expect(found.contains { $0 == ("--numeric-sort", .constant) })
        // An argument that is not a flag stays plain: that is the #match? "^-"
        // predicate being evaluated, not ignored.
        #expect(!found.contains { $0.0 == "pipefail" })
        #expect(!found.contains { $0.0 == "file" })
    }

    @Test("A shebang and comments are comments")
    func comments() throws {
        let found = try highlight("#!/bin/bash\n# deploy\necho hi")
        #expect(found.contains { $0 == ("#!/bin/bash", .comment) })
        #expect(found.contains { $0 == ("# deploy", .comment) })
    }

    @Test("Variable names are properties, in assignments and loops")
    func variables() throws {
        let found = try highlight("export PATH=\"$HOME/bin\"\nfor f in *.txt; do echo; done")
        #expect(found.contains { $0 == ("PATH", .property) })
        #expect(found.contains { $0 == ("f", .property) })
        #expect(found.contains { $0 == ("export", .keyword) })
    }

    @Test("Control keywords")
    func keywords() throws {
        let found = try highlight("if true; then\n  echo\nelif false; then\n  echo\nelse\n  echo\nfi")
        for word in ["if", "then", "elif", "else", "fi"] {
            #expect(found.contains { $0 == (word, .keyword) }, "\(word)")
        }
    }

    @Test("Single- and double-quoted strings, each one token")
    func strings() throws {
        let found = try highlight("echo 'single' \"double $HOME\"")
        #expect(found.contains { $0 == ("'single'", .string) })
        #expect(found.contains { $0 == ("\"double $HOME\"", .string) })
    }

    /// The external scanner is what recognises a heredoc -- its body has no
    /// closing delimiter the grammar alone could find. If the scanner were
    /// missing, the body would not parse and neither would anything after it.
    @Test("A heredoc parses, so the external scanner is present")
    func heredoc() throws {
        let found = try highlight("cat <<EOF\nhello $USER\nEOF\necho done")
        #expect(found.contains { $0 == ("hello $USER\n", .string) })
        #expect(found.contains { $0 == ("echo", .function) })
    }

    /// `@embedded` covers a whole substitution including the command inside
    /// it. Unmapped, the command keeps its own colour; mapped, outermost-wins
    /// would swallow it.
    @Test("A command inside a substitution keeps its colour")
    func substitutions() throws {
        let found = try highlight("rev=$(git rev-parse --short HEAD)\ndiff <(ls a) <(ls b)")
        #expect(found.contains { $0 == ("git", .function) })
        #expect(found.contains { $0 == ("--short", .constant) })
        #expect(found.filter { $0.0 == "ls" }.map(\.1) == [.function, .function])
        #expect(!found.contains { $0.0.hasPrefix("$(") })
    }

    @Test("Redirections are punctuation and file descriptors are constants")
    func redirections() throws {
        let found = try highlight("echo hi >> log.txt 2>&1")
        #expect(found.contains { $0 == (">>", .punctuation) })
        #expect(found.contains { $0 == ("2", .constant) })
    }

    @Test("A function definition's name is a function")
    func functionDefinition() throws {
        let found = try highlight("deploy() {\n  git push\n}")
        #expect(found.contains { $0 == ("deploy", .function) })
        #expect(found.contains { $0 == ("git", .function) })
    }

    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("echo \"🎉\"\nls -la")
        #expect(found.contains { $0 == ("\"🎉\"", .string) })
        #expect(found.contains { $0 == ("ls", .function) })
        #expect(found.contains { $0 == ("-la", .constant) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("echo \"unterminated")
        _ = try highlight("cat <<EOF\nno end")
        _ = try highlight("$( ( ( ")
        _ = try highlight("if then fi else")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }

    @Test("Tokens come out sorted and non-overlapping")
    func tokensAreDisjoint() throws {
        let source = """
        #!/usr/bin/env bash
        set -euo pipefail
        readonly ROOT="$(cd "$(dirname "$0")" && pwd)"
        build() {
          local arch=${1:-arm64}
          swift build -c release --triple "$arch-apple-macosx" 2>&1 | tee "build-$arch.log"
        }
        for arch in arm64 x86_64; do build "$arch"; done
        cat <<EOF > summary.txt
        built in $ROOT
        EOF
        """
        let parser = try #require(SyntaxParser(language: .shell, queriesRoot: QueryLoadingTests.queriesRoot))
        let tokens = parser.tokens(for: source, budget: 30).tokens
        #expect(!tokens.isEmpty)
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }
}
