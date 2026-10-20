//! 提交（勾选文件提交、Amend、合并状态、钩子）的集成测试。

mod common;

use std::fs;

use common::{commit_file, empty_repo, git, git_raw, head, new_repo, open};
use gitdeck_core::{ChangeKind, CommitOptions, CoreError};

fn options(message: &str, paths: &[&str]) -> CommitOptions {
    CommitOptions {
        message: message.into(),
        paths: paths.iter().map(|p| p.to_string()).collect(),
        ..Default::default()
    }
}

/// 某次提交中修改的文件列表。
fn files_in(dir: &std::path::Path, rev: &str) -> Vec<String> {
    let out = git(
        dir,
        &["show", "--name-only", "--no-renames", "--format=", rev],
    );
    let mut files: Vec<String> = out
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();
    files.sort();
    files
}

#[test]
fn commits_only_selected_files_and_keeps_other_staged_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "a\n", "add a");
    commit_file(dir, "b.txt", "b\n", "add b");

    fs::write(dir.join("a.txt"), "a2\n").unwrap();
    fs::write(dir.join("b.txt"), "b2\n").unwrap();
    // b.txt 已暂存但未勾选：提交后应仍留在暂存区。
    git(dir, &["add", "b.txt"]);

    let result = open(dir)
        .commit(options("Change a\n\nBody line", &["a.txt"]))
        .unwrap();
    assert_eq!(result.subject, "Change a");
    assert_eq!(result.file_count, 1);
    assert_eq!(result.hash, head(dir));
    assert_eq!(files_in(dir, "HEAD"), ["a.txt"]);
    assert_eq!(
        git(dir, &["log", "-1", "--format=%B"]).trim_end(),
        "Change a\n\nBody line"
    );

    let st = open(dir).status().unwrap();
    let b = st
        .changes
        .iter()
        .find(|c| c.path == "b.txt")
        .expect("b.txt still changed");
    assert_eq!(b.staged, ChangeKind::Modified);
    assert!(!st.changes.iter().any(|c| c.path == "a.txt"));
}

#[test]
fn commits_partially_staged_file_with_working_tree_content() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("readme.md"), "staged\n").unwrap();
    git(dir, &["add", "readme.md"]);
    fs::write(dir.join("readme.md"), "working tree\n").unwrap();

    open(dir)
        .commit(options("Update readme", &["readme.md"]))
        .unwrap();
    assert_eq!(git(dir, &["show", "HEAD:readme.md"]), "working tree\n");
}

#[test]
fn adds_untracked_and_records_deleted_files() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "old.txt", "old\n", "add old");
    fs::remove_file(dir.join("old.txt")).unwrap();
    fs::write(dir.join("new [1].txt"), "new\n").unwrap();
    fs::write(dir.join("ignored-by-selection.txt"), "x\n").unwrap();

    open(dir)
        .commit(options("Replace old", &["old.txt", "new [1].txt"]))
        .unwrap();
    assert_eq!(files_in(dir, "HEAD"), ["new [1].txt", "old.txt"]);
    let st = open(dir).status().unwrap();
    let untouched = st
        .changes
        .iter()
        .find(|c| c.path == "ignored-by-selection.txt")
        .unwrap();
    assert_eq!(untouched.unstaged, ChangeKind::Untracked);
}

#[test]
fn staged_rename_commits_both_paths() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "before.txt", "content\n", "add before");
    git(dir, &["mv", "before.txt", "after.txt"]);

    open(dir).commit(options("Rename", &["after.txt"])).unwrap();
    assert_eq!(files_in(dir, "HEAD"), ["after.txt", "before.txt"]);
    assert!(open(dir).status().unwrap().changes.is_empty());
}

#[test]
fn first_commit_in_empty_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    empty_repo(dir);
    fs::write(dir.join("one.txt"), "1\n").unwrap();
    fs::write(dir.join("two.txt"), "2\n").unwrap();

    let repo = open(dir);
    assert_eq!(repo.last_commit_message().unwrap(), None);
    repo.commit(options("Initial", &["one.txt"])).unwrap();
    assert_eq!(files_in(dir, "HEAD"), ["one.txt"]);
}

