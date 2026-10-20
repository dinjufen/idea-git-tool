//! 集成测试共用的辅助函数：用系统 git 搭建测试仓库。
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use gitdeck_core::Repository;
use gitdeck_core::git::runner::GitExecutable;

/// 运行 git 并断言成功，返回标准输出。不读取用户的全局与系统配置。
pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = git_raw(dir, args);
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// 运行 git，不断言结果（用于预期失败的命令，例如产生冲突的 merge）。
pub fn git_raw(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("run git")
}

/// 在已有仓库中写入测试身份配置。
pub fn configure(dir: &Path) {
    git(dir, &["config", "user.name", "Test"]);
    git(dir, &["config", "user.email", "test@example.com"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    git(dir, &["config", "core.hooksPath", ".git/hooks"]);
    // 核心的 GitRunner 会读取系统配置，而 Git for Windows 默认 core.autocrlf=true；
    // 固定为 false，使断言中的行尾在各平台一致（CRLF 场景另有专门测试）。
    git(dir, &["config", "core.autocrlf", "false"]);
}

/// 创建一个空仓库（无提交），默认分支为 main。
pub fn empty_repo(dir: &Path) {
    git(dir, &["init", "-b", "main"]);
    configure(dir);
}

/// 创建一个带一次提交的仓库，默认分支为 main。
pub fn new_repo(dir: &Path) {
    empty_repo(dir);
    fs::write(dir.join("readme.md"), "hello\n").unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", "Initial commit"]);
}

/// 写入文件并提交，返回新提交的哈希。
pub fn commit_file(dir: &Path, path: &str, content: &str, message: &str) -> String {
    let full = dir.join(path);
    if let Some(parent) = full.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(full, content).unwrap();
    git(dir, &["add", "--", path]);
    git(dir, &["commit", "-m", message]);
    head(dir)
}

pub fn head(dir: &Path) -> String {
    git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

pub fn open(dir: &Path) -> Repository {
    Repository::open_with(GitExecutable::locate(None).unwrap(), dir).unwrap()
}

pub fn canonical(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap()
}
