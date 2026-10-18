//! Cherry-pick / Revert / Reset / Undo Commit / 编辑提交信息 / 交互式变基的集成测试。

mod common;

use std::fs;
use std::path::Path;

use common::{commit_file, git, git_raw, head, new_repo, open};
use gitdeck_core::{
    ChangeKind, CommitOptions, CoreError, MergeOutcome, RebaseAction, RebaseStep, RepositoryState,
    ResetMode,
};

fn subjects(dir: &Path) -> Vec<String> {
    git(dir, &["log", "--format=%s"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn rev(dir: &Path, spec: &str) -> String {
    git(dir, &["rev-parse", spec]).trim().to_owned()
}

#[test]
fn cherry_pick_and_conflict_flow() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    git(dir, &["checkout", "-q", "-b", "topic"]);
    let a = commit_file(dir, "a.txt", "a\n", "topic a");
    let b = commit_file(dir, "readme.md", "topic readme\n", "topic readme");
    git(dir, &["checkout", "-q", "main"]);
    let repo = open(dir);

    assert_eq!(repo.cherry_pick(vec![a]).unwrap(), MergeOutcome::Merged);
    assert_eq!(subjects(dir)[0], "topic a");

    commit_file(dir, "readme.md", "main readme\n", "main readme");
    assert_eq!(
        repo.cherry_pick(vec![b.clone()]).unwrap(),
        MergeOutcome::Conflicts
    );
    assert_eq!(repo.state(), RepositoryState::CherryPicking);
    repo.abort_cherry_pick().unwrap();
    assert_eq!(repo.state(), RepositoryState::Normal);

    // 解决冲突后既可以继续，也可以通过提交窗口提交（此时提交整个索引）。
    assert_eq!(repo.cherry_pick(vec![b]).unwrap(), MergeOutcome::Conflicts);
    fs::write(dir.join("readme.md"), "resolved\n").unwrap();
    repo.resolve_conflict("readme.md".into(), Some("resolved\n".into()))
        .unwrap();
    assert_eq!(
        repo.merge_message()
            .as_deref()
            .map(|m| m.lines().next().unwrap()),
        Some("topic readme")
    );
    repo.commit(CommitOptions {
        message: "topic readme".into(),
        paths: vec!["readme.md".into()],
        ..Default::default()
    })
    .unwrap();
    assert_eq!(repo.state(), RepositoryState::Normal);
    assert_eq!(subjects(dir)[0], "topic readme");
}

#[test]
fn revert_and_continue() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let c = commit_file(dir, "a.txt", "a\n", "add a");
    let repo = open(dir);
    assert_eq!(repo.revert_commits(vec![c]).unwrap(), MergeOutcome::Merged);
    assert!(!dir.join("a.txt").exists());
    assert!(subjects(dir)[0].starts_with("Revert \"add a\""));

    let edit = commit_file(dir, "readme.md", "edit 1\n", "edit 1");
    commit_file(dir, "readme.md", "edit 2\n", "edit 2");
    assert_eq!(
        repo.revert_commits(vec![edit]).unwrap(),
        MergeOutcome::Conflicts
    );
    assert_eq!(repo.state(), RepositoryState::Reverting);
    repo.resolve_conflict("readme.md".into(), Some("hello\nedit 2\n".into()))
        .unwrap();
    assert_eq!(repo.continue_revert().unwrap(), MergeOutcome::Merged);
    assert_eq!(repo.state(), RepositoryState::Normal);
}

#[test]
fn reset_modes() {
    for (mode, staged, worktree) in [
        (ResetMode::Soft, Some(ChangeKind::Added), true),
        (ResetMode::Mixed, None, true),
        (ResetMode::Hard, None, false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        new_repo(dir);
        let base = head(dir);
        commit_file(dir, "b.txt", "b\n", "add b");
        open(dir).reset_to(base.clone(), mode).unwrap();
        assert_eq!(head(dir), base);
        let status = open(dir).status().unwrap();
        let b = status.changes.iter().find(|c| c.path == "b.txt");
        assert_eq!(
            b.is_some() || dir.join("b.txt").exists(),
            worktree,
            "{mode:?}"
        );
        if let Some(kind) = staged {
            assert_eq!(b.unwrap().staged, kind);
        }
    }

    // --keep 遇到会被覆盖的本地改动时拒绝。
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let base = head(dir);
    commit_file(dir, "readme.md", "changed\n", "change readme");
    fs::write(dir.join("readme.md"), "local\n").unwrap();
    assert!(matches!(
        open(dir).reset_to(base, ResetMode::Keep),
        Err(CoreError::CommandFailed { .. } | CoreError::LocalChangesWouldBeOverwritten { .. })
    ));
}

#[test]
fn undo_last_commit_keeps_changes_staged() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let base = head(dir);
    commit_file(dir, "a.txt", "a\n", "add a");
    let repo = open(dir);
    repo.undo_last_commit().unwrap();
    assert_eq!(head(dir), base);
    let status = repo.status().unwrap();
    assert_eq!(status.changes[0].staged, ChangeKind::Added);

    // 根提交也可以撤销。
    repo.undo_last_commit().unwrap();
    assert!(
        !git_raw(dir, &["rev-parse", "--verify", "HEAD"])
            .status
            .success()
    );
    assert_eq!(repo.status().unwrap().branch.oid, None);
}

#[test]
fn edit_message_of_head_and_older_commit() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let older = commit_file(dir, "a.txt", "a\n", "olde typo");
    commit_file(dir, "b.txt", "b\n", "latest");
    // 暂存区中有其他改动：修改 HEAD 信息时不应把它带进提交。
    fs::write(dir.join("c.txt"), "c\n").unwrap();
    git(dir, &["add", "c.txt"]);
    let repo = open(dir);

    repo.edit_commit_message(head(dir), "latest, reworded".into())
        .unwrap();
    assert_eq!(subjects(dir)[0], "latest, reworded");
    assert!(git(dir, &["show", "--name-only", "--format=", "HEAD"]).contains("b.txt"));
    assert_eq!(repo.status().unwrap().changes[0].staged, ChangeKind::Added);

    assert_eq!(
        repo.edit_commit_message(older, "older, fixed\n\nwith body".into())
            .unwrap(),
        MergeOutcome::Merged
    );
    assert_eq!(
        subjects(dir),
        ["latest, reworded", "older, fixed", "Initial commit"]
    );
    assert_eq!(
        git(dir, &["log", "-1", "--format=%b", "HEAD~1"]).trim(),
        "with body"
    );
    // 自动储藏后恢复了暂存区之外的工作区状态。
    assert!(dir.join("c.txt").exists());
}

