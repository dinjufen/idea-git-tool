//! 启动本机 AI CLI 子进程。Windows 上隐藏控制台，避免探测与评审时闪出黑框。
//!
//! 访达 / `open` 启动的应用 PATH 通常只有系统目录。许多 Agent CLI 是
//! `#!/usr/bin/env node` 包装脚本，探测与调用时需要把 nvm、Homebrew、
//! `~/.local/bin` 等常见运行时目录补进子进程 PATH。

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::error::Result;

/// 构造用于探测或评审的命令；补齐运行时 PATH，并在 Windows 上隐藏控制台。
pub(super) fn command(path: impl AsRef<Path>) -> Command {
    let path = path.as_ref();
    let mut cmd = Command::new(path);
    cmd.env("PATH", augmented_path(Some(path)));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// 子进程 PATH：可执行文件所在目录 + 常见 Node/工具目录 + 原 PATH。
pub(super) fn augmented_path(executable: Option<&Path>) -> OsString {
    let sep = path_sep();
    let mut dirs = Vec::new();
    if let Some(path) = executable {
        if let Some(dir) = path.parent() {
            if !dir.as_os_str().is_empty() {
                dirs.push(dir.to_path_buf());
            }
        }
    }
    dirs.extend(runtime_bin_dirs(home_dir().as_deref()));
    if let Some(path) = std::env::var_os("PATH") {
        for part in std::env::split_paths(&path) {
            if !part.as_os_str().is_empty() {
                dirs.push(part);
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    let mut out = OsString::new();
    for dir in dirs {
        let key = std::fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        if !seen.insert(key) {
            continue;
        }
        if !out.is_empty() {
            out.push(sep);
        }
        out.push(dir.as_os_str());
    }
    out
}

fn path_sep() -> &'static str {
    if cfg!(windows) { ";" } else { ":" }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

/// 与当前用户主目录相关的常见 CLI / Node 目录（不含 PATH 本身）。
pub(super) fn runtime_bin_dirs(home: Option<&Path>) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(bin) = std::env::var_os("NVM_BIN") {
        dirs.push(PathBuf::from(bin));
    }
    if let Some(dir) = std::env::var_os("NVM_DIR") {
        push_nvm_version_bins(&mut dirs, Path::new(&dir));
    }
    if let Some(home) = home {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join(".cargo/bin"));
        dirs.push(home.join(".local/share/pi-node/current/bin"));
        dirs.push(home.join(".nvm/current/bin"));
        push_nvm_version_bins(&mut dirs, &home.join(".nvm"));
        dirs.push(home.join("AppData/Roaming/npm"));
        dirs.push(home.join("AppData/Roaming/nvm"));
        dirs.push(home.join("Applications/Codex.app/Contents/Resources"));
        dirs.push(home.join("Applications/Gemini.app/Contents/Helpers"));
    }
    dirs.push(PathBuf::from("/opt/homebrew/bin"));
    dirs.push(PathBuf::from("/usr/local/bin"));
    dirs.push(PathBuf::from("/usr/bin"));
    dirs.push(PathBuf::from("/bin"));
    dirs.push(PathBuf::from("/Applications/Codex.app/Contents/Resources"));
    dirs.push(PathBuf::from("/Applications/Gemini.app/Contents/Helpers"));
    dirs
}

fn push_nvm_version_bins(dirs: &mut Vec<PathBuf>, nvm_root: &Path) {
    if let Some(bin) = std::env::var_os("NVM_BIN") {
        let _ = bin;
    }
    let versions = nvm_root.join("versions/node");
    if let Ok(entries) = std::fs::read_dir(&versions) {
        let mut bins: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .map(|p| p.join("bin"))
            .filter(|p| p.is_dir())
            .collect();
        // 新版本优先，便于 PATH 里先找到能用的 node。
        bins.sort_by(|a, b| b.cmp(a));
        dirs.extend(bins);
    }
}

pub(super) fn unique_tempdir() -> Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!(
        "gitdeck-cli-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

pub(super) struct TempDirCleanup(pub PathBuf);

impl Drop for TempDirCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_bin_dirs_include_nvm_and_app_bundles() {
        let home = PathBuf::from("/tmp/gitdeck-fake-home");
        let dirs = runtime_bin_dirs(Some(&home));
        assert!(dirs.contains(&home.join(".local/bin")));
        assert!(dirs.contains(&home.join(".nvm/current/bin")));
        assert!(
            dirs.iter()
                .any(|d| d.ends_with("Codex.app/Contents/Resources"))
        );
        assert!(
            dirs.iter()
                .any(|d| d.ends_with("Gemini.app/Contents/Helpers"))
        );
        assert!(dirs.iter().any(|d| d == Path::new("/opt/homebrew/bin")));
    }
}
