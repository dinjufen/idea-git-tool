//! 分支操作（签出、新建、重命名、删除、合并、变基）的集成测试。

mod common;

use std::fs;

use common::{commit_file, git, head, new_repo, open};
use gitdeck_core::{CheckoutMode, CoreError, MergeOutcome, RepositoryState};

fn current_branch(dir: &std::path::Path) -> String {
    git(dir, &["branch", "--show-current"]).trim().to_owned()
}

#[test]
fn validates_branch_names() {
    let tmp = tempfile::tempdir().unwrap();
    new_repo(tmp.path());
    let repo = open(tmp.path());
    assert!(repo.is_valid_branch_name("feature/新功能-1".into()));
    for bad in ["", "-x", "a..b", "a b", "a~1", "end.lock", "x/"] {
        assert!(!repo.is_valid_branch_name(bad.into()), "{bad}");
    }
    assert!(matches!(
        repo.create_branch("bad name".into(), None, false),
        Err(CoreError::InvalidBranchName { .. })
    ));
}

#[test]
fn create_checkout_rename_and_delete() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let repo = open(dir);

    repo.create_branch("feature".into(), None, true).unwrap();
    assert_eq!(current_branch(dir), "feature");
    commit_file(dir, "f.txt", "f\n", "feature work");

    repo.checkout_branch("main".into(), CheckoutMode::Normal)
        .unwrap();
    assert_eq!(current_branch(dir), "main");

    repo.rename_branch("feature".into(), "feature-renamed".into())
        .unwrap();
    // 未合并的分支需要强制删除。
    assert_eq!(
        repo.delete_branch("feature-renamed".into(), false)
            .unwrap_err(),
        CoreError::BranchNotFullyMerged {
            name: "feature-renamed".into()
        }
    );
    repo.delete_branch("feature-renamed".into(), true).unwrap();
    assert!(
        git(dir, &["branch", "--list", "feature*"])
            .trim()
            .is_empty()
    );

    // 从指定起点新建但不签出。
    repo.create_branch("from-start".into(), Some("HEAD".into()), false)
        .unwrap();
    assert_eq!(current_branch(dir), "main");
}

#[test]
fn checkout_revision_detaches_head() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let first = head(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    open(dir)
        .checkout_revision(first.clone(), CheckoutMode::Normal)
        .unwrap();
    assert_eq!(head(dir), first);
    assert_eq!(current_branch(dir), "");
}

#[test]
fn checkout_remote_branch_creates_tracking_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = tmp.path().join("origin");
    let work = tmp.path().join("work");
    fs::create_dir_all(&origin).unwrap();
    new_repo(&origin);
    git(&origin, &["checkout", "-b", "topic"]);
    commit_file(&origin, "t.txt", "t\n", "topic");
    git(&origin, &["checkout", "main"]);
    git(
        tmp.path(),
        &[
            "clone",
            "-q",
            origin.to_str().unwrap(),
            work.to_str().unwrap(),
        ],
    );
    common::configure(&work);

    open(&work)
        .checkout_remote_branch("origin/topic".into(), CheckoutMode::Normal)
        .unwrap();
    assert_eq!(current_branch(&work), "topic");
    assert_eq!(
        git(&work, &["rev-parse", "--abbrev-ref", "topic@{u}"]).trim(),
        "origin/topic"
    );

    // 本地已有同名分支时直接签出它。
    git(&work, &["checkout", "-q", "main"]);
    open(&work)
        .checkout_remote_branch("origin/topic".into(), CheckoutMode::Normal)
        .unwrap();
    assert_eq!(current_branch(&work), "topic");
}

/// main 与 other 都修改了 a.txt，工作区中 a.txt 有未提交的改动。
fn dirty_conflicting_checkout(dir: &std::path::Path) {
    new_repo(dir);
    commit_file(dir, "a.txt", "base\n", "base");
    git(dir, &["checkout", "-q", "-b", "other"]);
    commit_file(dir, "a.txt", "other\n", "other");
    git(dir, &["checkout", "-q", "main"]);
    fs::write(dir.join("a.txt"), "local edit\n").unwrap();
}

#[test]
fn checkout_reports_overwritten_files_then_force_discards() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    dirty_conflicting_checkout(dir);
    let repo = open(dir);

    match repo.checkout_branch("other".into(), CheckoutMode::Normal) {
        Err(CoreError::LocalChangesWouldBeOverwritten { files }) => assert_eq!(files, ["a.txt"]),
        other => panic!("unexpected: {other:?}"),
    }
    repo.checkout_branch("other".into(), CheckoutMode::Force)
        .unwrap();
    assert_eq!(current_branch(dir), "other");
    assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), "other\n");
}

#[test]
fn smart_checkout_stashes_and_restores_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "1\n2\n3\n4\n5\n", "base");
    git(dir, &["checkout", "-q", "-b", "other"]);
    commit_file(
        dir,
        "a.txt",
        "1 other\n2\n3\n4\n5\n",
        "other edits first line",
    );
    git(dir, &["checkout", "-q", "main"]);
    // 本地只改最后一行：签出 other 后可以干净地恢复。
    fs::write(dir.join("a.txt"), "1\n2\n3\n4\n5 local\n").unwrap();

    let outcome = open(dir)
        .checkout_branch("other".into(), CheckoutMode::Smart)
        .unwrap();
    assert!(!outcome.stash_conflicts);
    assert_eq!(current_branch(dir), "other");
    assert_eq!(
        fs::read_to_string(dir.join("a.txt")).unwrap(),
        "1 other\n2\n3\n4\n5 local\n"
    );
    assert!(git(dir, &["stash", "list"]).trim().is_empty());
}