#[test]
fn amend_with_files_and_message_only() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let original = commit_file(dir, "a.txt", "a\n", "Add a");

    fs::write(dir.join("b.txt"), "b\n").unwrap();
    let repo = open(dir);
    assert_eq!(
        repo.last_commit_message().unwrap().as_deref(),
        Some("Add a")
    );
    let mut opts = options("Add a and b", &["b.txt"]);
    opts.amend = true;
    let amended = repo.commit(opts).unwrap();
    assert_ne!(amended.hash, original);
    assert_eq!(files_in(dir, "HEAD"), ["a.txt", "b.txt"]);
    assert_eq!(git(dir, &["rev-list", "--count", "HEAD"]).trim(), "2");

    // 没有勾选文件时只修改提交信息，其他工作区改动不受影响。
    fs::write(dir.join("c.txt"), "c\n").unwrap();
    let mut opts = options("Reworded", &[]);
    opts.amend = true;
    repo.commit(opts).unwrap();
    assert_eq!(git(dir, &["log", "-1", "--format=%s"]).trim(), "Reworded");
    assert_eq!(files_in(dir, "HEAD"), ["a.txt", "b.txt"]);
    assert!(
        repo.status()
            .unwrap()
            .changes
            .iter()
            .any(|c| c.path == "c.txt")
    );
}

#[test]
fn sign_off_and_author_override() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("readme.md"), "changed\n").unwrap();
    let mut opts = options("Signed", &["readme.md"]);
    opts.sign_off = true;
    opts.author = Some("Someone Else <someone@example.com>".into());
    open(dir).commit(opts).unwrap();

    assert_eq!(
        git(dir, &["log", "-1", "--format=%an <%ae>"]).trim(),
        "Someone Else <someone@example.com>"
    );
    assert!(
        git(dir, &["log", "-1", "--format=%B"]).contains("Signed-off-by: Test <test@example.com>")
    );
}

#[test]
fn merge_in_progress_commits_whole_index() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["checkout", "-b", "other"]);
    commit_file(dir, "readme.md", "theirs\n", "theirs");
    commit_file(dir, "clean.txt", "clean\n", "clean change");
    git(dir, &["checkout", "main"]);
    commit_file(dir, "readme.md", "ours\n", "ours");
    assert!(!git_raw(dir, &["merge", "other"]).status.success());

    // 解决冲突后只勾选冲突文件：合并带入的 clean.txt 也必须进入合并提交。
    fs::write(dir.join("readme.md"), "resolved\n").unwrap();
    open(dir)
        .commit(options("Merge other", &["readme.md"]))
        .unwrap();

    let parents = git(dir, &["log", "-1", "--format=%P"]);
    assert_eq!(parents.split_whitespace().count(), 2);
    assert_eq!(git(dir, &["show", "HEAD:clean.txt"]), "clean\n");
    assert_eq!(git(dir, &["show", "HEAD:readme.md"]), "resolved\n");
}

#[test]
fn hooks_run_unless_skipped() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let hook = dir.join(".git/hooks/pre-commit");
    fs::write(&hook, "#!/bin/sh\necho 'blocked by hook' >&2\nexit 1\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    }
    fs::write(dir.join("readme.md"), "changed\n").unwrap();

    let repo = open(dir);
    let err = repo.commit(options("Blocked", &["readme.md"])).unwrap_err();
    match err {
        CoreError::CommandFailed { stderr, .. } => {
            assert!(stderr.contains("blocked by hook"), "{stderr}")
        }
        other => panic!("unexpected error: {other:?}"),
    }

    let mut opts = options("Skip hooks", &["readme.md"]);
    opts.skip_hooks = true;
    repo.commit(opts).unwrap();
    assert_eq!(git(dir, &["log", "-1", "--format=%s"]).trim(), "Skip hooks");
}

#[test]
fn rejects_empty_message_and_empty_selection() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("readme.md"), "changed\n").unwrap();
    let repo = open(dir);
    assert_eq!(
        repo.commit(options("  \n", &["readme.md"])).unwrap_err(),
        CoreError::EmptyCommitMessage
    );
    assert_eq!(
        repo.commit(options("Msg", &[])).unwrap_err(),
        CoreError::NothingToCommit
    );
    assert_eq!(
        repo.commit(options("Msg", &["not-changed.txt"]))
            .unwrap_err(),
        CoreError::NothingToCommit
    );
}

