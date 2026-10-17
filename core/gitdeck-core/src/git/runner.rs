//! 定位并调用系统 git 可执行文件。
//!
//! 与 IDEA 一致，所有 git 操作都通过命令行完成；这里统一注入
//! 稳定输出所需的配置与环境变量，解析层只需面对确定的格式。

use std::ffi::OsStr;
use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::{CoreError, Result};

/// 支持的最低 git 版本（见 docs/DECISIONS.md 第 4 项）。
pub const MIN_GIT_VERSION: GitVersion = GitVersion {
    major: 2,
    minor: 30,
    patch: 0,
};

/// 用户或测试可通过该环境变量指定 git 路径，优先级最高。
pub const GIT_PATH_ENV: &str = "GITDECK_GIT";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct GitVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl GitVersion {
    /// 解析 `git --version` 输出，例如：
    /// `git version 2.54.0 (Apple Git-157)`、`git version 2.45.1.windows.1`。
    pub fn parse(output: &str) -> Option<Self> {
        let rest = output.trim().strip_prefix("git version ")?;
        let mut nums = rest
            .split(|c: char| !c.is_ascii_digit())
            .filter(|s| !s.is_empty())
            .map(|s| s.parse::<u32>().ok());
        Some(GitVersion {
            major: nums.next()??,
            minor: nums.next()??,
            patch: nums.next().flatten().unwrap_or(0),
        })
    }
}

impl fmt::Display for GitVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// 一次 git 调用的结果。stdout 保留原始字节，由解析层决定如何解码。
#[derive(Debug)]
pub struct GitOutput {
    pub stdout: Vec<u8>,
    pub stderr: String,
}

#[derive(Debug, Clone)]
pub struct GitExecutable {
    path: PathBuf,
    version: GitVersion,
}

impl GitExecutable {
    /// 按优先级查找 git：显式路径 → `GITDECK_GIT` → PATH → 平台内置兜底。
    pub fn locate(explicit: Option<&Path>) -> Result<Self> {
        let candidate = explicit
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os(GIT_PATH_ENV).map(PathBuf::from))
            .or_else(|| which::which("git").ok())
            .or_else(bundled_git)
            .ok_or(CoreError::GitNotFound)?;
        Self::from_path(candidate)
    }

    pub fn from_path(path: PathBuf) -> Result<Self> {
        let output = base_command(&path)
            .arg("--version")
            .output()
            .map_err(|_| CoreError::GitNotFound)?;
        if !output.status.success() {
            return Err(CoreError::GitNotFound);
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let version = GitVersion::parse(&text).ok_or_else(|| CoreError::Parse {
            detail: format!("unrecognized `git --version` output: {}", text.trim()),
        })?;
        if version < MIN_GIT_VERSION {
            return Err(CoreError::GitTooOld {
                found: version.to_string(),
                required: MIN_GIT_VERSION.to_string(),
            });
        }
        Ok(GitExecutable { path, version })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn version(&self) -> GitVersion {
        self.version
    }

    /// 在 `cwd` 下执行 git，非零退出码转换为 [`CoreError::CommandFailed`]。
    pub fn run<I, S>(&self, cwd: &Path, args: I) -> Result<GitOutput>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.exec(cwd, args, None)
    }

    /// 同 [`run`](Self::run)，并把 `input` 写入 git 的标准输入（例如 `commit -F -`）。
    pub fn run_with_input<I, S>(&self, cwd: &Path, args: I, input: &[u8]) -> Result<GitOutput>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.exec(cwd, args, Some(input))
    }

    fn exec<I, S>(&self, cwd: &Path, args: I, input: Option<&[u8]>) -> Result<GitOutput>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let args: Vec<_> = args.into_iter().map(|a| a.as_ref().to_owned()).collect();
        let mut child = base_command(&self.path)
            .args(STABLE_OUTPUT_CONFIG)
            .args(&args)
            .current_dir(cwd)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        // 在独立线程写入标准输入，避免输入较大时与 stdout 读取互相阻塞。
        let writer = match (input, child.stdin.take()) {
            (Some(data), Some(mut stdin)) => {
                let data = data.to_vec();
                Some(std::thread::spawn(move || stdin.write_all(&data)))
            }
            _ => None,
        };
        let output = child.wait_with_output()?;
        if let Some(writer) = writer {
            // git 可能在读完输入前就失败退出，此时写入报 BrokenPipe，以退出码为准。
            let _ = writer.join();
        }
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        if !output.status.success() {
            return Err(CoreError::CommandFailed {
                command: args
                    .iter()
                    .map(|a| a.to_string_lossy())
                    .collect::<Vec<_>>()
                    .join(" "),
                exit_code: output.status.code().unwrap_or(-1),
                stderr: stderr.trim().to_owned(),
            });
        }
        Ok(GitOutput {
            stdout: output.stdout,
            stderr,
        })
    }
}

/// 每次调用都注入的配置，保证输出格式不受用户全局配置影响。
const STABLE_OUTPUT_CONFIG: &[&str] = &[
    "-c",
    "core.quotepath=false",
    "-c",
    "color.ui=never",
    "-c",
    "log.showSignature=false",
    "--no-pager",
    // 传入的路径都按字面量处理，文件名中的 `*`、`[` 等不会被当作通配符。
    "--literal-pathspecs",
];

fn base_command(path: &Path) -> Command {
    let mut cmd = Command::new(path);
    cmd
        // 不允许 git 在后台弹出终端交互，认证统一由客户端的 askpass 处理（后续实现）。
        .env("GIT_TERMINAL_PROMPT", "0")
        // 错误信息保持英文，便于按内容识别错误类型。
        .env("LANGUAGE", "C")
        .env("LC_MESSAGES", "C");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Windows 安装包内置的 MinGit：`<exe 目录>/mingit/cmd/git.exe`。
#[cfg(windows)]
fn bundled_git() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let git = exe.parent()?.join("mingit").join("cmd").join("git.exe");
    git.is_file().then_some(git)
}

#[cfg(not(windows))]
fn bundled_git() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_version_strings() {
        let cases = [
            ("git version 2.54.0 (Apple Git-157)", (2, 54, 0)),
            ("git version 2.45.1.windows.1\n", (2, 45, 1)),
            ("git version 2.30.0", (2, 30, 0)),
            ("git version 2.43", (2, 43, 0)),
        ];
        for (input, (major, minor, patch)) in cases {
            assert_eq!(
                GitVersion::parse(input),
                Some(GitVersion {
                    major,
                    minor,
                    patch
                }),
                "{input}"
            );
        }
    }

    #[test]
    fn rejects_unrelated_output() {
        assert_eq!(GitVersion::parse("hg version 6.0"), None);
        assert_eq!(GitVersion::parse("git version"), None);
    }

    #[test]
    fn version_ordering() {
        assert!(GitVersion::parse("git version 2.29.9").unwrap() < MIN_GIT_VERSION);
        assert!(GitVersion::parse("git version 2.30.0").unwrap() >= MIN_GIT_VERSION);
    }
}
