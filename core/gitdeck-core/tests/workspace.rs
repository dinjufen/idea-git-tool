//! 远程、工作树、子模块、补丁与 Console 的集成测试。

mod common;

use std::fs;
use std::path::Path;

use common::{canonical, commit_file, configure, git, head, new_repo, open};
use gitdeck_core::{SubmoduleState, console_entries};

#[test]
fn manage_remotes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let repo = open(dir);
    repo.add_remote("origin".into(), "https://example.com/a.git".into())
        .unwrap();
    repo.add_remote("upstream".into(), "git@example.com:b.git".into())
        .unwrap();
    repo.rename_remote("upstream".into(), "fork".into())
        .unwrap();
    repo.set_remote_url("origin".into(), "https://example.com/new.git".into())
        .unwrap();
    let mut remotes: Vec<_> = repo
        .remotes()
        .unwrap()
        .into_iter()
        .map(|r| (r.name, r.url))
        .collect();
    remotes.sort();
    assert_eq!(
        remotes,
        [
            ("fork".into(), "git@example.com:b.git".into()),
            ("origin".into(), "https://example.com/new.git".into())
        ]
    );
    repo.remove_remote("fork".into()).unwrap();
    assert_eq!(repo.remotes().unwrap().len(), 1);
    assert!(repo.add_remote("--bad".into(), "x".into()).is_err());
}

#[test]
fn worktrees_add_list_remove() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("repo");
    fs::create_dir_all(&dir).unwrap();
    new_repo(&dir);
    git(&dir, &["branch", "existing"]);
    let repo = open(&dir);

    let new_path = tmp.path().join("wt-new");
    repo.add_worktree(
        new_path.to_string_lossy().into(),
        None,
        Some("feature/wt".into()),
        None,
    )
    .unwrap();
    let existing_path = tmp.path().join("wt-existing");
    repo.add_worktree(
        existing_path.to_string_lossy().into(),
        Some("existing".into()),
        None,
        None,
    )
    .unwrap();

    let list = repo.worktrees().unwrap();
    assert_eq!(list.len(), 3);
    assert!(list[0].is_main && list[0].is_current);
    // 主工作树总在第一位，其余的顺序由 git 决定。
    assert_eq!(list[0].branch.as_deref(), Some("main"));
    let added = list
        .iter()
        .find(|w| w.branch.as_deref() == Some("feature/wt"))
        .unwrap();
    assert_eq!(canonical(Path::new(&added.path)), canonical(&new_path));
    assert!(list.iter().any(|w| w.branch.as_deref() == Some("existing")));

    // 在工作树中打开仓库时，is_current 指向它自己。
    let in_worktree = open(&new_path).worktrees().unwrap();
    assert!(
        in_worktree
            .iter()
            .find(|w| w.is_current)
            .unwrap()
            .branch
            .as_deref()
            == Some("feature/wt")
    );

    repo.remove_worktree(new_path.to_string_lossy().into(), false)
        .unwrap();
    assert_eq!(repo.worktrees().unwrap().len(), 2);
}