#[test]
fn smart_checkout_restores_untracked_files() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "1\n2\n3\n4\n5\n", "base");
    git(dir, &["checkout", "-q", "-b", "other"]);
    commit_file(dir, "a.txt", "1 other\n2\n3\n4\n5\n", "other");
    git(dir, &["checkout", "-q", "main"]);
    fs::write(dir.join("a.txt"), "1\n2\n3\n4\n5 local\n").unwrap();
    // 未跟踪文件应随储藏一起暂存并在签出后原样恢复（回归：--literal-pathspecs 曾导致其未被清理）。
    fs::write(dir.join("scratch.txt"), "notes\n").unwrap();

    let outcome = open(dir)
        .checkout_branch("other".into(), CheckoutMode::Smart)
        .unwrap();
    assert!(!outcome.stash_conflicts);
    assert_eq!(
        fs::read_to_string(dir.join("scratch.txt")).unwrap(),
        "notes\n"
    );
    assert!(git(dir, &["stash", "list"]).trim().is_empty());
}

#[test]
fn smart_checkout_keeps_stash_on_conflict() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    dirty_conflicting_checkout(dir);
    let outcome = open(dir)
        .checkout_branch("other".into(), CheckoutMode::Smart)
        .unwrap();
    assert!(outcome.stash_conflicts);
    assert_eq!(current_branch(dir), "other");
    assert!(!git(dir, &["stash", "list"]).trim().is_empty());
}

#[test]
fn merge_outcomes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["checkout", "-q", "-b", "ff"]);
    commit_file(dir, "ff.txt", "ff\n", "ff");
    git(dir, &["checkout", "-q", "main"]);
    let repo = open(dir);

    assert_eq!(
        repo.merge_branch("ff".into()).unwrap(),
        MergeOutcome::FastForward
    );
    assert_eq!(
        repo.merge_branch("ff".into()).unwrap(),
        MergeOutcome::UpToDate
    );

    git(dir, &["checkout", "-q", "-b", "side"]);
    commit_file(dir, "side.txt", "s\n", "side");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "main.txt", "m\n", "main");
    assert_eq!(
        repo.merge_branch("side".into()).unwrap(),
        MergeOutcome::Merged
    );
    assert_eq!(
        git(dir, &["log", "-1", "--format=%P"])
            .split_whitespace()
            .count(),
        2
    );

    git(dir, &["checkout", "-q", "-b", "clash"]);
    commit_file(dir, "readme.md", "clash\n", "clash");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "readme.md", "main\n", "main edit");
    assert_eq!(
        repo.merge_branch("clash".into()).unwrap(),
        MergeOutcome::Conflicts
    );
    assert_eq!(repo.state(), RepositoryState::Merging);
    repo.abort_merge().unwrap();
    assert_eq!(repo.state(), RepositoryState::Normal);
}

#[test]
fn rebase_with_conflict_continue_and_abort() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["checkout", "-q", "-b", "topic"]);
    commit_file(dir, "topic.txt", "t\n", "topic");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "main.txt", "m\n", "main");
    git(dir, &["checkout", "-q", "topic"]);
    let repo = open(dir);

    assert_eq!(
        repo.rebase_onto("main".into()).unwrap(),
        MergeOutcome::Merged
    );
    assert_eq!(
        repo.rebase_onto("main".into()).unwrap(),
        MergeOutcome::UpToDate
    );

    // 制造冲突：两边都改 readme.md。
    commit_file(dir, "readme.md", "topic\n", "topic readme");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "readme.md", "main\n", "main readme");
    git(dir, &["checkout", "-q", "topic"]);
    assert_eq!(
        repo.rebase_onto("main".into()).unwrap(),
        MergeOutcome::Conflicts
    );
    assert_eq!(repo.state(), RepositoryState::Rebasing);

    // 解决冲突后继续。
    fs::write(dir.join("readme.md"), "resolved\n").unwrap();
    git(dir, &["add", "readme.md"]);
    assert_eq!(repo.continue_rebase().unwrap(), MergeOutcome::Merged);
    assert_eq!(repo.state(), RepositoryState::Normal);
    assert_eq!(
        git(dir, &["log", "-1", "--format=%s"]).trim(),
        "topic readme"
    );

    // 再次冲突后中止。
    commit_file(dir, "readme.md", "topic 2\n", "topic readme 2");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "readme.md", "main 2\n", "main readme 2");
    git(dir, &["checkout", "-q", "topic"]);
    let before = head(dir);
    assert_eq!(
        repo.rebase_onto("main".into()).unwrap(),
        MergeOutcome::Conflicts
    );
    repo.abort_rebase().unwrap();
    assert_eq!(head(dir), before);
}

#[test]
fn merge_refuses_to_overwrite_local_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    dirty_conflicting_checkout(dir);
    match open(dir).merge_branch("other".into()) {
        Err(CoreError::LocalChangesWouldBeOverwritten { files }) => assert_eq!(files, ["a.txt"]),
        other => panic!("unexpected: {other:?}"),
    }
}
