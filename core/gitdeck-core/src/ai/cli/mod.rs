//! 本机 CLI 评审：探测已安装的命令行工具，并以 GitDeck 的工具面驱动评审。
//!
//! GitDeck 负责执行工具（含敏感文件过滤）。`claude` 通过本进程内的 MCP 服务
//! 暴露与 HTTP Agent 相同的工具；测试与通用适配则使用行分隔 JSON 协议。
//! 其他已支持的 Agent CLI（Codex、Grok、Pi、Gemini、Copilot）走非交互
//! print/exec 路径：把评审提示交给本机已登录的 CLI，再解析最终文本。
//! 写入类工具单独门控，默认关闭。

mod catalog;
mod claude;
mod command;
mod mcp;
mod print;
mod protocol;

use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
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
///
/// 各 CLI 并行探测，避免设置页把十几个候选串行跑完要等好几秒。
#[uniffi::export]
pub fn detect_ai_clis() -> Vec<DetectedAiCli> {
    let specs: Vec<&catalog::CliSpec> = catalog::supported()
        .iter()
        .filter(|spec| spec.auto_detect)
        .collect();
    std::thread::scope(|scope| {
        let handles: Vec<_> = specs
            .iter()
            .map(|spec| scope.spawn(|| detect_one(spec.id, spec.display_name)))
            .collect();
        handles
            .into_iter()
            .filter_map(|handle| handle.join().ok().flatten())
            .collect()
    })
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
    let runner = catalog::find(&resolved.id).map(|spec| spec.runner);
    let with_tools = matches!(
        runner,
        Some(catalog::RunnerKind::ClaudeMcp | catalog::RunnerKind::Protocol)
    );
    let system = review::system_prompt(
        options,
        with_tools,
        cli.write_permission && with_tools,
        prep.rules.as_deref(),
    );
    let (max_turns, budget) = review::review_limits(options);
    let tools = tools::tool_specs(cli.write_permission);
    match runner {
        Some(catalog::RunnerKind::ClaudeMcp) => claude::run(
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
        Some(catalog::RunnerKind::Protocol) => {
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
        Some(catalog::RunnerKind::Print) => print::run(
            &resolved,
            repo,
            &system,
            &prep.prompt,
            context,
            max_turns,
            task,
            listener,
            prep.revision,
        ),
        None => Err(CoreError::AiCliNotFound {
            name: resolved.id.clone(),
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
        let display = catalog::display_name(&id).to_owned();
        return Ok(probe(&id, &display, &path));
    }
    if id.is_empty() || id == CLI_CLAUDE {
        return detect_one(CLI_CLAUDE, catalog::display_name(CLI_CLAUDE)).ok_or_else(|| {
            CoreError::AiCliNotFound {
                name: CLI_CLAUDE.into(),
            }
        });
    }
    if let Some(spec) = catalog::find(id) {
        if matches!(spec.runner, catalog::RunnerKind::Protocol) {
            return Err(CoreError::AiCliNotFound {
                name: format!("{} (set executable to a protocol CLI)", spec.id),
            });
        }
        return detect_one(spec.id, spec.display_name).ok_or_else(|| CoreError::AiCliNotFound {
            name: spec.id.into(),
        });
    }
    Err(CoreError::AiCliNotFound {
        name: id.to_owned(),
    })
}

fn detect_one(id: &str, display: &str) -> Option<DetectedAiCli> {
    let spec = catalog::find(id);
    candidates(id).into_iter().find_map(|path| {
        if !is_runnable(&path) {
            return None;
        }
        if !is_callable(spec, &path) {
            return None;
        }
        Some(probe(id, display, &path))
    })
}

/// 候选必须真正能跑起来：有指纹的要能打出帮助，没有指纹的至少要能成功打印版本或帮助。
/// 包装脚本在 PATH 缺 node、或本机二进制缺失时会被跳过，继续找下一个路径。
fn is_callable(spec: Option<&catalog::CliSpec>, path: &Path) -> bool {
    if let Some(spec) = spec {
        if !spec.fingerprint.is_empty() {
            return fingerprint_matches(spec, path);
        }
    }
    probe_version(path).is_some() || help_text(path).is_some()
}

fn fingerprint_matches(spec: &catalog::CliSpec, path: &Path) -> bool {
    if spec.fingerprint.is_empty() {
        return true;
    }
    let Some(text) = help_text(path) else {
        return false;
    };
    let lower = text.to_ascii_lowercase();
    spec.fingerprint
        .iter()
        .any(|needle| lower.contains(&needle.to_ascii_lowercase()))
}

/// Settings 探测用的时限：卡住的包装脚本应尽快放弃，改试下一个候选。
const HELP_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

fn help_text(path: &Path) -> Option<String> {
    for arg in ["--help", "-h"] {
        match run_with_status(path, &[arg], HELP_PROBE_TIMEOUT) {
            Some((code, text)) => {
                if looks_like_spawn_failure(&text) {
                    continue;
                }
                if code == 0 || text_looks_like_help(&text) {
                    return Some(text);
                }
            }
            // 超时或无法启动时不再试下一个参数，避免探测被拉长。
            None => return None,
        }
    }
    None
}

fn text_looks_like_help(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("usage") || lower.contains("options") || lower.contains("commands")
}

fn looks_like_spawn_failure(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("no such file or directory")
        || lower.contains("enoent")
        || lower.contains("is not recognized as")
        || lower.contains("the system cannot find")
        || lower.contains("command not found")
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
        if let Some(spec) = catalog::find(id) {
            for dir in (spec.extra_bin_dirs)(&home) {
                paths.push(dir.join(id));
                paths.push(dir.join(format!("{id}.exe")));
                paths.push(dir.join(format!("{id}.cmd")));
            }
        }
    }
    // 访达 / 程序坞启动时 PATH 往往没有 nvm。NVM_BIN 是当前选中的 Node bin。
    if let Some(bin) = std::env::var_os("NVM_BIN") {
        let bin = PathBuf::from(bin);
        paths.push(bin.join(id));
        paths.push(bin.join(format!("{id}.exe")));
        paths.push(bin.join(format!("{id}.cmd")));
    }
    let mut nvm_roots = Vec::new();
    if let Some(dir) = std::env::var_os("NVM_DIR") {
        nvm_roots.push(PathBuf::from(dir));
    }
    if let Some(dir) = std::env::var_os("NVM_HOME") {
        nvm_roots.push(PathBuf::from(dir));
    }
    if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
        let home = PathBuf::from(home);
        nvm_roots.push(home.join(".nvm"));
        nvm_roots.push(home.join("AppData/Roaming/nvm"));
    }
    paths.extend(nvm_install_paths(&nvm_roots, id));
    paths.push(PathBuf::from("/opt/homebrew/bin").join(id));
    paths.push(PathBuf::from("/usr/local/bin").join(id));
    paths.push(PathBuf::from("/usr/bin").join(id));
    paths
}

/// nvm（含 nvm-windows）安装根下的 CLI 路径：默认 alias 优先，其余按 Node 版本从新到旧。
fn nvm_install_paths(roots: &[PathBuf], id: &str) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for root in roots {
        let key = std::fs::canonicalize(root).unwrap_or_else(|_| root.clone());
        if !seen.insert(key) || !root.is_dir() {
            continue;
        }

        let mut versions = read_dir_dirs(&root.join("versions/node"));
        versions.sort_by(|a, b| cmp_node_version_desc(a, b));
        if let Some(default) = nvm_default_version_dir(root) {
            versions.retain(|path| path != &default);
            versions.insert(0, default);
        }
        for version in &versions {
            paths.push(version.join("bin").join(id));
            paths.push(version.join("bin").join(format!("{id}.exe")));
        }

        // nvm-windows：`%NVM_HOME%\v24.14.0\claude.cmd`
        let mut win_versions = read_dir_dirs(root);
        win_versions.retain(|path| parse_node_version(path).is_some());
        win_versions.sort_by(|a, b| cmp_node_version_desc(a, b));
        for version in win_versions {
            paths.push(version.join(id));
            paths.push(version.join(format!("{id}.cmd")));
            paths.push(version.join(format!("{id}.exe")));
        }
    }
    paths
}

fn read_dir_dirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect()
}

