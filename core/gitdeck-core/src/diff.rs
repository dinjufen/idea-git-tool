//! 文本差异：编辑器 gutter 的变更标记（IDEA 的 line status）与 Diff 视图。
//!
//! 先按行比较得到变更块，再在“修改”块内按单词比较，标出具体变化的位置。
//! 所有字符偏移均为 UTF-16，与两端 UI 的字符串编址一致。

use std::time::{Duration, Instant};

use similar::{Algorithm, DiffOp};

use crate::error::CoreError;
use crate::repo::Repository;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LineChangeKind {
    Added,
    Modified,
    Deleted,
}

/// 一段连续的行变更。行号从 0 开始。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LineChange {
    pub kind: LineChangeKind,
    /// 在新文本中的起始行；删除时为删除位置之后的那一行。
    pub start: u32,
    /// 新文本中的行数；删除时为 0。
    pub count: u32,
    /// 在基准文本中的起始行。
    pub base_start: u32,
    /// 基准文本中的行数；新增时为 0。
    pub base_count: u32,
}

/// 空白字符的比较方式，对应 IDEA Diff 工具栏的 “Do not ignore / Trim whitespaces / Ignore whitespaces”。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum WhitespaceMode {
    #[default]
    Compare,
    /// 忽略行首行尾的空白。
    Trim,
    /// 忽略所有空白。
    Ignore,
}

/// 文本中的一段字符区间（UTF-16 偏移，左闭右开）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TextRange {
    pub start: u32,
    pub end: u32,
}

/// Diff 视图中的一个变更块。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DiffBlock {
    pub change: LineChange,
    /// 基准文本中变化的单词（仅“修改”块计算）。
    pub base_inline: Vec<TextRange>,
    /// 新文本中变化的单词（仅“修改”块计算）。
    pub inline: Vec<TextRange>,
}

/// 单次计算的时间上限；超时后 similar 会返回不那么精确但正确的结果。
const DIFF_DEADLINE: Duration = Duration::from_millis(500);
/// 超过该行数的修改块不再计算单词级差异（IDEA 同样对大块跳过细粒度比较）。
const INLINE_MAX_LINES: u32 = 200;

/// 计算从 `base` 到 `text` 的行级变更。换行符差异（CRLF / LF）被忽略，与 IDEA 一致。
#[uniffi::export]
pub fn line_changes(base: String, text: String) -> Vec<LineChange> {
    let old = Lines::new(&base);
    let new = Lines::new(&text);
    line_blocks(&old, &new, WhitespaceMode::Compare)
}

/// 计算 Diff 视图所需的变更块，修改块内附带单词级差异。
#[uniffi::export]
pub fn diff_texts(base: String, text: String, whitespace: WhitespaceMode) -> Vec<DiffBlock> {
    let old = Lines::new(&base);
    let new = Lines::new(&text);
    line_blocks(&old, &new, whitespace)
        .into_iter()
        .map(|change| {
            let (base_inline, inline) = if change.kind == LineChangeKind::Modified
                && change.count.max(change.base_count) <= INLINE_MAX_LINES
            {
                inline_diff(
                    &old,
                    change.base_start..change.base_start + change.base_count,
                    &new,
                    change.start..change.start + change.count,
                    whitespace,
                )
            } else {
                (Vec::new(), Vec::new())
            };
            DiffBlock {
                change,
                base_inline,
                inline,
            }
        })
        .collect()
}

fn line_blocks(old: &Lines, new: &Lines, whitespace: WhitespaceMode) -> Vec<LineChange> {
    let old_keys: Vec<String> = old.lines.iter().map(|l| normalize(l, whitespace)).collect();
    let new_keys: Vec<String> = new.lines.iter().map(|l| normalize(l, whitespace)).collect();
    let ops = similar::capture_diff_slices_deadline(
        Algorithm::Myers,
        &old_keys,
        &new_keys,
        Some(Instant::now() + DIFF_DEADLINE),
    );

    let mut changes: Vec<LineChange> = Vec::new();
    for op in ops {
        let (base_start, base_count, start, count) = match op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete {
                old_index,
                old_len,
                new_index,
            } => (old_index, old_len, new_index, 0),
            DiffOp::Insert {
                old_index,
                new_index,
                new_len,
            } => (old_index, 0, new_index, new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => (old_index, old_len, new_index, new_len),
        };
        // 相邻的删除与插入合并为一段“修改”。
        if let Some(last) = changes.last_mut()
            && last.base_start + last.base_count == base_start as u32
            && last.start + last.count == start as u32
        {
            last.base_count += base_count as u32;
            last.count += count as u32;
            last.kind = kind_of(last.base_count, last.count);
            continue;
        }
        changes.push(LineChange {
            kind: kind_of(base_count as u32, count as u32),
            start: start as u32,
            count: count as u32,
            base_start: base_start as u32,
            base_count: base_count as u32,
        });
    }
    changes
}