#[test]
fn submodules_status_and_update() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = tmp.path().join("lib");
    fs::create_dir_all(&lib).unwrap();
    new_repo(&lib);
    let app = tmp.path().join("app");
    fs::create_dir_all(&app).unwrap();
    new_repo(&app);
    // git 2.38+ 默认禁止 file:// 子模块，测试中显式允许。
    git(
        &app,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            lib.to_str().unwrap(),
            "libs/lib",
        ],
    );
    git(&app, &["commit", "-qm", "add submodule"]);

    let subs = open(&app).submodules().unwrap();
    assert_eq!(subs.len(), 1);
    assert_eq!(subs[0].path, "libs/lib");
    assert_eq!(subs[0].state, SubmoduleState::UpToDate);
    assert_eq!(subs[0].url.as_deref(), Some(lib.to_str().unwrap()));
    assert_eq!(subs[0].head, head(&lib));

    // 克隆后子模块未初始化。
    let clone = tmp.path().join("clone");
    git(
        tmp.path(),
        &[
            "clone",
            "-q",
            app.to_str().unwrap(),
            clone.to_str().unwrap(),
        ],
    );
    let repo = open(&clone);
    assert_eq!(
        repo.submodules().unwrap()[0].state,
        SubmoduleState::Uninitialized
    );
    // 初始化并更新子模块。git 克隆子模块时不读取仓库级配置，经环境变量允许 file:// 传输
    // （只影响本测试进程启动的 git；Rust 标准库对环境变量与进程启动加锁，不会与其他测试竞争）。
    unsafe {
        std::env::set_var("GIT_CONFIG_COUNT", "1");
        std::env::set_var("GIT_CONFIG_KEY_0", "protocol.file.allow");
        std::env::set_var("GIT_CONFIG_VALUE_0", "always");
    }
    repo.update_submodules(vec![], true).unwrap();
    let subs = repo.submodules().unwrap();
    assert_eq!(subs[0].state, SubmoduleState::UpToDate);
    assert_eq!(subs[0].head, head(&lib));
    assert!(clone.join("libs/lib/readme.md").exists());

    // 子模块检出了不同的提交时显示为 Modified，update 后恢复。
    let sub = clone.join("libs/lib");
    configure(&sub);
    commit_file(&sub, "extra.txt", "x\n", "extra in submodule");
    assert_eq!(
        repo.submodules().unwrap()[0].state,
        SubmoduleState::Modified
    );
    repo.update_submodules(vec!["libs/lib".into()], false)
        .unwrap();
    assert_eq!(
        repo.submodules().unwrap()[0].state,
        SubmoduleState::UpToDate
    );
    assert!(
        open(tmp.path().join("lib").as_path())
            .submodules()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn create_and_apply_patches() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a");
    fs::create_dir_all(&a).unwrap();
    new_repo(&a);
    commit_file(&a, "edit.txt", "1\n2\n", "add edit");
    let b = tmp.path().join("b");
    git(
        tmp.path(),
        &["clone", "-q", a.to_str().unwrap(), b.to_str().unwrap()],
    );
    common::configure(&b);

    fs::write(a.join("edit.txt"), "1\n2 changed\n").unwrap();
    fs::write(a.join("new file.txt"), "brand new\n").unwrap();
    fs::write(a.join("skip.txt"), "not selected\n").unwrap();
    let patch = open(&a)
        .create_patch(vec!["edit.txt".into(), "new file.txt".into()])
        .unwrap();
    assert!(patch.contains("new file.txt") && !patch.contains("skip.txt"));

    let target = open(&b);
    let mut files: Vec<_> = target
        .patch_files(patch.clone())
        .unwrap()
        .into_iter()
        .map(|f| (f.path, f.added, f.deleted))
        .collect();
    files.sort();
    assert_eq!(
        files,
        [("edit.txt".into(), 1, 1), ("new file.txt".into(), 1, 0)]
    );
    assert!(target.can_apply_patch(patch.clone()));
    assert!(!target.apply_patch(patch, false).unwrap().conflicts);
    assert_eq!(
        fs::read_to_string(b.join("edit.txt")).unwrap(),
        "1\n2 changed\n"
    );
    assert_eq!(
        fs::read_to_string(b.join("new file.txt")).unwrap(),
        "brand new\n"
    );

    // 提交导出的补丁。
    let c1 = commit_file(&a, "c.txt", "c\n", "add c");
    let commit_patch = open(&a).create_patch_from_commits(vec![c1]).unwrap();
    assert!(commit_patch.starts_with("From ") && commit_patch.contains("Subject: [PATCH] add c"));
    let fresh = tmp.path().join("fresh");
    git(
        tmp.path(),
        &["clone", "-q", a.to_str().unwrap(), fresh.to_str().unwrap()],
    );
    git(&fresh, &["reset", "-q", "--hard", "HEAD~1"]);
    open(&fresh).apply_patch(commit_patch, false).unwrap();
    assert_eq!(fs::read_to_string(fresh.join("c.txt")).unwrap(), "c\n");
}

#[test]
fn console_records_commands() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let marker = format!("console-check-{}", std::process::id());
    let repo = open(dir);
    repo.create_branch(marker.clone(), None, false).unwrap();
    let entry = console_entries(0)
        .into_iter()
        .find(|e| e.command.starts_with("git branch") && e.command.contains(&marker))
        .expect("branch command recorded");
    assert_eq!(entry.exit_code, 0);
    assert!(!entry.background);
    // 创建前的名称校验属于后台查询。
    assert!(
        console_entries(0)
            .iter()
            .any(|e| e.command.contains("check-ref-format") && e.background)
    );
}

#[test]
fn finds_nested_repositories_and_submodules() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = tmp.path().join("lib");
    fs::create_dir_all(&lib).unwrap();
    new_repo(&lib);
    let app = tmp.path().join("app");
    fs::create_dir_all(&app).unwrap();
    new_repo(&app);
    git(
        &app,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            lib.to_str().unwrap(),
            "libs/lib",
        ],
    );
    git(&app, &["commit", "-qm", "add submodule"]);
    // 独立的嵌套仓库（被父仓库忽略）、过深的仓库与依赖目录中的仓库。
    fs::write(app.join(".gitignore"), "services/\nnode_modules/\n").unwrap();
    for dir in ["services/api", "a/b/c/d/deep", "node_modules/pkg"] {
        let path = app.join(dir);
        fs::create_dir_all(&path).unwrap();
        new_repo(&path);
    }
    let found = open(&app).nested_repositories(3).unwrap();
    let names: Vec<_> = found
        .iter()
        .map(|r| (r.relative_path.as_str(), r.is_submodule))
        .collect();
    assert_eq!(names, [("libs/lib", true), ("services/api", false)]);
    assert!(Path::new(&found[1].path).ends_with("services/api"));
}
