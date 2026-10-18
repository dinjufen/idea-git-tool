//! 敏感文件过滤：匹配的文件不会出现在发给模型的 diff 中，Agent 工具也无法读取。
//!
//! 规则语法与 `.gitignore` 相近：不含 `/` 的规则匹配任意一级的文件或目录名；
//! 以 `/` 结尾的规则只匹配目录；其余规则按相对仓库根目录的完整路径匹配，`**` 可跨越多级目录。
//! 匹配不区分大小写（宁可多排除）。

/// 默认排除的敏感文件。
pub const DEFAULT_SENSITIVE_PATTERNS: &[&str] = &[
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.keystore",
    "*.kdbx",
    "id_rsa*",
    "id_dsa*",
    "id_ecdsa*",
    "id_ed25519*",
    ".netrc",
    ".npmrc",
    ".pypirc",
    "secrets/",
    ".ssh/",
];

/// 默认的敏感文件规则，供设置界面展示与恢复默认。
#[uniffi::export]
pub fn default_sensitive_patterns() -> Vec<String> {
    DEFAULT_SENSITIVE_PATTERNS
        .iter()
        .map(|p| (*p).to_owned())
        .collect()
}

/// 路径（相对仓库根目录，`/` 分隔）是否命中任一规则。
#[uniffi::export]
pub fn is_sensitive_path(path: String, patterns: Vec<String>) -> bool {
    SensitiveFilter::new(&patterns).matches(&path, false)
}

#[derive(Debug, Clone)]
pub(crate) struct SensitiveFilter {
    patterns: Vec<Pattern>,
}

#[derive(Debug, Clone)]
struct Pattern {
    glob: String,
    dir_only: bool,
    anchored: bool,
}

impl SensitiveFilter {
    pub fn new(patterns: &[String]) -> Self {
        let patterns = patterns
            .iter()
            .map(|p| p.trim())
            .filter(|p| !p.is_empty() && !p.starts_with('#'))
            .map(|p| {
                let dir_only = p.ends_with('/');
                let p = p.trim_end_matches('/');
                let anchored = p.contains('/');
                Pattern {
                    glob: p.trim_start_matches('/').to_ascii_lowercase(),
                    dir_only,
                    anchored,
                }
            })
            .collect();
        Self { patterns }
    }

    /// `is_dir` 表示 `path` 本身是目录（列目录时）。`.git` 目录始终视为排除。
    pub fn matches(&self, path: &str, is_dir: bool) -> bool {
        let path = path.trim_matches('/').to_ascii_lowercase();
        let components: Vec<&str> = path.split('/').collect();
        if components.contains(&".git") {
            return true;
        }
        self.patterns.iter().any(|p| {
            if p.anchored {
                // 完整路径匹配，或匹配某一级父目录（规则指向目录时其下的文件都排除）。
                (0..components.len()).any(|end| {
                    let is_last = end + 1 == components.len();
                    (!p.dir_only || !is_last || is_dir)
                        && glob_match(&p.glob, &components[..=end].join("/"))
                })
            } else {
                components.iter().enumerate().any(|(i, name)| {
                    let is_last = i + 1 == components.len();
                    (!p.dir_only || !is_last || is_dir) && glob_match(&p.glob, name)
                })
            }
        })
    }
}

/// `*` 匹配除 `/` 外的任意字符，`?` 匹配单个字符，`**` 匹配任意字符（含 `/`）。
fn glob_match(pattern: &str, text: &str) -> bool {
    fn go(p: &[u8], t: &[u8]) -> bool {
        match p.first() {
            None => t.is_empty(),
            Some(b'*') if p.get(1) == Some(&b'*') => {
                let rest = p[2..].strip_prefix(b"/").unwrap_or(&p[2..]);
                (0..=t.len()).any(|i| go(rest, &t[i..]))
            }
            Some(b'*') => (0..=t.len())
                .take_while(|&i| i == 0 || t[i - 1] != b'/')
                .any(|i| go(&p[1..], &t[i..])),
            Some(b'?') => !t.is_empty() && t[0] != b'/' && go(&p[1..], &t[1..]),
            Some(c) => t.first() == Some(c) && go(&p[1..], &t[1..]),
        }
    }
    go(pattern.as_bytes(), text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_filter() -> SensitiveFilter {
        SensitiveFilter::new(&default_sensitive_patterns())
    }

    #[test]
    fn matches_default_patterns() {
        let f = default_filter();
        for path in [
            ".env",
            "config/.env.production",
            "certs/server.PEM",
            "deploy/id_rsa.pub",
            "secrets/db.yaml",
            "app/secrets/nested/token.txt",
            ".git/config",
        ] {
            assert!(f.matches(path, false), "{path} should be excluded");
        }
        for path in [
            "src/main.rs",
            "environment.ts",
            "keys.rs",
            "secrets.rs",
            "docs/key.md",
        ] {
            assert!(!f.matches(path, false), "{path} should be allowed");
        }
        assert!(f.matches("secrets", true));
        assert!(!f.matches("secrets", false));
    }

    #[test]
    fn anchored_and_double_star_patterns() {
        let f = SensitiveFilter::new(&["config/*.yml".into(), "**/fixtures/**".into()]);
        assert!(f.matches("config/prod.yml", false));
        assert!(!f.matches("other/config/prod.yml", false));
        assert!(!f.matches("config/sub/prod.yml", false));
        assert!(f.matches("a/b/fixtures/x.json", false));
        assert!(f.matches("fixtures/x.json", false));
    }
}
