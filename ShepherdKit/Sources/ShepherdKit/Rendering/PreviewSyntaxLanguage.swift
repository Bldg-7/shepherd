import Foundation

/// Small, bounded lexical highlighting, not a compiler or a language server.
/// Unknown languages remain plain text. No grammar downloads or code execution.
public nonisolated enum PreviewSyntaxLanguage: String, Sendable {
    case plain, swift, python, javascript, json, yaml, toml, shell, cFamily, rust, go, ruby, sql

    public static func filename(_ path: String?) -> Self {
        guard let path else { return .plain }
        return switch (path as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "py", "pyi": .python
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": .javascript
        case "json", "jsonl": .json
        case "yaml", "yml": .yaml
        case "toml", "ini", "conf": .toml
        case "sh", "bash", "zsh": .shell
        case "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt": .cFamily
        case "rs": .rust
        case "go": .go
        case "rb": .ruby
        case "sql": .sql
        default: .plain
        }
    }

    public static func fence(_ label: String?) -> Self {
        guard let label else { return .plain }
        return switch label.lowercased() {
        case "swift": .swift
        case "python", "py": .python
        case "javascript", "js", "jsx", "typescript", "ts", "tsx": .javascript
        case "json": .json
        case "yaml", "yml": .yaml
        case "toml", "ini": .toml
        case "sh", "shell", "bash", "zsh": .shell
        case "c", "cpp", "c++", "objc", "objective-c", "java", "kotlin": .cFamily
        case "rust", "rs": .rust
        case "go", "golang": .go
        case "ruby", "rb": .ruby
        case "sql": .sql
        default: .plain
        }
    }

    public var hashComments: Bool { [.python, .yaml, .toml, .shell, .ruby].contains(self) }
    public var slashComments: Bool { [.swift, .javascript, .cFamily, .rust, .go].contains(self) }
    public var keywords: Set<String> {
        let words: String
        switch self {
        case .plain: words = ""
        case .swift: words = "actor any as async await associatedtype break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is isolated let macro mutating nil nonisolated open override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while"
        case .python: words = "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"
        case .javascript: words = "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface keyof let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while yield"
        case .json: words = "true false null"
        case .yaml, .toml: words = "true false null yes no on off"
        case .shell: words = "if then else elif fi for while until do done case esac in function select return export local readonly declare unset exit"
        case .cFamily: words = "abstract auto bool break case catch char class const continue default delete do double else enum extern false final float for friend if import int interface long namespace new nullptr override package private protected public return short signed sizeof static struct super switch template this throw true try typedef typename union unsigned using virtual void volatile while"
        case .rust: words = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        case .go: words = "break case chan const continue default defer else fallthrough for func go goto if import interface map nil package range return select struct switch type var true false"
        case .ruby: words = "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"
        case .sql: words = "select from where join inner outer left right full on as insert into values update set delete create table drop alter index primary key foreign references null not and or is like in exists case when then else end group by order having limit offset distinct union all true false asc desc"
        }
        return Set(words.split(separator: " ").map(String.init))
    }
}

