//! 针对真实 git 仓库的集成测试。

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use gitdeck_core::git::runner::GitExecutable;
use gitdeck_core::{BranchKind, ChangeKind, ConflictKind, CoreError, Repository};

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("run git");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// 创建一个带一次提交的仓库，默认分支为 main。
fn new_repo(dir: &Path) {
    git(dir, &["init", "-b", "main"]);
    git(dir, &["config", "user.name", "Test"]);
    git(dir, &["config", "user.email", "test@example.com"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    fs::write(dir.join("readme.md"), "hello\n").unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", "Initial commit"]);
}

fn open(dir: &Path) -> Repository {
    Repository::open_with(GitExecutable::locate(None).unwrap(), dir).unwrap()
}

fn canonical(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap()
}

#[test]
fn open_from_subdirectory_resolves_root() {
    let tmp = tempfile::tempdir().unwrap();
    new_repo(tmp.path());
    let sub = tmp.path().join("a/b");
    fs::create_dir_all(&sub).unwrap();

    let repo = open(&sub);
    assert_eq!(canonical(repo.root_path()), canonical(tmp.path()));
}

#[test]
fn open_non_repository_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let err = Repository::open_with(GitExecutable::locate(None).unwrap(), tmp.path()).unwrap_err();
    assert!(matches!(err, CoreError::NotARepository { .. }), "{err:?}");
}

#[test]
fn status_reports_staged_unstaged_untracked_and_renames() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("a.txt"), "a\n").unwrap();
    git(dir, &["add", "a.txt"]);
    git(dir, &["commit", "-m", "add a"]);

    fs::write(dir.join("readme.md"), "hello\nworld\n").unwrap();
    git(dir, &["mv", "a.txt", "重命名 后.txt"]);
    fs::write(dir.join("new file.txt"), "n\n").unwrap();

    let st = open(dir).status().unwrap();
    assert_eq!(st.branch.head.as_deref(), Some("main"));
    assert!(st.branch.oid.is_some());

    let find = |p: &str| {
        st.changes
            .iter()
            .find(|c| c.path == p)
            .unwrap_or_else(|| panic!("{p} missing: {:?}", st.changes))
    };
    assert_eq!(find("readme.md").unstaged, ChangeKind::Modified);
    let renamed = find("重命名 后.txt");
    assert_eq!(renamed.staged, ChangeKind::Renamed);
    assert_eq!(renamed.orig_path.as_deref(), Some("a.txt"));
    assert_eq!(find("new file.txt").unstaged, ChangeKind::Untracked);
}

#[test]
fn status_reports_merge_conflicts() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["checkout", "-b", "other"]);
    fs::write(dir.join("readme.md"), "theirs\n").unwrap();
    git(dir, &["commit", "-am", "theirs"]);
    git(dir, &["checkout", "main"]);
    fs::write(dir.join("readme.md"), "ours\n").unwrap();
    git(dir, &["commit", "-am", "ours"]);
    // 合并预期失败并留下冲突，不能用 git() 断言成功。
    let merge = Command::new("git")
        .args(["merge", "other"])
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(!merge.status.success());

    let st = open(dir).status().unwrap();
    let c = st.changes.iter().find(|c| c.path == "readme.md").unwrap();
    assert_eq!(c.conflict, Some(ConflictKind::BothModified));
}

#[test]
fn status_of_empty_repository() {
    let tmp = tempfile::tempdir().unwrap();
    git(tmp.path(), &["init", "-b", "trunk"]);
    let st = open(tmp.path()).status().unwrap();
    assert_eq!(st.branch.head.as_deref(), Some("trunk"));
    assert_eq!(st.branch.oid, None);
    assert!(st.changes.is_empty());
}

#[test]
fn branches_with_upstream_tracking() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = tmp.path().join("origin");
    let work = tmp.path().join("work");
    fs::create_dir_all(&origin).unwrap();
    new_repo(&origin);
    git(
        tmp.path(),
        &["clone", origin.to_str().unwrap(), work.to_str().unwrap()],
    );
    git(&work, &["config", "user.name", "Test"]);
    git(&work, &["config", "user.email", "test@example.com"]);
    git(&work, &["config", "commit.gpgsign", "false"]);

    // 本地领先 1，远程领先 1。
    fs::write(work.join("local.txt"), "l\n").unwrap();
    git(&work, &["add", "."]);
    git(&work, &["commit", "-m", "local"]);
    fs::write(origin.join("remote.txt"), "r\n").unwrap();
    git(&origin, &["add", "."]);
    git(&origin, &["commit", "-m", "remote"]);
    git(&work, &["fetch"]);
    git(&work, &["branch", "feature/x"]);

    let repo = open(&work);
    let branches = repo.branches().unwrap();
    let main = branches.iter().find(|b| b.name == "main").unwrap();
    assert!(main.is_current);
    assert_eq!(main.kind, BranchKind::Local);
    assert_eq!(main.upstream.as_deref(), Some("origin/main"));
    assert_eq!((main.ahead, main.behind), (1, 1));
    assert_eq!(main.subject, "local");

    let feature = branches.iter().find(|b| b.name == "feature/x").unwrap();
    assert!(!feature.is_current);

    let remote = branches.iter().find(|b| b.name == "origin/main").unwrap();
    assert_eq!(remote.kind, BranchKind::Remote);
    assert!(!branches.iter().any(|b| b.name.ends_with("/HEAD")));

    let st = repo.status().unwrap();
    assert_eq!(st.branch.upstream.as_deref(), Some("origin/main"));
    assert_eq!((st.branch.ahead, st.branch.behind), (1, 1));
}