fn nvm_default_version_dir(root: &Path) -> Option<PathBuf> {
    let raw = std::fs::read_to_string(root.join("alias/default")).ok()?;
    let name = raw.trim();
    if name.is_empty() {
        return None;
    }
    [
        root.join("versions/node").join(name),
        root.join("versions/node").join(format!("v{name}")),
        root.join(name),
        root.join(format!("v{name}")),
    ]
    .into_iter()
    .find(|path| path.is_dir())
}

fn parse_node_version(path: &Path) -> Option<(u64, u64, u64)> {
    let name = path.file_name()?.to_str()?;
    let name = name.strip_prefix('v').unwrap_or(name);
    let mut parts = name.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next().unwrap_or("0").parse().ok()?;
    let patch = parts.next().unwrap_or("0").parse().ok()?;
    Some((major, minor, patch))
}

fn cmp_node_version_desc(a: &Path, b: &Path) -> std::cmp::Ordering {
    match (parse_node_version(a), parse_node_version(b)) {
        (Some(left), Some(right)) => right.cmp(&left),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => b.file_name().cmp(&a.file_name()),
    }
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
        version: if should_probe_version(id) {
            probe_version(path)
        } else {
            None
        },
    }
}

fn should_probe_version(id: &str) -> bool {
    // Hermes 的 `--version` / `-v` 会触发运行时依赖安装（甚至 git fetch），不能在探测时调用。
    id != "hermes"
}

