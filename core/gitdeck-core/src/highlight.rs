//! 语法高亮：用 tree-sitter 解析源码，输出按 UTF-16 偏移表示的着色区间。
//!
//! macOS（NSString）与 Windows（.NET string）都以 UTF-16 编址文本，
//! 因此偏移在核心里统一换算，两端可直接用于设置文本属性。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// 高亮类别，由 UI 映射到配色方案中的颜色（对应 IDEA 的 Color Scheme 条目）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TokenKind {
    Keyword,
    String,
    /// 正则、符号、链接等特殊字符串。
    StringSpecial,
    Escape,
    Comment,
    Number,
    Constant,
    Function,
    Type,
    Parameter,
    Property,
    Operator,
    Punctuation,
    Tag,
    Attribute,
    Namespace,
    Label,
    Heading,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HighlightSpan {
    /// UTF-16 偏移（含）。
    pub start: u32,
    /// UTF-16 偏移（不含）。
    pub end: u32,
    pub kind: TokenKind,
}

/// 超过该大小的文件不做高亮（IDEA 对大文件同样会关闭代码分析）。
pub const MAX_HIGHLIGHT_BYTES: usize = 2 * 1024 * 1024;

/// tree-sitter 捕获名 → 类别。未列出的捕获（例如普通 `variable`）不着色，与 IDEA 默认配色一致。
/// 匹配时取最长前缀，例如 `function.method.call` 会匹配 `function.method`。
const CAPTURES: &[(&str, TokenKind)] = &[
    ("attribute", TokenKind::Attribute),
    ("boolean", TokenKind::Constant),
    ("character", TokenKind::String),
    ("comment", TokenKind::Comment),
    ("constant", TokenKind::Constant),
    // 数字字面量与 true / null 等共用该捕获，按内容细分，见 `refine_builtin`。
    ("constant.builtin", TokenKind::Constant),
    ("constructor", TokenKind::Type),
    ("escape", TokenKind::Escape),
    ("float", TokenKind::Number),
    ("function", TokenKind::Function),
    ("function.builtin", TokenKind::Function),
    ("function.macro", TokenKind::Function),
    ("function.method", TokenKind::Function),
    ("keyword", TokenKind::Keyword),
    ("label", TokenKind::Label),
    ("markup.heading", TokenKind::Heading),
    ("markup.link", TokenKind::StringSpecial),
    ("markup.raw", TokenKind::String),
    ("module", TokenKind::Namespace),
    ("namespace", TokenKind::Namespace),
    ("number", TokenKind::Number),
    ("operator", TokenKind::Operator),
    ("property", TokenKind::Property),
    ("punctuation", TokenKind::Punctuation),
    ("string", TokenKind::String),
    ("string.escape", TokenKind::Escape),
    ("string.special", TokenKind::StringSpecial),
    ("tag", TokenKind::Tag),
    ("text.literal", TokenKind::String),
    ("text.title", TokenKind::Heading),
    ("text.uri", TokenKind::StringSpecial),
    ("type", TokenKind::Type),
    ("type.builtin", TokenKind::Type),
    // self / this 等按关键字着色。
    ("variable.builtin", TokenKind::Keyword),
    ("variable.parameter", TokenKind::Parameter),
];

/// 按文件路径推断语言标识；不支持的文件返回 `None`。
#[uniffi::export]
pub fn language_for_path(path: String) -> Option<String> {
    let name = path
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(&path)
        .to_ascii_lowercase();
    let by_name = match name.as_str() {
        "cargo.lock" | "pipfile" => Some("toml"),
        ".bashrc" | ".zshrc" | ".bash_profile" | ".profile" => Some("bash"),
        _ => None,
    };
    let ext = name.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    let language = by_name.or(match ext {
        "rs" => Some("rust"),
        "js" | "mjs" | "cjs" => Some("javascript"),
        "jsx" => Some("jsx"),
        "ts" | "mts" | "cts" => Some("typescript"),
        "tsx" => Some("tsx"),
        "py" | "pyi" => Some("python"),
        "go" => Some("go"),
        "java" => Some("java"),
        "c" | "h" => Some("c"),
        "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => Some("cpp"),
        "cs" => Some("csharp"),
        "json" => Some("json"),
        "html" | "htm" => Some("html"),
        "css" => Some("css"),
        "sh" | "bash" | "zsh" => Some("bash"),
        "md" | "markdown" => Some("markdown"),
        "yml" | "yaml" => Some("yaml"),
        "toml" => Some("toml"),
        "swift" => Some("swift"),
        _ => None,
    });
    language.map(str::to_owned)
}

