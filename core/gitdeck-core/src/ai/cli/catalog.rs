//! 已确认可非交互调用的主流 Agent CLI 目录。
//!
//! `gitdeck-protocol` 仅用于测试与自定义适配，不会自动探测。
//! 各 CLI 的参数只使用官方文档中的非交互接口，不臆造 API。

use std::path::{Path, PathBuf};

use super::{CLI_CLAUDE, CLI_PROTOCOL};

/// 提示词如何传给子进程。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptInput {
    /// 把组合后的 system+user 提示写到标准输入（例如 `codex exec -`）。
    CombinedStdin,
    /// 把组合后的提示写到临时文件，路径由参数构建函数使用。
    CombinedFile,
    /// system 提示写到临时文件，user 提示走标准输入（例如 `pi --system-prompt`）。
    SystemFileUserStdin,
    /// 把组合后的提示作为 `--print` / `-p` 的参数（例如 `agy --print`）。
    CombinedAsPromptFlag,
}

/// 如何从成功退出的子进程输出中取出最终回复。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    /// 整个标准输出即为最终回复（进度应在 stderr，如 `codex exec`）。
    PlainStdout,
    /// Gemini / Antigravity 一类 envelope：`{"response","error","stats"|"usage"}`。
    ResponseEnvelope,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerKind {
    ClaudeMcp,
    Protocol,
    Print,
}

pub struct PrintProfile {
    pub prompt: PromptInput,
    pub output: OutputFormat,
    pub args: fn(ctx: &PrintArgCtx<'_>) -> Vec<String>,
}

pub struct PrintArgCtx<'a> {
    pub system_file: &'a Path,
    pub prompt_file: &'a Path,
    pub write_permission: bool,
    pub max_turns: u32,
}

pub struct CliSpec {
    pub id: &'static str,
    pub display_name: &'static str,
    pub auto_detect: bool,
    /// `--help` / `-h` 输出中任一片段命中即视为该 CLI，避免 `pi` 等短名字误探。
    pub fingerprint: &'static [&'static str],
    pub extra_bin_dirs: fn(home: &Path) -> Vec<PathBuf>,
    pub runner: RunnerKind,
    pub print: Option<PrintProfile>,
}

pub fn supported() -> &'static [CliSpec] {
    &SPECS
}

pub fn find(id: &str) -> Option<&'static CliSpec> {
    SPECS.iter().find(|spec| spec.id == id)
}

pub fn display_name(id: &str) -> &str {
    find(id).map(|spec| spec.display_name).unwrap_or(id)
}

fn no_extra(_home: &Path) -> Vec<PathBuf> {
    Vec::new()
}

fn pi_extra(home: &Path) -> Vec<PathBuf> {
    // 官方独立安装会把二进制放在 `~/.pi/agent/bin`，再软链接到 `~/.local/bin/pi`。
    vec![home.join(".pi/agent/bin")]
}

fn codex_extra(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Applications/Codex.app/Contents/Resources"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources"),
    ]
}

fn agy_extra(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Applications/Gemini.app/Contents/Helpers"),
        PathBuf::from("/Applications/Gemini.app/Contents/Helpers"),
    ]
}

fn cursor_agent_extra(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".local/bin"),
        home.join(".cursor/bin"),
        home.join(".cursor-agent/bin"),
    ]
}

fn hermes_extra(home: &Path) -> Vec<PathBuf> {
    vec![home.join(".hermes/hermes-agent/venv/bin")]
}

