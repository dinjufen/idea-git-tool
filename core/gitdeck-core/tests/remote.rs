//! Fetch / Update Project / Push 的集成测试，远程为本地的裸仓库。

mod common;

use std::fs;
use std::path::{Path, PathBuf};

use common::{commit_file, configure, git, head, new_repo, open};
use gitdeck_core::{CoreError, MergeOutcome, PushOptions, UpdateMethod};

/// 创建裸远程 `origin.git`，并克隆出 `work` 与 `other` 两个工作副本。
fn setup(tmp: &Path) -> (PathBuf, PathBuf, PathBuf) {
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
    (origin, work, other)
}

#[test]
fn lists_remotes_and_fetches() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, other) = setup(tmp.path());
    let repo = open(&work);
    let remotes = repo.remotes().unwrap();
    assert_eq!(remotes.len(), 1);
    assert_eq!(remotes[0].name, "origin");

    commit_file(&other, "o.txt", "o\n", "from other");
    git(&other, &["push", "-q", "origin", "main"]);
    git(
        &other,
        &["push", "-q", "origin", "main:refs/heads/new-branch"],
    );
    assert_eq!(repo.fetch(false).unwrap(), 2);
    assert_eq!(repo.fetch(false).unwrap(), 0);
}

#[test]
fn update_project_merges_and_rebases_incoming_commits() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, other) = setup(tmp.path());
    commit_file(&other, "o.txt", "o\n", "from other");
    git(&other, &["push", "-q", "origin", "main"]);
    let repo = open(&work);

    // 本地没有新提交：快进。
    let result = repo.update_project(UpdateMethod::Merge).unwrap();
    assert_eq!(
        (result.outcome, result.received),
        (MergeOutcome::FastForward, 1)
    );
    assert_eq!(
        repo.update_project(UpdateMethod::Merge).unwrap().outcome,
        MergeOutcome::UpToDate
    );

    // 双方都有新提交：变基后历史保持线性。
    commit_file(&other, "o2.txt", "o2\n", "from other 2");
    git(&other, &["push", "-q", "origin", "main"]);
    commit_file(&work, "w.txt", "w\n", "local work");
    let result = repo.update_project(UpdateMethod::Rebase).unwrap();
    assert_eq!(result.outcome, MergeOutcome::Merged);
    assert_eq!(
        git(&work, &["log", "-1", "--format=%P"])
            .split_whitespace()
            .count(),
        1
    );
    assert_eq!(
        git(&work, &["log", "-1", "--format=%s"]).trim(),
        "local work"
    );
}

#[test]
fn update_project_stashes_local_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, other) = setup(tmp.path());
    commit_file(
        &other,
        "readme.md",
        "hello\nfrom other\n",
        "other edits readme",
    );
    git(&other, &["push", "-q", "origin", "main"]);
    // 本地改动的是另一个文件，更新后应完整恢复。
    commit_file(&work, "local.txt", "1\n", "local file");
    fs::write(work.join("local.txt"), "1\n2\n").unwrap();

    let result = open(&work).update_project(UpdateMethod::Merge).unwrap();
    assert_eq!(result.outcome, MergeOutcome::Merged);
    assert!(!result.stash_conflicts && !result.stash_kept);
    assert_eq!(
        fs::read_to_string(work.join("local.txt")).unwrap(),
        "1\n2\n"
    );
    assert!(git(&work, &["stash", "list"]).trim().is_empty());
}

#[test]
fn update_project_conflict_keeps_stash() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, other) = setup(tmp.path());
    commit_file(&other, "readme.md", "other\n", "other");
    git(&other, &["push", "-q", "origin", "main"]);
    commit_file(&work, "readme.md", "work\n", "work");
    commit_file(&work, "local.txt", "1\n", "local");
    fs::write(work.join("local.txt"), "dirty\n").unwrap();

    let result = open(&work).update_project(UpdateMethod::Merge).unwrap();
    assert_eq!(result.outcome, MergeOutcome::Conflicts);
    assert!(result.stash_kept);
    assert!(!git(&work, &["stash", "list"]).trim().is_empty());
}

