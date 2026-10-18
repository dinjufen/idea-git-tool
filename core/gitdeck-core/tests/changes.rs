//! Rollback、克隆、与工作区比较，以及分支菜单中的 Checkout and Rebase / Update / 删除远程分支。

mod common;

use std::fs;
use std::path::Path;

use common::*;
use gitdeck_core::{ChangeKind, MergeOutcome, clone_directory_name, clone_repository};

fn status_paths(dir: &Path) -> Vec<String> {
    open(dir)
        .status()
        .unwrap()
        .changes
        .into_iter()
        .map(|c| c.path)
        .collect()
}

#[test]
fn rollback_restores_modified_deleted_and_staged_files() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    commit_file(dir, "b.txt", "b\n", "b");
    fs::write(dir.join("a.txt"), "changed\n").unwrap();
    git(dir, &["add", "a.txt"]);
    fs::write(dir.join("a.txt"), "changed again\n").unwrap();
    fs::remove_file(dir.join("b.txt")).unwrap();
    fs::write(dir.join("keep.txt"), "untracked\n").unwrap();

    let repo = open(dir);
    repo.rollback(
        vec!["a.txt".into(), "b.txt".into(), "keep.txt".into()],
        true,
    )
    .unwrap();
    assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), "a\n");
    assert_eq!(fs::read_to_string(dir.join("b.txt")).unwrap(), "b\n");
    // 未跟踪的文件不受 Rollback 影响。
    assert_eq!(status_paths(dir), ["keep.txt"]);
}

#[test]
fn rollback_added_files_keeps_or_deletes_them() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("new1.txt"), "1\n").unwrap();
    fs::write(dir.join("new2.txt"), "2\n").unwrap();
    git(dir, &["add", "new1.txt", "new2.txt"]);
    let repo = open(dir);

    repo.rollback(vec!["new1.txt".into()], false).unwrap();
    assert!(dir.join("new1.txt").exists());
    let status = repo.status().unwrap();
    let new1 = status
        .changes
        .iter()
        .find(|c| c.path == "new1.txt")
        .unwrap();
    assert_eq!(new1.unstaged, ChangeKind::Untracked);

    repo.rollback(vec!["new2.txt".into()], true).unwrap();
    assert!(!dir.join("new2.txt").exists());
}

#[test]
fn rollback_rename_restores_original() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "old.txt", "content\n", "add old");
    git(dir, &["mv", "old.txt", "new.txt"]);
    let repo = open(dir);
    repo.rollback(vec!["new.txt".into()], true).unwrap();
    assert!(dir.join("old.txt").exists());
    assert!(!dir.join("new.txt").exists());
    assert!(status_paths(dir).is_empty());
}

#[test]
fn rollback_in_empty_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    empty_repo(dir);
    fs::write(dir.join("first.txt"), "x\n").unwrap();
    git(dir, &["add", "first.txt"]);
    open(dir).rollback(vec!["first.txt".into()], false).unwrap();
    let status = open(dir).status().unwrap();
    assert_eq!(status.changes[0].unstaged, ChangeKind::Untracked);
}

#[test]
fn lists_differences_with_working_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    git(dir, &["branch", "base"]);
    commit_file(dir, "b.txt", "b\n", "b");
    fs::write(dir.join("a.txt"), "local\n").unwrap();
    let files = open(dir).diff_with_working_tree("base".into()).unwrap();
    let names: Vec<_> = files.iter().map(|f| (f.path.as_str(), f.kind)).collect();
    assert_eq!(
        names,
        [
            ("a.txt", ChangeKind::Modified),
            ("b.txt", ChangeKind::Added)
        ]
    );
    assert!(open(dir).diff_with_working_tree("-p".into()).is_err());
}

#[test]
fn clones_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let seed = tmp.path().join("seed");
    fs::create_dir_all(&seed).unwrap();
    new_repo(&seed);
    let target = tmp.path().join("nested/copy");
    let repo = clone_repository(
        seed.to_string_lossy().into(),
        target.to_string_lossy().into(),
    )
    .unwrap();
    assert_eq!(canonical(Path::new(&repo.root())), canonical(&target));
    assert!(target.join("readme.md").exists());
    // 目标目录非空时克隆失败。
    assert!(
        clone_repository(
            seed.to_string_lossy().into(),
            target.to_string_lossy().into()
        )
        .is_err()
    );

    assert_eq!(
        clone_directory_name("https://github.com/team/app.git".into()),
        "app"
    );
    assert_eq!(
        clone_directory_name("git@github.com:team/tool.git/".into()),
        "tool"
    );
    assert_eq!(clone_directory_name("/srv/repos/lib".into()), "lib");
}

/// 裸远程加一个工作副本，`other` 用于模拟别人推送。
fn remote_setup(tmp: &Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let seed = tmp.join("seed");
    fs::create_dir_all(&seed).unwrap();
    new_repo(&seed);
    let origin = tmp.join("origin.git");
    git(
        tmp,
        &[
            "clone",
            "-q",
            "--bare",
            seed.to_str().unwrap(),
            origin.to_str().unwrap(),
        ],
    );
    let work = tmp.join("work");
    let other = tmp.join("other");
    for dir in [&work, &other] {
        git(
            tmp,
            &[
                "clone",
                "-q",
                origin.to_str().unwrap(),
                dir.to_str().unwrap(),
            ],
        );
        configure(dir);
    }
    (work, other)
}

#[test]
fn updates_non_current_branch_and_deletes_remote_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let (work, other) = remote_setup(tmp.path());
    git(&other, &["switch", "-q", "-c", "feature"]);
    commit_file(&other, "f.txt", "1\n", "f1");
    git(&other, &["push", "-q", "-u", "origin", "feature"]);
    git(&work, &["fetch", "-q"]);
    git(
        &work,
        &["branch", "-q", "--track", "feature", "origin/feature"],
    );
    commit_file(&other, "f.txt", "2\n", "f2");
    git(&other, &["push", "-q"]);
    let expected = head(&other);

    let repo = open(&work);
    repo.update_branch("feature".into()).unwrap();
    assert_eq!(git(&work, &["rev-parse", "feature"]).trim(), expected);

    repo.delete_remote_branch("origin/feature".into()).unwrap();
    let remote_branches = git(&other, &["ls-remote", "--heads", "origin"]);
    assert!(!remote_branches.contains("refs/heads/feature"));
    assert!(repo.delete_remote_branch("nope/feature".into()).is_err());
}

#[test]
fn checkout_and_rebase_onto_current() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["branch", "feature"]);
    commit_file(dir, "main.txt", "m\n", "on main");
    git(dir, &["switch", "-q", "feature"]);
    commit_file(dir, "feature.txt", "f\n", "on feature");
    git(dir, &["switch", "-q", "main"]);
    // 本地改动会自动暂存并恢复。
    fs::write(dir.join("readme.md"), "dirty\n").unwrap();

    let outcome = open(dir)
        .checkout_and_rebase("feature".into(), "main".into())
        .unwrap();
    assert_eq!(outcome, MergeOutcome::Merged);
    assert_eq!(git(dir, &["branch", "--show-current"]).trim(), "feature");
    assert!(dir.join("main.txt").exists());
    assert_eq!(
        fs::read_to_string(dir.join("readme.md")).unwrap(),
        "dirty\n"
    );
}