const SPECS: [CliSpec; 13] = [
    CliSpec {
        id: CLI_CLAUDE,
        display_name: "Claude Code",
        auto_detect: true,
        fingerprint: &[],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::ClaudeMcp,
        print: None,
    },
    CliSpec {
        id: "codex",
        display_name: "Codex",
        auto_detect: true,
        fingerprint: &[],
        extra_bin_dirs: codex_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedStdin,
            output: OutputFormat::PlainStdout,
            args: codex_args,
        }),
    },
    CliSpec {
        id: "grok",
        display_name: "Grok",
        auto_detect: true,
        fingerprint: &[],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedFile,
            output: OutputFormat::PlainStdout,
            args: grok_args,
        }),
    },
    CliSpec {
        id: "pi",
        display_name: "Pi",
        auto_detect: true,
        // `pi` 太短，必须能对上 Pi coding agent 的帮助信息。
        fingerprint: &["AI coding assistant", "--system-prompt", "pi-coding-agent"],
        extra_bin_dirs: pi_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::SystemFileUserStdin,
            output: OutputFormat::PlainStdout,
            args: pi_args,
        }),
    },
    CliSpec {
        id: "gemini",
        display_name: "Gemini CLI",
        auto_detect: true,
        fingerprint: &[],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedStdin,
            output: OutputFormat::ResponseEnvelope,
            args: gemini_args,
        }),
    },
    CliSpec {
        id: "copilot",
        display_name: "GitHub Copilot",
        auto_detect: true,
        fingerprint: &["--prompt", "GitHub Copilot"],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedFile,
            output: OutputFormat::PlainStdout,
            args: copilot_args,
        }),
    },
    CliSpec {
        id: "omp",
        display_name: "Oh My Pi",
        auto_detect: true,
        fingerprint: &[
            "Non-interactive mode: process prompt and exit",
            "--approval-mode",
        ],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedFile,
            output: OutputFormat::PlainStdout,
            args: omp_args,
        }),
    },
    CliSpec {
        id: "agy",
        display_name: "Antigravity",
        auto_detect: true,
        fingerprint: &["Usage of agy", "--dangerously-skip-permissions"],
        extra_bin_dirs: agy_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedAsPromptFlag,
            output: OutputFormat::ResponseEnvelope,
            args: agy_args,
        }),
    },
    CliSpec {
        id: "hermes",
        display_name: "Hermes",
        auto_detect: true,
        fingerprint: &["Hermes Agent", "tool-calling capabilities"],
        extra_bin_dirs: hermes_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedFile,
            output: OutputFormat::PlainStdout,
            args: hermes_args,
        }),
    },
    CliSpec {
        id: "agent",
        display_name: "Cursor Agent",
        auto_detect: true,
        fingerprint: &["CURSOR_API_KEY", "--output-format"],
        extra_bin_dirs: cursor_agent_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedAsPromptFlag,
            output: OutputFormat::PlainStdout,
            args: cursor_agent_args,
        }),
    },
    CliSpec {
        id: "kiro-cli",
        display_name: "Kiro",
        auto_detect: true,
        fingerprint: &["--no-interactive", "--trust-tools"],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedStdin,
            output: OutputFormat::PlainStdout,
            args: kiro_args,
        }),
    },
    CliSpec {
        id: "qwen",
        display_name: "Qwen Code",
        auto_detect: true,
        fingerprint: &["Qwen Code", "--approval-mode", "--output-format"],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Print,
        print: Some(PrintProfile {
            prompt: PromptInput::CombinedStdin,
            output: OutputFormat::PlainStdout,
            args: qwen_args,
        }),
    },
    CliSpec {
        id: CLI_PROTOCOL,
        display_name: "GitDeck CLI protocol",
        auto_detect: false,
        fingerprint: &[],
        extra_bin_dirs: no_extra,
        runner: RunnerKind::Protocol,
        print: None,
    },
];

pub fn codex_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let _ = (ctx.system_file, ctx.prompt_file, ctx.max_turns);
    let mut args = vec!["exec".into(), "--ephemeral".into()];
    if ctx.write_permission {
        args.extend(["--sandbox".into(), "workspace-write".into()]);
    }
    args.push("-".into());
    args
}

pub fn grok_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mut args = vec![
        "--prompt-file".into(),
        ctx.prompt_file.to_string_lossy().into_owned(),
        "--output-format".into(),
        "plain".into(),
        "--no-auto-update".into(),
        "--max-turns".into(),
        ctx.max_turns.to_string(),
    ];
    // 无写权限时不自动批准工具，避免未授权改文件；工具若要批准可能失败或结束，而不是默默写入。
    if ctx.write_permission {
        args.push("--always-approve".into());
    }
    args
}

pub fn pi_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mut args = vec![
        "--print".into(),
        "--no-session".into(),
        "--system-prompt".into(),
        ctx.system_file.to_string_lossy().into_owned(),
    ];
    if !ctx.write_permission {
        // 默认工具含 bash/edit/write；评审在未授权写入时应只读。
        args.extend(["--tools".into(), "read".into()]);
    }
    args
}

pub fn gemini_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mode = if ctx.write_permission {
        "auto_edit"
    } else {
        "plan"
    };
    vec![
        "--output-format".into(),
        "json".into(),
        "--approval-mode".into(),
        mode.into(),
        "--skip-trust".into(),
    ]
}

pub fn copilot_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mut args = vec![
        "--silent".into(),
        "--no-ask-user".into(),
        "--allow-tool".into(),
        "read".into(),
    ];
    if ctx.write_permission {
        args.extend(["--allow-tool".into(), "write".into()]);
    } else {
        args.extend(["--deny-tool".into(), "write".into()]);
    }
    // `@path` 把提示文件作为上下文纳入非交互 `-p` 调用。
    args.push("-p".into());
    args.push(format!("@{}", ctx.prompt_file.display()));
    args
}