/// 对整段文本做高亮。语言不支持、文本过大或解析失败时返回空列表。
#[uniffi::export]
pub fn highlight(language: String, text: String) -> Vec<HighlightSpan> {
    if text.len() > MAX_HIGHLIGHT_BYTES {
        return Vec::new();
    }
    let Some(config) = configuration(&language) else {
        return Vec::new();
    };
    let mut highlighter = Highlighter::new();
    let Ok(events) = highlighter.highlight(&config, text.as_bytes(), None, None, |_| None) else {
        return Vec::new();
    };

    let mut spans: Vec<HighlightSpan> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut offsets = Utf16Offsets::new(&text);
    for event in events {
        match event {
            Ok(HighlightEvent::HighlightStart(h)) => stack.push(h.0),
            Ok(HighlightEvent::HighlightEnd) => {
                stack.pop();
            }
            Ok(HighlightEvent::Source { start, end }) => {
                let Some(&capture) = stack.last() else {
                    continue;
                };
                let (name, kind) = CAPTURES[capture];
                let kind = if name == "constant.builtin" {
                    refine_builtin(&text[start..end])
                } else {
                    kind
                };
                let start = offsets.at(start);
                let end = offsets.at(end);
                // 合并相邻的同类区间，减少 UI 需要设置的属性段。
                match spans.last_mut() {
                    Some(last) if last.kind == kind && last.end == start => last.end = end,
                    _ => spans.push(HighlightSpan { start, end, kind }),
                }
            }
            Err(_) => break,
        }
    }
    spans
}

/// `constant.builtin` 细分：数字字面量按数字着色，`true` / `null` / `None` 等按关键字着色（与 IDEA 一致）。
fn refine_builtin(token: &str) -> TokenKind {
    let mut chars = token.chars();
    match (chars.next(), chars.next()) {
        (Some(c), _) if c.is_ascii_digit() => TokenKind::Number,
        (Some('-' | '.'), Some(c)) if c.is_ascii_digit() => TokenKind::Number,
        _ => TokenKind::Keyword,
    }
}

/// 编译好的高亮配置按语言缓存；查询编译较慢，只做一次。
static CONFIGS: LazyLock<Mutex<HashMap<String, Option<Arc<HighlightConfiguration>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn configuration(language: &str) -> Option<Arc<HighlightConfiguration>> {
    let mut cache = CONFIGS.lock().unwrap_or_else(|e| e.into_inner());
    cache
        .entry(language.to_owned())
        .or_insert_with(|| build_configuration(language).map(Arc::new))
        .clone()
}

fn build_configuration(language: &str) -> Option<HighlightConfiguration> {
    use tree_sitter_javascript as js;
    // 部分语法的查询是在基础语言上扩展的，需要拼接：更具体的查询放在前面优先匹配。
    let (lang, highlights): (tree_sitter::Language, String) = match language {
        "rust" => (
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY.into(),
        ),
        "javascript" => (js::LANGUAGE.into(), js::HIGHLIGHT_QUERY.into()),
        "jsx" => (
            js::LANGUAGE.into(),
            [js::JSX_HIGHLIGHT_QUERY, js::HIGHLIGHT_QUERY].concat(),
        ),
        "typescript" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            [
                tree_sitter_typescript::HIGHLIGHTS_QUERY,
                js::HIGHLIGHT_QUERY,
            ]
            .concat(),
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            [
                tree_sitter_typescript::HIGHLIGHTS_QUERY,
                js::JSX_HIGHLIGHT_QUERY,
                js::HIGHLIGHT_QUERY,
            ]
            .concat(),
        ),
        "python" => (
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY.into(),
        ),
        "go" => (
            tree_sitter_go::LANGUAGE.into(),
            tree_sitter_go::HIGHLIGHTS_QUERY.into(),
        ),
        "java" => (
            tree_sitter_java::LANGUAGE.into(),
            tree_sitter_java::HIGHLIGHTS_QUERY.into(),
        ),
        "c" => (
            tree_sitter_c::LANGUAGE.into(),
            tree_sitter_c::HIGHLIGHT_QUERY.into(),
        ),
        "cpp" => (
            tree_sitter_cpp::LANGUAGE.into(),
            [
                tree_sitter_cpp::HIGHLIGHT_QUERY,
                tree_sitter_c::HIGHLIGHT_QUERY,
            ]
            .concat(),
        ),
        "csharp" => (
            tree_sitter_c_sharp::LANGUAGE.into(),
            tree_sitter_c_sharp::HIGHLIGHTS_QUERY.into(),
        ),
        "json" => (
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY.into(),
        ),
        "html" => (
            tree_sitter_html::LANGUAGE.into(),
            tree_sitter_html::HIGHLIGHTS_QUERY.into(),
        ),
        "css" => (
            tree_sitter_css::LANGUAGE.into(),
            tree_sitter_css::HIGHLIGHTS_QUERY.into(),
        ),
        "bash" => (
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY.into(),
        ),
        "markdown" => (
            tree_sitter_md::LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK.into(),
        ),
        "yaml" => (
            tree_sitter_yaml::LANGUAGE.into(),
            tree_sitter_yaml::HIGHLIGHTS_QUERY.into(),
        ),
        "toml" => (
            tree_sitter_toml_ng::LANGUAGE.into(),
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY.into(),
        ),
        "swift" => (
            tree_sitter_swift::LANGUAGE.into(),
            tree_sitter_swift::HIGHLIGHTS_QUERY.into(),
        ),
        _ => return None,
    };
    let mut config = HighlightConfiguration::new(lang, language, &highlights, "", "").ok()?;
    let names: Vec<&str> = CAPTURES.iter().map(|(name, _)| *name).collect();
    config.configure(&names);
    Some(config)
}