fn kind_of(base_count: u32, count: u32) -> LineChangeKind {
    match (base_count, count) {
        (0, _) => LineChangeKind::Added,
        (_, 0) => LineChangeKind::Deleted,
        _ => LineChangeKind::Modified,
    }
}

fn normalize(line: &str, whitespace: WhitespaceMode) -> String {
    match whitespace {
        WhitespaceMode::Compare => line.to_owned(),
        WhitespaceMode::Trim => line.trim().to_owned(),
        WhitespaceMode::Ignore => line.chars().filter(|c| !c.is_whitespace()).collect(),
    }
}

/// 按行切分的文本，记录每行起点的 UTF-16 偏移。行内容不含换行符（`\n` 与 `\r\n`）。
struct Lines<'a> {
    lines: Vec<&'a str>,
    starts: Vec<u32>,
}

impl<'a> Lines<'a> {
    fn new(text: &'a str) -> Self {
        let mut lines = Vec::new();
        let mut starts = Vec::new();
        let mut offset = 0u32;
        for raw in text.split_inclusive('\n') {
            starts.push(offset);
            offset += raw.encode_utf16().count() as u32;
            let line = raw.strip_suffix('\n').unwrap_or(raw);
            lines.push(line.strip_suffix('\r').unwrap_or(line));
        }
        Lines { lines, starts }
    }
}

/// 单词级比较：把块内文本切成单词、空白与符号，比较后返回双方变化部分的区间。
fn inline_diff(
    old: &Lines,
    old_range: std::ops::Range<u32>,
    new: &Lines,
    new_range: std::ops::Range<u32>,
    whitespace: WhitespaceMode,
) -> (Vec<TextRange>, Vec<TextRange>) {
    let old_tokens = tokenize(old, old_range, whitespace);
    let new_tokens = tokenize(new, new_range, whitespace);
    let old_text: Vec<&str> = old_tokens.iter().map(|t| t.text).collect();
    let new_text: Vec<&str> = new_tokens.iter().map(|t| t.text).collect();
    let ops = similar::capture_diff_slices_deadline(
        Algorithm::Myers,
        &old_text,
        &new_text,
        Some(Instant::now() + DIFF_DEADLINE),
    );

    let mut old_changed = Vec::new();
    let mut new_changed = Vec::new();
    for op in ops {
        let (old_slice, new_slice) = match op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete {
                old_index, old_len, ..
            } => (old_index..old_index + old_len, 0..0),
            DiffOp::Insert {
                new_index, new_len, ..
            } => (0..0, new_index..new_index + new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => (
                old_index..old_index + old_len,
                new_index..new_index + new_len,
            ),
        };
        push_ranges(&mut old_changed, &old_tokens[old_slice]);
        push_ranges(&mut new_changed, &new_tokens[new_slice]);
    }
    (old_changed, new_changed)
}

struct Token<'a> {
    text: &'a str,
    start: u32,
    end: u32,
}

#[derive(PartialEq)]
enum TokenClass {
    Word,
    Space,
    Other,
}

fn class_of(c: char) -> TokenClass {
    if c.is_alphanumeric() || c == '_' {
        TokenClass::Word
    } else if c.is_whitespace() {
        TokenClass::Space
    } else {
        TokenClass::Other
    }
}

/// 把若干行切分为单词（字母数字下划线连续段）、空白段与单个符号，行之间用换行符号分隔。
fn tokenize<'a>(
    lines: &Lines<'a>,
    range: std::ops::Range<u32>,
    whitespace: WhitespaceMode,
) -> Vec<Token<'a>> {
    let mut tokens = Vec::new();
    for index in range {
        let line = lines.lines[index as usize];
        let line_start = lines.starts[index as usize];
        let mut utf16 = line_start;
        let mut chars = line.char_indices().peekable();
        while let Some((byte, c)) = chars.next() {
            let class = class_of(c);
            let mut end_byte = byte + c.len_utf8();
            let mut end_utf16 = utf16 + c.len_utf16() as u32;
            if class != TokenClass::Other {
                while let Some(&(next_byte, next)) = chars.peek() {
                    if class_of(next) != class {
                        break;
                    }
                    chars.next();
                    end_byte = next_byte + next.len_utf8();
                    end_utf16 += next.len_utf16() as u32;
                }
            }
            let keep = class != TokenClass::Space || whitespace == WhitespaceMode::Compare;
            if keep {
                tokens.push(Token {
                    text: &line[byte..end_byte],
                    start: utf16,
                    end: end_utf16,
                });
            }
            utf16 = end_utf16;
        }
        // 换行也作为一个标记参与比较，使跨行移动的单词能被正确识别。
        tokens.push(Token {
            text: "\n",
            start: utf16,
            end: utf16,
        });
    }
    tokens
}

