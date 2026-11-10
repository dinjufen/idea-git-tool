//! 本机 CLI 评审：探测已安装的命令行工具，并以 GitDeck 的工具面驱动评审。
//!
//! GitDeck 负责执行工具（含敏感文件过滤）。`claude` 通过本进程内的 MCP 服务
//! 暴露与 HTTP Agent 相同的工具；测试与通用适配则使用行分隔 JSON 协议。
//! 写入类工具单独门控，默认关闭。

mod claude;
mod mcp;
mod protocol;

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::AiTask;
use super::review::{self, ReviewEvent, ReviewListener, ReviewOptions, ReviewResult, ReviewScope};
use super::tools::{self, ToolContext};
use crate::error::{CoreError, Result};
use crate::repo::Repository;

/// 已支持探测与调用的 Claude Code 命令行。
pub const CLI_CLAUDE: &str = "claude";
/// 行分隔 JSON 协议（供测试与后续其它 CLI 适配；不会自动探测）。
pub const CLI_PROTOCOL: &str = "gitdeck-protocol";

/// 探测到的本机 AI CLI。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DetectedAiCli {
    /// 稳定标识，例如 `claude`。
    pub id: String,
    pub display_name: String,
    /// 解析后的可执行文件路径。
    pub path: String,
    /// `claude -v` 等探活得到的版本；探活失败时为空。
    pub version: Option<String>,
}

/// 一次 CLI 评审的配置。`executable` 为空时使用探测结果。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiCliConfig {
    pub id: String,
    pub executable: String,
    /// 是否允许写入类工具；默认应关闭。
    pub write_permission: bool,
}

/// CLI 写权限的产品默认值（关闭）。
#[uniffi::export]
pub fn default_ai_cli_write_permission() -> bool {
    false
}

/// 探测本机已安装、且 GitDeck 能用于评审的 CLI。
#[uniffi::export]
pub fn detect_ai_clis() -> Vec<DetectedAiCli> {
    let mut found = Vec::new();
    if let Some(cli) = detect_one(CLI_CLAUDE, "Claude Code") {
        found.push(cli);
    }
    found
}

/// 解析用户选择的 CLI：优先使用指定路径，否则用探测结果。
#[uniffi::export]
pub fn resolve_ai_cli(
    id: String,
    executable: String,
) -> std::result::Result<DetectedAiCli, CoreError> {
    resolve_ai_cli_inner(&id, &executable)
}

#[uniffi::export]
impl Repository {
    /// 在后台线程开始 CLI 评审，进度与结果经 `listener` 回调；返回的句柄可取消评审。
    pub fn start_ai_cli_review(
        self: Arc<Self>,
        cli: AiCliConfig,
        scope: ReviewScope,
        options: ReviewOptions,
        listener: Arc<dyn ReviewListener>,
    ) -> Arc<AiTask> {
        let task = AiTask::new();
        let handle = Arc::clone(&task);
        let spawned = std::thread::Builder::new()
            .name("gitdeck-ai-cli-review".into())
            .spawn({
                let listener = Arc::clone(&listener);
                move || {
                    let event =
                        match run_cli_review(&self, &cli, &scope, &options, &handle, &*listener) {
                            Ok(result) => ReviewEvent::Finished { result },
                            Err(error) => ReviewEvent::Failed { error },
                        };
                    listener.on_event(event);
                }
            });
        if let Err(e) = spawned {
            listener.on_event(ReviewEvent::Failed { error: e.into() });
        }
        task
    }
}

fn run_cli_review(
    repo: &Repository,
    cli: &AiCliConfig,
    scope: &ReviewScope,
    options: &ReviewOptions,
    task: &AiTask,
    listener: &dyn ReviewListener,
) -> Result<ReviewResult> {
    let resolved = resolve_ai_cli_inner(&cli.id, &cli.executable)?;
    let prep = review::prepare_review_session(repo, scope, options)?;
    listener.on_event(ReviewEvent::Started {
        files: prep.files.clone(),
        excluded: prep.excluded.clone(),
        truncated: prep.truncated,
    });
    if prep.files.is_empty() {
        return Ok(ReviewResult {
            summary: String::new(),
            findings: Vec::new(),
            revision: prep.revision,
            turns: 0,
            input_tokens: 0,
            output_tokens: 0,
            incomplete: false,
        });
    }
    task.check()?;
    let context = ToolContext {
        repo,
        filter: &prep.filter,
        revision: prep.revision.clone(),
        write_permission: cli.write_permission,
    };
    let system = review::system_prompt(options, true, cli.write_permission, prep.rules.as_deref());
    let (max_turns, budget) = review::review_limits(options);
    let tools = tools::tool_specs(cli.write_permission);
    match resolved.id.as_str() {
        CLI_CLAUDE => claude::run(
            &resolved,
            repo,
            &system,
            &prep.prompt,
            context,
            tools,
            max_turns,
            budget,
            task,
            listener,
            prep.revision,
        ),
        CLI_PROTOCOL => {
            let mut conversation =
                protocol::conversation(&resolved.path, system, tools, repo, task)?;
            conversation.push_user_text(&prep.prompt);
            review::run_tool_agent(
                conversation,
                context,
                task,
                listener,
                true,
                max_turns,
                budget,
                prep.revision,
            )
        }
        other => Err(CoreError::AiCliNotFound {
            name: other.to_owned(),
        }),
    }
}