/// 把单调递增的 UTF-8 字节偏移换算为 UTF-16 偏移。
struct Utf16Offsets<'a> {
    text: &'a str,
    byte: usize,
    utf16: u32,
}

impl<'a> Utf16Offsets<'a> {
    fn new(text: &'a str) -> Self {
        Utf16Offsets {
            text,
            byte: 0,
            utf16: 0,
        }
    }

    fn at(&mut self, byte: usize) -> u32 {
        if byte < self.byte {
            // 理论上事件按偏移递增；万一回退则从头计算。
            self.byte = 0;
            self.utf16 = 0;
        }
        let byte = byte.min(self.text.len());
        for c in self.text[self.byte..byte].chars() {
            self.utf16 += c.len_utf16() as u32;
        }
        self.byte = byte;
        self.utf16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 支持的语言标识。
    const LANGUAGES: &[&str] = &[
        "bash",
        "c",
        "cpp",
        "csharp",
        "css",
        "go",
        "html",
        "java",
        "javascript",
        "json",
        "jsx",
        "markdown",
        "python",
        "rust",
        "swift",
        "toml",
        "tsx",
        "typescript",
        "yaml",
    ];

    fn kinds_of(language: &str, text: &str) -> Vec<(String, TokenKind)> {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        highlight(language.into(), text.into())
            .into_iter()
            .map(|s| {
                (
                    String::from_utf16_lossy(&utf16[s.start as usize..s.end as usize]),
                    s.kind,
                )
            })
            .collect()
    }

    #[test]
    fn every_language_configuration_compiles() {
        for language in LANGUAGES {
            assert!(
                configuration(language).is_some(),
                "{language} query failed to compile"
            );
        }
    }

    #[test]
    fn highlights_rust_tokens() {
        let spans = kinds_of(
            "rust",
            "// note\nfn main() { let s = \"hi\"; let n = 42; }\n",
        );
        assert!(
            spans.contains(&("// note".into(), TokenKind::Comment)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("fn".into(), TokenKind::Keyword)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("main".into(), TokenKind::Function)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("\"hi\"".into(), TokenKind::String)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("42".into(), TokenKind::Number)),
            "{spans:?}"
        );
    }

    #[test]
    fn builtin_constants_split_into_numbers_and_keywords() {
        let spans = kinds_of("python", "x = None\ny = 3.5\nz = True\n");
        assert!(
            spans.contains(&("None".into(), TokenKind::Keyword)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("True".into(), TokenKind::Keyword)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("3.5".into(), TokenKind::Number)),
            "{spans:?}"
        );
    }

    #[test]
    fn offsets_are_utf16_with_cjk_and_emoji() {
        // “中文”各占 1 个 UTF-16 单元，emoji 占 2 个；字符串起点应为 UTF-16 下标。
        let text = "// 中文😀\nlet s = \"x\";";
        let spans = kinds_of("typescript", text);
        assert!(
            spans.contains(&("// 中文😀".into(), TokenKind::Comment)),
            "{spans:?}"
        );
        assert!(
            spans.contains(&("\"x\"".into(), TokenKind::String)),
            "{spans:?}"
        );
    }

    #[test]
    fn unsupported_or_huge_input_yields_nothing() {
        assert!(highlight("cobol".into(), "IDENTIFICATION DIVISION.".into()).is_empty());
        let huge = "a".repeat(MAX_HIGHLIGHT_BYTES + 1);
        assert!(highlight("rust".into(), huge).is_empty());
    }

    #[test]
    fn detects_language_from_path() {
        let cases = [
            ("src/main.rs", Some("rust")),
            ("C:\\work\\App.TSX", Some("tsx")),
            ("include/foo.hpp", Some("cpp")),
            ("Cargo.lock", Some("toml")),
            ("docs/README.md", Some("markdown")),
            ("Makefile", None),
            ("archive.tar.gz", None),
        ];
        for (path, expected) in cases {
            assert_eq!(
                language_for_path(path.into()).as_deref(),
                expected,
                "{path}"
            );
        }
    }
}