/// 把变化的标记合并为连续区间（忽略换行标记本身）。
fn push_ranges(out: &mut Vec<TextRange>, tokens: &[Token]) {
    for token in tokens.iter().filter(|t| t.end > t.start) {
        match out.last_mut() {
            Some(last) if last.end == token.start => last.end = token.end,
            _ => out.push(TextRange {
                start: token.start,
                end: token.end,
            }),
        }
    }
}

#[uniffi::export]
impl Repository {
    /// 读取文件在某个修订中的内容；该修订中不存在此文件时返回 `None`。
    ///
    /// `revision` 可以是 `HEAD`、提交哈希或分支名；`path` 相对仓库根目录。
    /// 非 UTF-8 内容按有损方式解码。
    pub fn file_at_revision(
        &self,
        revision: String,
        path: String,
    ) -> std::result::Result<Option<String>, CoreError> {
        if revision.starts_with('-') || revision.contains(':') {
            return Err(CoreError::Parse {
                detail: format!("invalid revision: {revision:?}"),
            });
        }
        let object = format!("{revision}:{path}");
        // `-e` 只检查对象是否存在：不存在时退出码为 1，不当作错误。
        if self
            .git
            .run(&self.root, ["cat-file", "-e", object.as_str()])
            .is_err()
        {
            return Ok(None);
        }
        let out = self
            .git
            .run(&self.root, ["cat-file", "blob", object.as_str()])?;
        Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(
        kind: LineChangeKind,
        start: u32,
        count: u32,
        base_start: u32,
        base_count: u32,
    ) -> LineChange {
        LineChange {
            kind,
            start,
            count,
            base_start,
            base_count,
        }
    }

    fn slices(text: &str, ranges: &[TextRange]) -> Vec<String> {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        ranges
            .iter()
            .map(|r| String::from_utf16_lossy(&utf16[r.start as usize..r.end as usize]))
            .collect()
    }

    #[test]
    fn inline_changes_mark_changed_words() {
        let base = "let x = 1;\nlet name = \"旧值\";\n";
        let text = "let x = 1;\nlet title = \"新值😀\";\n";
        let blocks = diff_texts(base.into(), text.into(), WhitespaceMode::Compare);
        assert_eq!(blocks.len(), 1);
        assert_eq!(
            blocks[0].change,
            change(LineChangeKind::Modified, 1, 1, 1, 1)
        );
        assert_eq!(slices(base, &blocks[0].base_inline), ["name", "旧值"]);
        assert_eq!(slices(text, &blocks[0].inline), ["title", "新值😀"]);
    }

    #[test]
    fn whitespace_modes() {
        let base = "fn a() {\n    x();\n}\n";
        let text = "fn a() {\n\tx();  \n}\n";
        assert_eq!(
            diff_texts(base.into(), text.into(), WhitespaceMode::Compare).len(),
            1
        );
        assert!(diff_texts(base.into(), text.into(), WhitespaceMode::Trim).is_empty());
        let spaced = "fn a( ) {\n    x ( );\n}\n";
        // 相邻两行都有变化，合并为一个两行的修改块。
        let trimmed = diff_texts(base.into(), spaced.into(), WhitespaceMode::Trim);
        assert_eq!(trimmed.len(), 1);
        assert_eq!(
            trimmed[0].change,
            change(LineChangeKind::Modified, 0, 2, 0, 2)
        );
        assert!(diff_texts(base.into(), spaced.into(), WhitespaceMode::Ignore).is_empty());
    }

    #[test]
    fn crlf_offsets_account_for_carriage_returns() {
        let base = "a\r\nold\r\n";
        let text = "a\r\nnew\r\n";
        let blocks = diff_texts(base.into(), text.into(), WhitespaceMode::Compare);
        assert_eq!(slices(base, &blocks[0].base_inline), ["old"]);
        assert_eq!(slices(text, &blocks[0].inline), ["new"]);
    }

    #[test]
    fn identical_text_has_no_changes() {
        assert!(line_changes("a\nb\n".into(), "a\nb\n".into()).is_empty());
    }

    #[test]
    fn detects_added_modified_and_deleted_lines() {
        let base = "one\ntwo\nthree\nfour\nfive\n";
        let text = "zero\none\nTWO\nthree\nfive\n";
        assert_eq!(
            line_changes(base.into(), text.into()),
            [
                change(LineChangeKind::Added, 0, 1, 0, 0),
                change(LineChangeKind::Modified, 2, 1, 1, 1),
                change(LineChangeKind::Deleted, 4, 0, 3, 1),
            ]
        );
    }

    #[test]
    fn ignores_line_ending_differences() {
        assert!(line_changes("a\nb\n".into(), "a\r\nb\r\n".into()).is_empty());
    }

    #[test]
    fn new_file_is_all_added() {
        assert_eq!(
            line_changes(String::new(), "x\ny\n".into()),
            [change(LineChangeKind::Added, 0, 2, 0, 0)]
        );
    }
}
