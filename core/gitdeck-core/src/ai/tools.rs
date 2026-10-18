//! 评审 Agent 的只读工具：读文件、列目录、搜索代码、查看历史与 blame。
//!
//! 所有路径都相对仓库根目录，拒绝绝对路径与 `..`，并经过敏感文件过滤；
//! 工作区读取还会解析符号链接，确认目标仍在仓库内。

use std::path::Path;

use serde_json::{Value, json};

use super::filter::SensitiveFilter;
use super::provider::ToolSpec;
use crate::repo::Repository;

pub(crate) const SUBMIT_REVIEW: &str = "submit_review";

/// 单次工具输出的上限，避免一次读取占满上下文。
const MAX_OUTPUT_CHARS: usize = 60_000;
const MAX_READ_LINES: usize = 1_200;
const MAX_SEARCH_RESULTS: usize = 150;
const MAX_LIST_ENTRIES: usize = 400;

pub(crate) struct ToolContext<'a> {
    pub repo: &'a Repository,
    pub filter: &'a SensitiveFilter,
    /// 被评审的版本：`None` 为工作区，否则为某个修订。
    pub revision: Option<String>,
}

pub(crate) fn tool_specs() -> Vec<ToolSpec> {
    let revision = json!({
        "type": "string",
        "description": "Optional commit hash or ref to read from instead of the version under review."
    });
    vec![
        ToolSpec {
            name: "read_file",
            description: "Read a file from the repository, with line numbers. Defaults to the version under review. Use start_line/end_line for large files.",
            schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Path relative to the repository root." },
                    "start_line": { "type": "integer", "minimum": 1 },
                    "end_line": { "type": "integer", "minimum": 1 },
                    "revision": revision,
                },
                "required": ["path"],
                "additionalProperties": false,
            }),
        },
        ToolSpec {
            name: "list_directory",
            description: "List the files and subdirectories of a directory in the repository (directories end with '/').",
            schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Directory relative to the repository root; empty for the root." },
                    "revision": revision,
                },
                "additionalProperties": false,
            }),
        },
        ToolSpec {
            name: "search_code",
            description: "Search the repository's files (git grep). Returns matching lines as path:line:text.",
            schema: json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Text to search for; an extended regular expression when regex is true." },
                    "regex": { "type": "boolean" },
                    "ignore_case": { "type": "boolean" },
                    "path": { "type": "string", "description": "Optional directory or file to limit the search to." },
                    "revision": revision,
                },
                "required": ["pattern"],
                "additionalProperties": false,
            }),
        },
        ToolSpec {
            name: "git_log",
            description: "Show recent commits (hash, date, author, subject), optionally limited to a path.",
            schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "max_count": { "type": "integer", "minimum": 1, "maximum": 50 },
                    "revision": revision,
                },
                "additionalProperties": false,
            }),
        },
        ToolSpec {
            name: "git_blame",
            description: "Show which commit last changed each line in a range of a file.",
            schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "start_line": { "type": "integer", "minimum": 1 },
                    "end_line": { "type": "integer", "minimum": 1 },
                    "revision": revision,
                },
                "required": ["path", "start_line", "end_line"],
                "additionalProperties": false,
            }),
        },
        ToolSpec {
            name: SUBMIT_REVIEW,
            description: "Submit the final review. Call exactly once, when the review is complete; an empty findings list is fine when there is nothing worth reporting.",
            schema: json!({
                "type": "object",
                "properties": {
                    "summary": { "type": "string", "description": "Two or three sentences on the overall state of the change." },
                    "findings": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "file": { "type": "string", "description": "Path relative to the repository root." },
                                "line": { "type": "integer", "minimum": 1, "description": "First affected line in the version under review." },
                                "end_line": { "type": "integer", "minimum": 1 },
                                "severity": { "type": "string", "enum": ["error", "warning", "suggestion"] },
                                "title": { "type": "string", "description": "One-line description of the problem." },
                                "explanation": { "type": "string", "description": "Why it is a problem and how to fix it." },
                                "original": { "type": "string", "description": "Optional: the exact current text of lines line..end_line, copied verbatim." },
                                "replacement": { "type": "string", "description": "Optional: the text that should replace `original`." },
                            },
                            "required": ["file", "line", "severity", "title", "explanation"],
                            "additionalProperties": false,
                        },
                    },
                },
                "required": ["summary", "findings"],
                "additionalProperties": false,
            }),
        },
    ]
}