fn resolve_ai_cli_inner(id: &str, executable: &str) -> Result<DetectedAiCli> {
    let id = id.trim();
    let executable = executable.trim();
    if !executable.is_empty() {
        let path = PathBuf::from(executable);
        if !is_runnable(&path) {
            return Err(CoreError::AiCliNotFound {
                name: executable.to_owned(),
            });
        }
        let id = if id.is_empty() {
            path.file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(CLI_PROTOCOL)
                .to_owned()
        } else {
            id.to_owned()
        };
        return Ok(probe(&id, display_name(&id), &path));
    }
    if id.is_empty() || id == CLI_CLAUDE {
        return detect_one(CLI_CLAUDE, "Claude Code").ok_or_else(|| CoreError::AiCliNotFound {
            name: CLI_CLAUDE.into(),
        });
    }
    if id == CLI_PROTOCOL {
        return Err(CoreError::AiCliNotFound {
            name: format!("{id} (set executable to a protocol CLI)"),
        });
    }
    Err(CoreError::AiCliNotFound {
        name: id.to_owned(),
    })
}

fn detect_one(id: &str, display: &str) -> Option<DetectedAiCli> {
    candidates(id)
        .into_iter()
        .find_map(|path| is_runnable(&path).then(|| probe(id, display, &path)))
}

fn display_name(id: &str) -> &str {
    match id {
        CLI_CLAUDE => "Claude Code",
        CLI_PROTOCOL => "GitDeck CLI protocol",
        other => other,
    }
}

fn candidates(id: &str) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = which::which_all(id)
        .map(|it| it.collect())
        .unwrap_or_default();
    #[cfg(windows)]
    {
        if let Ok(extra) = which::which_all(format!("{id}.cmd")) {
            paths.extend(extra);
        }
        if let Ok(extra) = which::which_all(format!("{id}.exe")) {
            paths.extend(extra);
        }
    }
    paths.extend(well_known_paths(id));
    let mut seen = std::collections::HashSet::new();
    paths
        .into_iter()
        .filter(|p| is_runnable(p))
        .filter(|p| seen.insert(std::fs::canonicalize(p).unwrap_or_else(|_| p.clone())))
        .collect()
}

fn well_known_paths(id: &str) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"));
    if let Some(home) = home {
        let home = PathBuf::from(home);
        paths.push(home.join(".local/bin").join(id));
        paths.push(home.join(".claude/local").join(id));
        paths.push(home.join(".local/bin").join(format!("{id}.exe")));
        paths.push(home.join("AppData/Roaming/npm").join(id));
        paths.push(home.join("AppData/Roaming/npm").join(format!("{id}.cmd")));
        paths.push(
            home.join("AppData/Local/Programs")
                .join(id)
                .join(format!("{id}.exe")),
        );
    }
    if id == CLI_CLAUDE {
        paths.push(PathBuf::from("/opt/homebrew/bin/claude"));
        paths.push(PathBuf::from("/usr/local/bin/claude"));
        paths.push(PathBuf::from("/usr/bin/claude"));
    }
    paths
}

fn is_runnable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn probe(id: &str, display: &str, path: &Path) -> DetectedAiCli {
    DetectedAiCli {
        id: id.to_owned(),
        display_name: display.to_owned(),
        path: path.to_string_lossy().into_owned(),
        version: probe_version(path),
    }
}

fn probe_version(path: &Path) -> Option<String> {
    for arg in ["-v", "--version"] {
        if let Some(text) = run_with_timeout(path, &[arg], Duration::from_secs(3)) {
            let line = text.lines().find(|l| !l.trim().is_empty())?.trim();
            if line.is_empty() {
                continue;
            }
            return Some(line.to_owned());
        }
    }
    None
}

fn run_with_timeout(path: &Path, args: &[&str], timeout: Duration) -> Option<String> {
    let mut child = Command::new(path)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let outcome = wait_or_kill(&mut child, timeout);
    match outcome {
        Ok(true) => {
            let out = child.wait_with_output().ok()?;
            let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
            if text.trim().is_empty() {
                text = String::from_utf8_lossy(&out.stderr).into_owned();
            }
            Some(text)
        }
        _ => None,
    }
}

/// 等待子进程结束；超时或失败时杀死进程树，返回是否在时限内退出。
fn wait_or_kill(child: &mut Child, timeout: Duration) -> std::io::Result<bool> {
    let start = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(false);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub(crate) fn kill_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_permission_defaults_to_off() {
        assert!(!default_ai_cli_write_permission());
        let config = AiCliConfig {
            id: CLI_CLAUDE.into(),
            executable: String::new(),
            write_permission: default_ai_cli_write_permission(),
        };
        assert!(!config.write_permission);
    }

    #[test]
    fn missing_cli_is_a_user_facing_error() {
        let err = resolve_ai_cli_inner("definitely-not-an-installed-cli", "").unwrap_err();
        assert!(
            matches!(err, CoreError::AiCliNotFound { name } if name.contains("definitely-not-an-installed-cli"))
        );
        let err = resolve_ai_cli_inner(CLI_CLAUDE, "/no/such/claude-binary").unwrap_err();
        assert!(matches!(err, CoreError::AiCliNotFound { .. }));
    }
}