#[test]
fn interactive_rebase_reorders_squashes_and_drops() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let a = commit_file(dir, "a.txt", "a\n", "A");
    let b = commit_file(dir, "b.txt", "b\n", "B");
    let c = commit_file(dir, "c.txt", "c\n", "C");
    let d = commit_file(dir, "d.txt", "d\n", "D");
    let repo = open(dir);

    let listed: Vec<_> = repo
        .rebase_commits(a.clone())
        .unwrap()
        .into_iter()
        .map(|c| c.subject)
        .collect();
    assert_eq!(listed, ["A", "B", "C", "D"]);

    let step = |hash: &str, action, message: Option<&str>| RebaseStep {
        hash: hash.into(),
        action,
        message: message.map(Into::into),
    };
    let outcome = repo
        .interactive_rebase(
            a.clone(),
            vec![
                step(&c, RebaseAction::Reword, Some("C reworded")),
                step(&a, RebaseAction::Pick, None),
                step(&b, RebaseAction::Squash, Some("A and B")),
                step(&d, RebaseAction::Drop, None),
            ],
        )
        .unwrap();
    assert_eq!(outcome, MergeOutcome::Merged);
    assert_eq!(subjects(dir), ["A and B", "C reworded", "Initial commit"]);
    assert!(!dir.join("d.txt").exists());
    assert!(dir.join("a.txt").exists() && dir.join("b.txt").exists());
}

#[test]
fn interactive_rebase_edit_pauses_and_continues() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let a = commit_file(dir, "a.txt", "a\n", "A");
    let b = commit_file(dir, "b.txt", "b\n", "B");
    let repo = open(dir);
    let outcome = repo
        .interactive_rebase(
            a.clone(),
            vec![
                RebaseStep {
                    hash: a,
                    action: RebaseAction::Edit,
                    message: None,
                },
                RebaseStep {
                    hash: b,
                    action: RebaseAction::Pick,
                    message: None,
                },
            ],
        )
        .unwrap();
    assert_eq!(outcome, MergeOutcome::Paused);
    assert_eq!(repo.state(), RepositoryState::Rebasing);
    fs::write(dir.join("a.txt"), "a edited\n").unwrap();
    git(dir, &["commit", "-q", "--amend", "-am", "A edited"]);
    assert_eq!(repo.continue_rebase().unwrap(), MergeOutcome::Merged);
    assert_eq!(subjects(dir), ["B", "A edited", "Initial commit"]);
}

#[test]
fn drop_commits_and_invalid_plans() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let a = commit_file(dir, "a.txt", "a\n", "A");
    let b = commit_file(dir, "b.txt", "b\n", "B");
    commit_file(dir, "c.txt", "c\n", "C");
    let repo = open(dir);

    assert!(matches!(
        repo.interactive_rebase(
            a.clone(),
            vec![RebaseStep {
                hash: a.clone(),
                action: RebaseAction::Fixup,
                message: None
            }]
        ),
        Err(CoreError::InvalidRebasePlan { .. })
    ));

    assert_eq!(repo.drop_commits(vec![b, a]).unwrap(), MergeOutcome::Merged);
    assert_eq!(subjects(dir), ["C", "Initial commit"]);

    // 范围内有合并提交时拒绝。
    git(dir, &["checkout", "-q", "-b", "side"]);
    commit_file(dir, "s.txt", "s\n", "S");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "m.txt", "m\n", "M");
    git(dir, &["merge", "-q", "--no-ff", "side", "-m", "merge side"]);
    let root = rev(dir, "HEAD~2");
    assert_eq!(
        repo.rebase_commits(root).unwrap_err(),
        CoreError::RebaseWithMerges
    );
}

#[test]
fn pushed_detection() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = tmp.path().join("origin");
    fs::create_dir_all(&origin).unwrap();
    new_repo(&origin);
    let work = tmp.path().join("work");
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
    let pushed = head(&work);
    let local = commit_file(&work, "x.txt", "x\n", "local only");
    let repo = open(&work);
    assert!(repo.is_ancestor(pushed.clone(), "HEAD".into()));
    assert!(!repo.is_ancestor(local.clone(), pushed.clone()));
    assert!(repo.is_pushed(pushed).unwrap());
    assert!(!repo.is_pushed(local).unwrap());
}