fn probe_version(path: &Path) -> Option<String> {
    // 先试 `--version`：部分 CLI（如 Codex 官方二进制）把 `-v` 当成非法参数。
    for arg in ["--version", "-v"] {
        let Some((code, text)) = run_with_status(path, &[arg], VERSION_PROBE_TIMEOUT) else {
            // 超时则不再试下一个参数，避免 Settings 探测被卡住。
            return None;
        };
        if code != 0 || looks_like_spawn_failure(&text) {
            continue;
        }
        let line = text.lines().find(|l| !l.trim().is_empty())?.trim();
        if line.is_empty() || looks_like_spawn_failure(line) {
            continue;
        }
        return Some(line.to_owned());
    }
    None
}

fn run_with_status(path: &Path, args: &[&str], timeout: Duration) -> Option<(i32, String)> {
    let mut child = command::command(path)
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
            Some((out.status.code().unwrap_or(-1), text))
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

    #[test]
    fn nvm_install_paths_prefers_default_alias_then_newer_node() {
        let root = std::env::temp_dir().join(format!(
            "gitdeck-nvm-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let cleanup = |root: &Path| {
            let _ = std::fs::remove_dir_all(root);
        };
        cleanup(&root);
        let v22_bin = root.join("versions/node/v22.0.0/bin");
        let v24_bin = root.join("versions/node/v24.14.0/bin");
        std::fs::create_dir_all(&v22_bin).unwrap();
        std::fs::create_dir_all(&v24_bin).unwrap();
        std::fs::write(v22_bin.join("claude"), b"").unwrap();
        std::fs::write(v24_bin.join("claude"), b"").unwrap();
        std::fs::create_dir_all(root.join("alias")).unwrap();
        std::fs::write(root.join("alias/default"), "v22.0.0\n").unwrap();

        let claude_bins = |root: &Path| -> Vec<PathBuf> {
            nvm_install_paths(&[root.to_path_buf()], "claude")
                .into_iter()
                .filter(|path| path.file_name().and_then(|name| name.to_str()) == Some("claude"))
                .collect()
        };

        assert_eq!(
            claude_bins(&root),
            vec![v22_bin.join("claude"), v24_bin.join("claude")]
        );

        std::fs::remove_file(root.join("alias/default")).unwrap();
        assert_eq!(
            claude_bins(&root),
            vec![v24_bin.join("claude"), v22_bin.join("claude")]
        );

        cleanup(&root);
    }

    #[test]
    fn nvm_install_paths_finds_nvm_windows_layout() {
        let root = std::env::temp_dir().join(format!(
            "gitdeck-nvm-win-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let v24 = root.join("v24.14.0");
        std::fs::create_dir_all(&v24).unwrap();
        std::fs::write(v24.join("claude.cmd"), b"").unwrap();

        let paths = nvm_install_paths(&[root.clone()], "claude");
        assert!(paths.contains(&v24.join("claude.cmd")));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn pi_fingerprint_rejects_unrelated_binaries() {
        let dir = std::env::temp_dir().join(format!(
            "gitdeck-pi-fp-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let other = dir.join("pi");
        std::fs::write(
            &other,
            "#!/bin/sh\nif [ \"$1\" = \"--help\" ]; then echo \"the pi package installer\"; exit 0; fi\nexit 1\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&other, std::fs::Permissions::from_mode(0o755)).unwrap();
        let spec = catalog::find("pi").unwrap();
        assert!(!fingerprint_matches(spec, &other));

        let agent = dir.join("pi-agent");
        std::fs::write(
            &agent,
            "#!/bin/sh\nif [ \"$1\" = \"--help\" ]; then echo \"pi - AI coding assistant with read, bash, edit, write tools\"; exit 0; fi\necho 1.1.0\n",
        )
        .unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(fingerprint_matches(spec, &agent));
        let _ = std::fs::remove_dir_all(&dir);
    }

    struct EnvGuard {
        key: &'static str,
        old: Option<std::ffi::OsString>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let old = std::env::var_os(key);
            unsafe { std::env::set_var(key, value.as_ref()) };
            Self { key, old }
        }

        fn remove(key: &'static str) -> Self {
            let old = std::env::var_os(key);
            unsafe { std::env::remove_var(key) };
            Self { key, old }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            unsafe {
                match &self.old {
                    Some(value) => std::env::set_var(self.key, value),
                    None => std::env::remove_var(self.key),
                }
            }
        }
    }

    fn unique_testdir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "{prefix}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[cfg(unix)]
    fn write_exec(path: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, body).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn spawn_failure_is_not_treated_as_a_version() {
        let dir = unique_testdir("gitdeck-cli-broken");
        let broken = dir.join("codex");
        write_exec(
            &broken,
            "#!/bin/sh\necho 'Error: spawn /missing/codex ENOENT' >&2\nexit 1\n",
        );
        assert!(probe_version(&broken).is_none());
        assert!(!is_callable(catalog::find("codex"), &broken));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn detect_skips_broken_path_and_falls_through_to_working_cli() {
        let root = unique_testdir("gitdeck-cli-fallback");
        let broken = root.join("broken/codex");
        write_exec(
            &broken,
            "#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n",
        );
        let working = root.join("working/codex");
        write_exec(
            &working,
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex-cli 0.133.0'; exit 0; fi\necho unexpected >&2\nexit 1\n",
        );
        // 直接断言可调用性：损坏包装会被拒绝，可用二进制会被接受。
        assert!(!is_callable(catalog::find("codex"), &broken));
        assert!(is_callable(catalog::find("codex"), &working));
        assert_eq!(
            probe_version(&working).as_deref(),
            Some("codex-cli 0.133.0")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn detect_skips_wrong_pi_and_finds_managed_install() {
        let _guard = ENV_LOCK.lock().unwrap();
        let root = unique_testdir("gitdeck-cli-pi-home");
        let wrong = root.join("wrong/pi");
        write_exec(
            &wrong,
            "#!/bin/sh\nif [ \"$1\" = \"--help\" ] || [ \"$1\" = \"-h\" ]; then echo 'the pi package installer'; exit 0; fi\nexit 1\n",
        );
        let real = root.join(".local/bin/pi");
        // 真实 Pi 是 env node 包装；本测试把 node 只放在 HOME/.nvm 下，模拟 GUI 最小 PATH。
        write_exec(&real, "#!/bin/sh\nexec node \"$@\"\n");
        let node = root.join(".nvm/versions/node/v24.14.0/bin/node");
        write_exec(
            &node,
            "#!/bin/sh\nif [ \"$1\" = \"--help\" ] || [ \"$1\" = \"-h\" ]; then echo 'pi - AI coding assistant with read, bash, edit, write tools'; echo '  --system-prompt'; exit 0; fi\nif [ \"$1\" = \"--version\" ] || [ \"$1\" = \"-v\" ]; then echo 1.1.0; exit 0; fi\nexit 1\n",
        );

        // GUI 启动常见的最小 PATH：错误的 `pi` 在最前，系统目录没有 node。
        let _home = EnvGuard::set("HOME", &root);
        let _nvm_bin = EnvGuard::remove("NVM_BIN");
        let _nvm_dir = EnvGuard::remove("NVM_DIR");
        let _path = EnvGuard::set(
            "PATH",
            format!("{}:/usr/bin:/bin", root.join("wrong").display()),
        );

        let found = detect_one("pi", "Pi").expect("real Pi should be detected via well-known path");
        assert!(
            found.path.ends_with(".local/bin/pi") || found.path.contains(".local/bin/pi"),
            "path was {}",
            found.path
        );
        assert!(fingerprint_matches(
            catalog::find("pi").unwrap(),
            Path::new(&found.path)
        ));
        assert!(!fingerprint_matches(catalog::find("pi").unwrap(), &wrong));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn hanging_help_is_abandoned_quickly() {
        let dir = unique_testdir("gitdeck-cli-hang");
        let hung = dir.join("hang");
        write_exec(&hung, "#!/bin/sh\nsleep 30\n");
        let start = Instant::now();
        assert!(help_text(&hung).is_none());
        assert!(
            start.elapsed() < Duration::from_secs(6),
            "hung help probe took {:?}",
            start.elapsed()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
}