#[test]
fn partial_commit_keeps_excluded_changes_in_working_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "f.txt", "1\n2\n3\n4\n", "base");
    let working = "1\nTWO\n3\n4\nfive\n";
    fs::write(dir.join("f.txt"), working).unwrap();
    fs::write(dir.join("other.txt"), "other\n").unwrap();
    git(dir, &["add", "other.txt"]);
    let repo = open(dir);

    // 只提交新增的 “five”，不提交第 2 行的修改；other.txt 整个提交。
    let content =
        gitdeck_core::partial_text("1\n2\n3\n4\n".into(), working.into(), vec![1], vec![1]);
    let result = repo
        .commit(CommitOptions {
            message: "partial".into(),
            paths: vec!["f.txt".into(), "other.txt".into()],
            partial: vec![gitdeck_core::PartialFile {
                path: "f.txt".into(),
                content,
            }],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(result.subject, "partial");
    assert_eq!(git(dir, &["show", "HEAD:f.txt"]), "1\n2\n3\n4\nfive\n");
    assert_eq!(git(dir, &["show", "HEAD:other.txt"]), "other\n");
    // 工作区不变；剩余改动为未暂存的修改，索引中是提交后的内容。
    assert_eq!(fs::read_to_string(dir.join("f.txt")).unwrap(), working);
    assert_eq!(git(dir, &["diff", "--cached", "--name-only"]), "");
    assert_eq!(git(dir, &["diff", "--name-only"]), "f.txt\n");
    assert!(!dir.join(".git/gitdeck-partial-index").exists());
}

#[test]
fn partial_commit_of_new_file_and_amend() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("new.txt"), "keep\ndraft\n").unwrap();
    let repo = open(dir);
    repo.commit(CommitOptions {
        message: "add new".into(),
        paths: vec!["new.txt".into()],
        partial: vec![gitdeck_core::PartialFile {
            path: "new.txt".into(),
            content: "keep\n".into(),
        }],
        ..Default::default()
    })
    .unwrap();
    assert_eq!(git(dir, &["show", "HEAD:new.txt"]), "keep\n");
    let status = repo.status().unwrap();
    assert_eq!(status.changes.len(), 1);
    assert_eq!(status.changes[0].unstaged, ChangeKind::Modified);

    // Amend 时同样以 HEAD 为基础。
    repo.commit(CommitOptions {
        message: "add new (amended)".into(),
        paths: vec!["new.txt".into()],
        amend: true,
        partial: vec![gitdeck_core::PartialFile {
            path: "new.txt".into(),
            content: "keep\ndraft\n".into(),
        }],
        ..Default::default()
    })
    .unwrap();
    assert_eq!(git(dir, &["rev-list", "--count", "HEAD"]).trim(), "2");
    assert_eq!(git(dir, &["show", "HEAD:new.txt"]), "keep\ndraft\n");
    assert!(repo.status().unwrap().changes.is_empty());
}

#[test]
fn partial_commit_with_autocrlf_stores_lf_in_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["config", "core.autocrlf", "true"]);
    commit_file(dir, "f.txt", "1\n2\n3\n", "base");
    // Windows 上的工作区文件是 CRLF；部分提交的内容按工作区换行风格生成。
    let working = "1\r\nTWO\r\n3\r\nfour\r\n";
    fs::write(dir.join("f.txt"), working).unwrap();
    let repo = open(dir);

    let content =
        gitdeck_core::partial_text("1\r\n2\r\n3\r\n".into(), working.into(), vec![1], vec![1]);
    assert_eq!(content, "1\r\n2\r\n3\r\nfour\r\n");
    repo.commit(CommitOptions {
        message: "partial".into(),
        paths: vec!["f.txt".into()],
        partial: vec![gitdeck_core::PartialFile {
            path: "f.txt".into(),
            content,
        }],
        ..Default::default()
    })
    .unwrap();
    // 仓库中保存为 LF，工作区保持原样，剩余的修改仍是未暂存改动。
    assert_eq!(git(dir, &["show", "HEAD:f.txt"]), "1\n2\n3\nfour\n");
    assert_eq!(fs::read_to_string(dir.join("f.txt")).unwrap(), working);
    assert_eq!(git(dir, &["diff", "--name-only"]), "f.txt\n");
}