fn prompt_text(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

pub fn omp_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mut args = vec![
        "--print".into(),
        "--no-session".into(),
        format!("@{}", ctx.prompt_file.display()),
    ];
    if !ctx.write_permission {
        args.extend(["--tools".into(), "read".into()]);
    }
    args
}

pub fn agy_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    // `--print` 的值才是提示词；其它开关必须放在它前面，stdin 会被忽略。
    let mode = if ctx.write_permission { "auto" } else { "plan" };
    vec![
        "--output-format".into(),
        "json".into(),
        "--mode".into(),
        mode.into(),
        "--print".into(),
        prompt_text(ctx.prompt_file),
    ]
}

pub fn hermes_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let mut args = vec![
        "chat".into(),
        "--query-file".into(),
        ctx.prompt_file.to_string_lossy().into_owned(),
        "--oneshot".into(),
        "-Q".into(),
        "--format".into(),
        "text".into(),
    ];
    if ctx.write_permission {
        args.push("--yolo".into());
    } else {
        // `safe` 工具集明确不含 file/terminal，避免 headless 下写入。
        // 评审 diff 已在提示词中。
        args.extend(["--toolsets".into(), "safe".into()]);
    }
    args
}

pub fn cursor_agent_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    // `--print` 是布尔开关；提示词作为后续位置参数。Ask 模式官方定义为只回答、不改文件。
    let mut args = vec![
        "--print".into(),
        "--output-format".into(),
        "text".into(),
        "--trust".into(),
    ];
    if !ctx.write_permission {
        args.extend(["--mode".into(), "ask".into()]);
    }
    args.push(prompt_text(ctx.prompt_file));
    args
}

pub fn kiro_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    let _ = (ctx.system_file, ctx.prompt_file, ctx.max_turns);
    // 提示走 stdin；只信任只读工具，避免 headless 下误写。
    vec![
        "chat".into(),
        "--v3".into(),
        "--no-interactive".into(),
        "--trust-tools=read_file,grep_search".into(),
    ]
}

