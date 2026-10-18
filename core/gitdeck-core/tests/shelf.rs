//! Changelist 与 Shelve 的集成测试。

mod common;

use std::fs;

use common::*;
use gitdeck_core::DEFAULT_CHANGELIST;

fn repo_with_changes(dir: &std::path::Path) {
    new_repo(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    commit_file(dir, "b.txt", "b\n", "b");
    fs::write(dir.join("a.txt"), "a changed\n").unwrap();
    fs::write(dir.join("b.txt"), "b changed\n").unwrap();
    fs::write(dir.join("new.txt"), "untracked\n").unwrap();
}

#[test]
fn changelists_track_changes_and_moves() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    repo_with_changes(dir);
    let repo = open(dir);

    let state = repo.changelists().unwrap();
    assert_eq!(state.active, DEFAULT_CHANGELIST);
    assert_eq!(state.lists.len(), 1);
    // 未跟踪文件不归入列表。
    assert_eq!(state.lists[0].paths, ["a.txt", "b.txt"]);

    let state = repo
        .add_changelist("Feature".into(), "work in progress".into(), false)
        .unwrap();
    assert!(
        repo.add_changelist("Feature".into(), String::new(), false)
            .is_err()
    );
    assert_eq!(state.lists[1].comment, "work in progress");
    let state = repo
        .move_to_changelist(vec!["b.txt".into()], "Feature".into())
        .unwrap();
    assert_eq!(state.lists[0].paths, ["a.txt"]);
    assert_eq!(state.lists[1].paths, ["b.txt"]);

    // 新出现的改动进入活动列表。
    repo.set_active_changelist("Feature".into()).unwrap();
    commit_file(dir, "c.txt", "c\n", "c");
    fs::write(dir.join("c.txt"), "c changed\n").unwrap();
    let state = repo.changelists().unwrap();
    assert_eq!(state.lists[1].paths, ["b.txt", "c.txt"]);

    // 不再有改动的文件被移除。
    git(dir, &["checkout", "--", "b.txt"]);
    let state = repo.changelists().unwrap();
    assert_eq!(state.lists[1].paths, ["c.txt"]);

    let state = repo
        .edit_changelist("Feature".into(), "Renamed".into(), String::new())
        .unwrap();
    assert_eq!(state.active, "Renamed");
    // 删除活动列表：文件回到第一个列表，并成为活动列表。
    let state = repo.remove_changelist("Renamed".into()).unwrap();
    assert_eq!(state.active, DEFAULT_CHANGELIST);
    assert_eq!(state.lists.len(), 1);
    assert_eq!(state.lists[0].paths, ["a.txt", "c.txt"]);
    assert!(repo.remove_changelist(DEFAULT_CHANGELIST.into()).is_err());
}

#[test]
fn shelve_and_unshelve_all() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    repo_with_changes(dir);
    let repo = open(dir);

    let entry = repo
        .shelve_changes(vec!["a.txt".into(), "new.txt".into()], "my work".into())
        .unwrap();
    assert_eq!(entry.name, "my work");
    let mut files: Vec<_> = entry.files.iter().map(|f| f.path.as_str()).collect();
    files.sort();
    assert_eq!(files, ["a.txt", "new.txt"]);
    // 工作区已撤销：a.txt 恢复，new.txt 删除，b.txt 不受影响。
    assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), "a\n");
    assert!(!dir.join("new.txt").exists());
    assert_eq!(
        fs::read_to_string(dir.join("b.txt")).unwrap(),
        "b changed\n"
    );
    assert_eq!(repo.shelves().unwrap().len(), 1);
    assert!(
        repo.shelf_patch(entry.id.clone())
            .unwrap()
            .contains("a changed")
    );

    let outcome = repo.unshelve(entry.id.clone(), vec![], false).unwrap();
    assert!(!outcome.conflicts);
    assert_eq!(
        fs::read_to_string(dir.join("a.txt")).unwrap(),
        "a changed\n"
    );
    assert_eq!(
        fs::read_to_string(dir.join("new.txt")).unwrap(),
        "untracked\n"
    );
    assert!(repo.shelves().unwrap().is_empty());
}

#[test]
fn unshelve_selected_files_and_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    repo_with_changes(dir);
    let repo = open(dir);
    let entry = repo.shelve_changes(vec![], String::new()).unwrap();
    assert!(entry.name.starts_with("Shelved"));
    assert_eq!(entry.files.len(), 3);

    // 只取回 b.txt 并保留在搁置中。
    repo.unshelve(entry.id.clone(), vec!["b.txt".into()], true)
        .unwrap();
    assert_eq!(
        fs::read_to_string(dir.join("b.txt")).unwrap(),
        "b changed\n"
    );
    assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), "a\n");
    assert_eq!(repo.shelves().unwrap()[0].files.len(), 3);

    // 取回 a.txt 并移除：搁置中剩下 b.txt 与 new.txt。
    git(dir, &["checkout", "--", "b.txt"]);
    repo.unshelve(entry.id.clone(), vec!["a.txt".into()], false)
        .unwrap();
    let remaining: Vec<_> = repo.shelves().unwrap()[0]
        .files
        .iter()
        .map(|f| f.path.clone())
        .collect();
    assert_eq!(remaining.len(), 2);
    assert!(!remaining.contains(&"a.txt".to_string()));

    repo.rename_shelf(entry.id.clone(), "renamed".into())
        .unwrap();
    assert_eq!(repo.shelves().unwrap()[0].name, "renamed");
    repo.delete_shelf(entry.id.clone()).unwrap();
    assert!(repo.shelves().unwrap().is_empty());
    assert!(repo.delete_shelf("../x".into()).is_err());
}

#[test]
fn unshelve_with_conflicts_uses_three_way_merge() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    repo_with_changes(dir);
    let repo = open(dir);
    let entry = repo
        .shelve_changes(vec!["a.txt".into()], "conflicting".into())
        .unwrap();
    commit_file(dir, "a.txt", "a committed differently\n", "diverge");
    let outcome = repo.unshelve(entry.id, vec![], false).unwrap();
    assert!(outcome.conflicts);
    assert!(
        fs::read_to_string(dir.join("a.txt"))
            .unwrap()
            .contains("<<<<<<<")
    );
}