#[test]
fn update_requires_upstream_and_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, _) = setup(tmp.path());
    git(&work, &["checkout", "-q", "-b", "local-only"]);
    let repo = open(&work);
    assert_eq!(
        repo.update_project(UpdateMethod::Merge).unwrap_err(),
        CoreError::NoUpstream {
            branch: "local-only".into()
        }
    );
    git(&work, &["checkout", "-q", "--detach"]);
    assert_eq!(
        repo.update_project(UpdateMethod::Merge).unwrap_err(),
        CoreError::DetachedHead
    );
}

#[test]
fn push_target_and_push_new_branch_with_upstream() {
    let tmp = tempfile::tempdir().unwrap();
    let (origin, work, _) = setup(tmp.path());
    let repo = open(&work);

    commit_file(&work, "a.txt", "a\n", "one");
    commit_file(&work, "b.txt", "b\n", "two");
    let target = repo.push_target().unwrap();
    assert!(target.has_upstream);
    assert_eq!(
        (target.remote.as_deref(), target.remote_branch.as_str()),
        (Some("origin"), "main")
    );
    let subjects: Vec<_> = target.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects, ["two", "one"]);

    git(&work, &["checkout", "-q", "-b", "feature"]);
    commit_file(&work, "f.txt", "f\n", "feature");
    let target = repo.push_target().unwrap();
    assert!(!target.has_upstream);
    assert_eq!(target.remote_branch, "feature");
    // 新分支：列出所有不在 origin 上的提交（包括 main 上尚未推送的两个）。
    assert_eq!(target.commits.len(), 3);

    let result = repo
        .push(PushOptions {
            local_branch: "feature".into(),
            remote: "origin".into(),
            remote_branch: "feature".into(),
            force: false,
            push_tags: false,
            set_upstream: true,
        })
        .unwrap();
    assert_eq!(result.pushed_commits, 3);
    assert_eq!(git(&origin, &["rev-parse", "feature"]).trim(), head(&work));
    assert_eq!(
        git(&work, &["rev-parse", "--abbrev-ref", "feature@{u}"]).trim(),
        "origin/feature"
    );
    assert!(repo.push_target().unwrap().commits.is_empty());

    // 非当前分支的推送目标：main 有上游，列出它尚未推送的两个提交。
    let main = repo.push_target_for("main".into()).unwrap();
    assert!(main.has_upstream);
    assert_eq!(main.local_branch, "main");
    assert_eq!(main.remote_branch, "main");
    assert_eq!(main.commits.len(), 2);
}

#[test]
fn push_rejected_then_forced_with_lease() {
    let tmp = tempfile::tempdir().unwrap();
    let (origin, work, other) = setup(tmp.path());
    commit_file(&other, "o.txt", "o\n", "other wins");
    git(&other, &["push", "-q", "origin", "main"]);
    commit_file(&work, "w.txt", "w\n", "work");
    let repo = open(&work);
    let options = PushOptions {
        local_branch: "main".into(),
        remote: "origin".into(),
        remote_branch: "main".into(),
        force: false,
        push_tags: false,
        set_upstream: false,
    };

    match repo.push(options.clone()) {
        Err(CoreError::PushRejected { reason }) => assert_eq!(reason, "fetch first"),
        other => panic!("unexpected: {other:?}"),
    }
    // 先 fetch 让本地知道远程的最新位置，再强制推送（带租约）。
    repo.fetch(false).unwrap();
    repo.push(PushOptions {
        force: true,
        ..options
    })
    .unwrap();
    assert_eq!(git(&origin, &["rev-parse", "main"]).trim(), head(&work));
}

#[test]
fn push_up_to_date() {
    let tmp = tempfile::tempdir().unwrap();
    let (_, work, _) = setup(tmp.path());
    let result = open(&work)
        .push(PushOptions {
            local_branch: "main".into(),
            remote: "origin".into(),
            remote_branch: "main".into(),
            force: false,
            push_tags: false,
            set_upstream: false,
        })
        .unwrap();
    assert!(result.up_to_date);
    assert_eq!(result.pushed_commits, 0);
}