pub fn qwen_args(ctx: &PrintArgCtx<'_>) -> Vec<String> {
    // 官方 headless：stdin 或 `-p`，`--approval-mode plan` 只读。
    // 默认文本输出（JSON 是消息数组，不是 Gemini envelope）。
    if ctx.write_permission {
        vec!["--approval-mode".into(), "auto-edit".into()]
    } else {
        vec![
            "--approval-mode".into(),
            "plan".into(),
            "--exclude-tools".into(),
            "shell,write,edit".into(),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args_for(builder: fn(&PrintArgCtx<'_>) -> Vec<String>, write: bool) -> Vec<String> {
        let dir = std::env::temp_dir().join(format!(
            "gitdeck-cli-args-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let system = dir.join("sys.txt");
        let prompt = dir.join("prompt.txt");
        std::fs::write(&system, "system").unwrap();
        std::fs::write(&prompt, "review please").unwrap();
        let ctx = PrintArgCtx {
            system_file: &system,
            prompt_file: &prompt,
            write_permission: write,
            max_turns: 24,
        };
        let args = builder(&ctx);
        let _ = std::fs::remove_dir_all(&dir);
        args
    }

    #[test]
    fn catalog_covers_known_clis_and_hides_protocol() {
        let ids: Vec<_> = supported().iter().map(|s| s.id).collect();
        assert_eq!(
            ids,
            vec![
                "claude",
                "codex",
                "grok",
                "pi",
                "gemini",
                "copilot",
                "omp",
                "agy",
                "hermes",
                "agent",
                "kiro-cli",
                "qwen",
                "gitdeck-protocol"
            ]
        );
        assert!(find("claude").unwrap().auto_detect);
        assert!(!find("gitdeck-protocol").unwrap().auto_detect);
        assert_eq!(display_name("codex"), "Codex");
        assert_eq!(display_name("unknown-cli"), "unknown-cli");
    }

    #[test]
    fn codex_exec_reads_stdin_and_only_enables_writes_when_allowed() {
        let off = args_for(codex_args, false);
        assert_eq!(off, vec!["exec", "--ephemeral", "-"]);
        let on = args_for(codex_args, true);
        assert_eq!(
            on,
            vec!["exec", "--ephemeral", "--sandbox", "workspace-write", "-"]
        );
    }

    #[test]
    fn grok_uses_prompt_file_and_gates_always_approve() {
        let off = args_for(grok_args, false);
        assert!(off.contains(&"--prompt-file".into()));
        assert!(off.iter().any(|a| a.ends_with("prompt.txt")));
        assert!(off.contains(&"--max-turns".into()));
        assert!(!off.iter().any(|a| a == "--always-approve"));
        let on = args_for(grok_args, true);
        assert!(on.iter().any(|a| a == "--always-approve"));
    }

    #[test]
    fn pi_print_is_readonly_by_default() {
        let off = args_for(pi_args, false);
        assert!(off.contains(&"--print".into()));
        assert!(off.contains(&"--no-session".into()));
        assert!(off.contains(&"--system-prompt".into()));
        assert!(off.iter().any(|a| a.ends_with("sys.txt")));
        let tools = off.iter().position(|a| a == "--tools").unwrap();
        assert_eq!(off[tools + 1], "read");
        let on = args_for(pi_args, true);
        assert!(!on.iter().any(|a| a == "--tools"));
    }

    #[test]
    fn gemini_uses_plan_mode_unless_writes_are_allowed() {
        let off = args_for(gemini_args, false);
        assert_eq!(
            off,
            vec![
                "--output-format",
                "json",
                "--approval-mode",
                "plan",
                "--skip-trust"
            ]
        );
        let on = args_for(gemini_args, true);
        assert!(on.contains(&"auto_edit".into()));
    }

    #[test]
    fn copilot_denies_write_tools_by_default() {
        let off = args_for(copilot_args, false);
        assert!(off.contains(&"--silent".into()));
        assert!(off.contains(&"--no-ask-user".into()));
        assert!(off.contains(&"--deny-tool".into()));
        assert!(off.contains(&"write".into()));
        assert!(off.iter().any(|a| a == "-p"));
        assert!(
            off.iter()
                .any(|a| a.starts_with('@') && a.ends_with("prompt.txt"))
        );
        let on = args_for(copilot_args, true);
        assert!(!on.windows(2).any(|w| w == ["--deny-tool", "write"]));
        assert!(on.windows(2).any(|w| w == ["--allow-tool", "write"]));
    }

    #[test]
    fn omp_print_is_readonly_by_default() {
        let off = args_for(omp_args, false);
        assert!(off.contains(&"--print".into()));
        assert!(off.contains(&"--no-session".into()));
        assert!(
            off.iter()
                .any(|a| a.starts_with('@') && a.ends_with("prompt.txt"))
        );
        assert!(off.windows(2).any(|w| w == ["--tools", "read"]));
        let on = args_for(omp_args, true);
        assert!(!on.iter().any(|a| a == "--tools"));
    }

    #[test]
    fn agy_uses_plan_mode_and_print_flag_value() {
        let off = args_for(agy_args, false);
        assert_eq!(off[0], "--output-format");
        assert!(off.contains(&"plan".into()));
        assert_eq!(off[off.len() - 2], "--print");
        assert_eq!(off.last().map(String::as_str), Some("review please"));
        let on = args_for(agy_args, true);
        assert!(on.contains(&"auto".into()));
    }

    #[test]
    fn hermes_uses_safe_toolset_and_does_not_yolo_when_readonly() {
        let off = args_for(hermes_args, false);
        assert!(off.contains(&"chat".into()));
        assert!(off.contains(&"--oneshot".into()));
        assert!(off.windows(2).any(|w| w == ["--toolsets", "safe"]));
        assert!(!off.iter().any(|a| a == "--yolo"));
        let on = args_for(hermes_args, true);
        assert!(on.iter().any(|a| a == "--yolo"));
        assert!(!on.windows(2).any(|w| w == ["--toolsets", "safe"]));
    }

    #[test]
    fn cursor_agent_uses_ask_mode_when_readonly() {
        let off = args_for(cursor_agent_args, false);
        assert!(off.windows(2).any(|w| w == ["--mode", "ask"]));
        assert!(off.contains(&"--trust".into()));
        assert_eq!(off.last().map(String::as_str), Some("review please"));
        let on = args_for(cursor_agent_args, true);
        assert!(!on.windows(2).any(|w| w == ["--mode", "ask"]));
    }

    #[test]
    fn kiro_trusts_only_readonly_tools() {
        let args = args_for(kiro_args, false);
        assert!(args.contains(&"chat".into()));
        assert!(args.contains(&"--no-interactive".into()));
        assert!(args.iter().any(|a| a.contains("read_file")));
        assert!(!args.iter().any(|a| a.contains("trust-all-tools")));
    }

    #[test]
    fn qwen_plan_mode_excludes_write_tools() {
        let off = args_for(qwen_args, false);
        assert!(off.windows(2).any(|w| w == ["--approval-mode", "plan"]));
        assert!(
            off.windows(2)
                .any(|w| w == ["--exclude-tools", "shell,write,edit"])
        );
        let on = args_for(qwen_args, true);
        assert!(on.windows(2).any(|w| w == ["--approval-mode", "auto-edit"]));
        assert!(!on.iter().any(|a| a == "--exclude-tools"));
    }
}
