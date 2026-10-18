//! 标签的集成测试。

mod common;

use std::fs;

use common::{commit_file, git, head, new_repo, open};
use gitdeck_core::CoreError;

#[test]
fn create_list_and_delete_tags() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let first = head(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    let repo = open(dir);

    repo.create_tag(
        "v1.0".into(),
        Some(first.clone()),
        Some("Release 1.0\n\nNotes".into()),
    )
    .unwrap();
    repo.create_tag("v1.1".into(), None, None).unwrap();
    assert!(!repo.is_valid_tag_name("bad tag".into()));
    assert!(matches!(
        repo.create_tag("-x".into(), None, None),
        Err(CoreError::InvalidTagName { .. })
    ));

    let tags = repo.tags().unwrap();
    let names: Vec<_> = tags.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["v1.1", "v1.0"]);
    assert!(tags[1].annotated);
    assert_eq!(tags[1].target, first);
    assert_eq!(tags[1].message.as_deref(), Some("Release 1.0"));
    assert!(!tags[0].annotated);
    assert_eq!(tags[0].target, head(dir));

    repo.delete_tag("v1.0".into()).unwrap();
    assert_eq!(repo.tags().unwrap().len(), 1);
}

#[test]
fn push_and_delete_remote_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let seed = tmp.path().join("seed");
    fs::create_dir_all(&seed).unwrap();
    new_repo(&seed);
    let origin = tmp.path().join("origin.git");
    git(
        tmp.path(),
        &[
            "clone",
            "-q",
            "--bare",
            seed.to_str().unwrap(),
            origin.to_str().unwrap(),
        ],
    );
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
    let repo = open(&work);

    repo.create_tag("v2".into(), None, Some("two".into()))
        .unwrap();
    repo.push_tag("origin".into(), "v2".into()).unwrap();
    assert_eq!(git(&origin, &["tag", "--list"]).trim(), "v2");
    repo.delete_remote_tag("origin".into(), "v2".into())
        .unwrap();
    assert!(git(&origin, &["tag", "--list"]).trim().is_empty());
}