/// 工具调用的简短描述，用于进度显示（例如 `read_file src/main.rs:10-40`）。
pub(crate) fn describe(name: &str, input: &Value) -> String {
    let path = input["path"].as_str().unwrap_or_default();
    match name {
        "read_file" | "git_blame" => {
            match (input["start_line"].as_u64(), input["end_line"].as_u64()) {
                (Some(s), Some(e)) => format!("{path}:{s}-{e}"),
                (Some(s), None) => format!("{path}:{s}"),
                _ => path.to_owned(),
            }
        }
        "search_code" => {
            let pattern = input["pattern"].as_str().unwrap_or_default();
            if path.is_empty() {
                pattern.to_owned()
            } else {
                format!("{pattern}  ({path})")
            }
        }
        _ => path.to_owned(),
    }
}

impl ToolContext<'_> {
    /// 执行只读工具；`Err` 的内容作为错误结果回传给模型。
    pub fn run(&self, name: &str, input: &Value) -> std::result::Result<String, String> {
        let output = match name {
            "read_file" => self.read_file(input),
            "list_directory" => self.list_directory(input),
            "search_code" => self.search_code(input),
            "git_log" => self.git_log(input),
            "git_blame" => self.git_blame(input),
            other => Err(format!("unknown tool: {other}")),
        }?;
        Ok(truncate(output, MAX_OUTPUT_CHARS))
    }

    fn revision(&self, input: &Value) -> std::result::Result<Option<String>, String> {
        match input.get("revision") {
            None | Some(Value::Null) => Ok(self.revision.clone()),
            Some(Value::String(r)) if r.is_empty() => Ok(self.revision.clone()),
            Some(Value::String(r)) => {
                if r.starts_with('-') || r.contains(':') || r.contains(char::is_whitespace) {
                    Err(format!("invalid revision: {r}"))
                } else {
                    Ok(Some(r.clone()))
                }
            }
            Some(_) => Err("revision must be a string".into()),
        }
    }

    /// 校验并规范化路径，排除敏感文件。
    fn path(
        &self,
        input: &Value,
        required: bool,
        is_dir: bool,
    ) -> std::result::Result<String, String> {
        let raw = match input.get("path") {
            Some(Value::String(p)) => p.as_str(),
            None | Some(Value::Null) if !required => "",
            _ => return Err("`path` (string) is required".into()),
        };
        let path = normalize_path(raw)?;
        if required && path.is_empty() {
            return Err("`path` must not be empty".into());
        }
        if !path.is_empty() && self.filter.matches(&path, is_dir) {
            return Err(format!(
                "{path} is excluded from AI review by the sensitive-file rules"
            ));
        }
        Ok(path)
    }

    fn read_file(&self, input: &Value) -> std::result::Result<String, String> {
        let path = self.path(input, true, false)?;
        let content = match self.revision(input)? {
            Some(rev) => self
                .repo
                .file_at_revision(rev.clone(), path.clone())
                .map_err(|e| e.to_string())?
                .ok_or_else(|| format!("{path} does not exist in {rev}"))?,
            None => self.read_working_file(&path)?,
        };
        if content.contains('\0') {
            return Err(format!("{path} is a binary file"));
        }
        let lines: Vec<&str> = content.lines().collect();
        let total = lines.len();
        let start = optional_u64(input, "start_line")?.unwrap_or(1).max(1) as usize;
        let requested_end = optional_u64(input, "end_line")?.map(|e| e as usize);
        let end = requested_end
            .unwrap_or(total)
            .min(total)
            .min(start + MAX_READ_LINES - 1);
        if total == 0 {
            return Ok(format!("{path} is empty"));
        }
        if start > total {
            return Err(format!("{path} has only {total} lines"));
        }
        let mut out = String::new();
        for (i, line) in lines[start - 1..end].iter().enumerate() {
            out.push_str(&format!("{:>5}\t{line}\n", start + i));
        }
        if end < requested_end.unwrap_or(total).min(total) {
            out.push_str(&format!(
                "[showing lines {start}-{end} of {total}; request a later start_line to read more]\n"
            ));
        }
        Ok(out)
    }

    fn read_working_file(&self, path: &str) -> std::result::Result<String, String> {
        let root = std::fs::canonicalize(&self.repo.root).map_err(|e| e.to_string())?;
        let full = std::fs::canonicalize(self.repo.root.join(path))
            .map_err(|_| format!("{path} does not exist in the working tree"))?;
        // 符号链接可能指向仓库外或敏感文件。
        let relative = full
            .strip_prefix(&root)
            .map_err(|_| format!("{path} points outside the repository"))?;
        let relative = relative.to_string_lossy().replace('\\', "/");
        if self.filter.matches(&relative, false) {
            return Err(format!(
                "{path} is excluded from AI review by the sensitive-file rules"
            ));
        }
        if full.is_dir() {
            return Err(format!("{path} is a directory; use list_directory"));
        }
        let bytes = std::fs::read(&full).map_err(|e| e.to_string())?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    fn list_directory(&self, input: &Value) -> std::result::Result<String, String> {
        let path = self.path(input, false, true)?;
        let mut entries: Vec<(String, bool)> = Vec::new();
        match self.revision(input)? {
            Some(rev) => {
                let object = format!("{rev}:{path}");
                let out = self
                    .repo
                    .git
                    .run(&self.repo.root, ["ls-tree", "-z", object.as_str()])
                    .map_err(|_| format!("{path} is not a directory in {rev}"))?;
                for record in out.stdout.split(|b| *b == 0).filter(|r| !r.is_empty()) {
                    let record = String::from_utf8_lossy(record);
                    let Some((meta, name)) = record.split_once('\t') else {
                        continue;
                    };
                    entries.push((name.to_owned(), meta.split(' ').nth(1) == Some("tree")));
                }
            }
            None => {
                let mut args = vec![
                    "ls-files",
                    "-z",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                ];
                if !path.is_empty() {
                    args.extend(["--", path.as_str()]);
                }
                let out = self
                    .repo
                    .git
                    .run(&self.repo.root, args)
                    .map_err(|e| e.to_string())?;
                let prefix = if path.is_empty() {
                    String::new()
                } else {
                    format!("{path}/")
                };
                for file in out.stdout.split(|b| *b == 0).filter(|r| !r.is_empty()) {
                    let file = String::from_utf8_lossy(file);
                    let Some(rest) = file.strip_prefix(prefix.as_str()) else {
                        continue;
                    };
                    let (name, is_dir) = match rest.split_once('/') {
                        Some((dir, _)) => (dir.to_owned(), true),
                        None => (rest.to_owned(), false),
                    };
                    if !entries.iter().any(|(n, _)| *n == name) {
                        entries.push((name, is_dir));
                    }
                }
                if entries.is_empty() && !self.repo.root.join(&path).is_dir() {
                    return Err(format!("{path} is not a directory"));
                }
            }
        }
        entries.retain(|(name, is_dir)| {
            let full = if path.is_empty() {
                name.clone()
            } else {
                format!("{path}/{name}")
            };
            !self.filter.matches(&full, *is_dir)
        });
        entries.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let total = entries.len();
        let mut out: String = entries
            .iter()
            .take(MAX_LIST_ENTRIES)
            .map(|(name, is_dir)| {
                if *is_dir {
                    format!("{name}/\n")
                } else {
                    format!("{name}\n")
                }
            })
            .collect();
        if total > MAX_LIST_ENTRIES {
            out.push_str(&format!(
                "[{} more entries omitted]\n",
                total - MAX_LIST_ENTRIES
            ));
        }
        if out.is_empty() {
            out.push_str("(empty)\n");
        }
        Ok(out)
    }

    fn search_code(&self, input: &Value) -> std::result::Result<String, String> {
        let pattern = input["pattern"]
            .as_str()
            .filter(|p| !p.is_empty())
            .ok_or("`pattern` (non-empty string) is required")?;
        let path = self.path(input, false, false)?;
        let revision = self.revision(input)?;
        let mut args: Vec<String> =
            vec!["grep".into(), "-n".into(), "-I".into(), "--no-color".into()];
        if optional_bool(input, "ignore_case")? {
            args.push("-i".into());
        }
        args.push(
            if optional_bool(input, "regex")? {
                "-E"
            } else {
                "-F"
            }
            .into(),
        );
        args.extend(["-e".into(), pattern.to_owned()]);
        match &revision {
            Some(rev) => args.push(rev.clone()),
            None => args.push("--untracked".into()),
        }
        if !path.is_empty() {
            args.extend(["--".into(), path]);
        }
        // 没有匹配时退出码为 1。
        let out = self
            .repo
            .git
            .run_with_exit_codes(&self.repo.root, &args, &[1])
            .map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&out.stdout);
        let prefix = revision.map(|r| format!("{r}:")).unwrap_or_default();
        let mut results = Vec::new();
        let mut total = 0;
        for line in text.lines() {
            let line = line.strip_prefix(prefix.as_str()).unwrap_or(line);
            let file = line.split(':').next().unwrap_or_default();
            if self.filter.matches(file, false) {
                continue;
            }
            total += 1;
            if results.len() < MAX_SEARCH_RESULTS {
                results.push(truncate(line.to_owned(), 300));
            }
        }
        if total == 0 {
            return Ok("No matches.".into());
        }
        let mut out = results.join("\n");
        out.push('\n');
        if total > MAX_SEARCH_RESULTS {
            out.push_str(&format!(
                "[{} more matches omitted; narrow the search]\n",
                total - MAX_SEARCH_RESULTS
            ));
        }
        Ok(out)
    }

    fn git_log(&self, input: &Value) -> std::result::Result<String, String> {
        let path = self.path(input, false, false)?;
        let max_count = optional_u64(input, "max_count")?.unwrap_or(15).clamp(1, 50);
        let mut args: Vec<String> = vec![
            "log".into(),
            "--format=%h %ad %an%n    %s".into(),
            "--date=short".into(),
            format!("-n{max_count}"),
        ];
        args.push(self.revision(input)?.unwrap_or_else(|| "HEAD".into()));
        if !path.is_empty() {
            args.extend(["--".into(), path]);
        }
        let out = self
            .repo
            .git
            .run(&self.repo.root, &args)
            .map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        Ok(if text.trim().is_empty() {
            "No commits.".into()
        } else {
            text
        })
    }

    fn git_blame(&self, input: &Value) -> std::result::Result<String, String> {
        let path = self.path(input, true, false)?;
        let start = optional_u64(input, "start_line")?.ok_or("`start_line` is required")?;
        let end = optional_u64(input, "end_line")?.ok_or("`end_line` is required")?;
        if start == 0 || end < start {
            return Err("invalid line range".into());
        }
        let end = end.min(start + 300);
        let mut args: Vec<String> = vec![
            "blame".into(),
            format!("-L{start},{end}"),
            "--date=short".into(),
        ];
        if let Some(rev) = self.revision(input)? {
            args.push(rev);
        }
        args.extend(["--".into(), path]);
        let out = self
            .repo
            .git
            .run(&self.repo.root, &args)
            .map_err(|e| e.to_string())?;
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

/// 规范化相对路径：统一分隔符，去掉 `.`，拒绝绝对路径与 `..`。
pub(crate) fn normalize_path(raw: &str) -> std::result::Result<String, String> {
    let raw = raw.trim().replace('\\', "/");
    if raw.starts_with('/') || Path::new(&raw).is_absolute() || raw.get(1..2) == Some(":") {
        return Err(format!("{raw}: use a path relative to the repository root"));
    }
    let mut parts = Vec::new();
    for part in raw.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                return Err(format!(
                    "{raw}: paths outside the repository are not allowed"
                ));
            }
            other => parts.push(other),
        }
    }
    Ok(parts.join("/"))
}

fn optional_u64(input: &Value, key: &str) -> std::result::Result<Option<u64>, String> {
    match input.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` must be a positive integer")),
    }
}

fn optional_bool(input: &Value, key: &str) -> std::result::Result<bool, String> {
    match input.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
        Some(_) => Err(format!("`{key}` must be a boolean")),
    }
}

pub(crate) fn truncate(mut text: String, max_chars: usize) -> String {
    if let Some((index, _)) = text.char_indices().nth(max_chars) {
        text.truncate(index);
        text.push_str("\n[output truncated]");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_paths() {
        assert_eq!(normalize_path("./src//main.rs").unwrap(), "src/main.rs");
        assert_eq!(normalize_path("src\\lib.rs").unwrap(), "src/lib.rs");
        assert_eq!(normalize_path("").unwrap(), "");
        assert!(normalize_path("../etc/passwd").is_err());
        assert!(normalize_path("src/../../x").is_err());
        assert!(normalize_path("/etc/passwd").is_err());
        assert!(normalize_path("C:/Windows").is_err());
    }
}
