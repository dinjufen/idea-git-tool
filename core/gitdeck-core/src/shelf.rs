//! Shelve（IDEA 的搁置）：把选中的改动保存为补丁并从工作区撤销，之后可以再取回（Unshelve）。
//!
//! 与 stash 不同，搁置的改动按文件保存、可以只取回部分文件，且不进入 git 的引用。
//! 数据保存在 `.git/gitdeck/shelf/<id>/`：`shelf.json`（名称、时间、文件）与 `changes.patch`。

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::git::status::ChangeKind;
use crate::patch::{PatchFile, PatchOutcome, section_path, split_sections};
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShelfEntry {
    pub id: String,
    pub name: String,
    /// 搁置时间（Unix 秒）。
    pub time: i64,
    pub files: Vec<PatchFile>,
}

#[derive(Serialize, Deserialize)]
struct Metadata {
    name: String,
    time: i64,
}

const PATCH_FILE: &str = "changes.patch";
const META_FILE: &str = "shelf.json";

#[uniffi::export]
impl Repository {
    /// 搁置选中文件的改动（含未跟踪文件），然后把这些文件恢复到 HEAD（未跟踪文件被删除）。
    pub fn shelve_changes(
        &self,
        paths: Vec<String>,
        name: String,
    ) -> std::result::Result<ShelfEntry, CoreError> {
        let status = self.status()?;
        let selected: Vec<_> = status
            .changes
            .iter()
            .filter(|c| c.conflict.is_none() && c.unstaged != ChangeKind::Ignored)
            .filter(|c| paths.is_empty() || paths.contains(&c.path))
            .collect();
        if selected.is_empty() {
            return Err(CoreError::NothingToCommit);
        }
        let selected_paths: Vec<String> = selected.iter().map(|c| c.path.clone()).collect();
        let patch = self.local_diff(&selected_paths, true)?;
        if patch.trim().is_empty() {
            return Err(CoreError::NothingToCommit);
        }

        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let id = format!("{time}");
        let dir = self.shelf_dir().join(&id);
        std::fs::create_dir_all(&dir)?;
        let name = if name.trim().is_empty() {
            format!("Shelved {id}")
        } else {
            name.trim().to_owned()
        };
        let meta = Metadata {
            name,
            time: (time / 1000) as i64,
        };
        std::fs::write(dir.join(PATCH_FILE), &patch)?;
        std::fs::write(
            dir.join(META_FILE),
            serde_json::to_vec_pretty(&meta).map_err(json_error)?,
        )?;

        // 补丁已安全写入后再撤销工作区改动。
        let tracked: Vec<String> = selected
            .iter()
            .filter(|c| c.unstaged != ChangeKind::Untracked)
            .map(|c| c.path.clone())
            .collect();
        if !tracked.is_empty() {
            self.rollback(tracked, true)?;
        }
        for change in selected
            .iter()
            .filter(|c| c.unstaged == ChangeKind::Untracked)
        {
            let full = self.root.join(&change.path);
            if full.is_file() || full.is_symlink() {
                std::fs::remove_file(full)?;
            }
        }
        self.read_shelf(&id)
    }

    /// 所有搁置的改动，最新的在前。
    pub fn shelves(&self) -> std::result::Result<Vec<ShelfEntry>, CoreError> {
        let Ok(entries) = std::fs::read_dir(self.shelf_dir()) else {
            return Ok(Vec::new());
        };
        let mut list: Vec<ShelfEntry> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().join(PATCH_FILE).is_file())
            .filter_map(|e| self.read_shelf(&e.file_name().to_string_lossy()).ok())
            .collect();
        list.sort_by(|a, b| b.time.cmp(&a.time).then(b.id.cmp(&a.id)));
        Ok(list)
    }

    /// 搁置的补丁全文（Shelf 中查看 Diff 用）。
    pub fn shelf_patch(&self, id: String) -> std::result::Result<String, CoreError> {
        Ok(std::fs::read_to_string(
            self.shelf_entry_dir(&id)?.join(PATCH_FILE),
        )?)
    }

    /// 取回搁置的改动；`paths` 为空时取回全部文件。不能直接应用时用三方合并，冲突留给用户解决。
    /// `keep` 为 false 时从搁置中移除已取回的文件（全部取回后删除该条目）。
    pub fn unshelve(
        &self,
        id: String,
        paths: Vec<String>,
        keep: bool,
    ) -> std::result::Result<PatchOutcome, CoreError> {
        let dir = self.shelf_entry_dir(&id)?;
        let patch = std::fs::read_to_string(dir.join(PATCH_FILE))?;
        let (preamble, sections) = split_sections(&patch);
        let (chosen, rest): (Vec<&str>, Vec<&str>) = sections
            .into_iter()
            .partition(|s| paths.is_empty() || paths.contains(&section_path(s)));
        if chosen.is_empty() {
            return Err(CoreError::NothingToCommit);
        }
        let outcome = self.apply_patch(format!("{preamble}{}", chosen.concat()), true)?;
        if !keep {
            if rest.is_empty() {
                std::fs::remove_dir_all(&dir)?;
            } else {
                std::fs::write(dir.join(PATCH_FILE), format!("{preamble}{}", rest.concat()))?;
            }
        }
        Ok(outcome)
    }

    pub fn delete_shelf(&self, id: String) -> std::result::Result<(), CoreError> {
        std::fs::remove_dir_all(self.shelf_entry_dir(&id)?)?;
        Ok(())
    }

    pub fn rename_shelf(&self, id: String, name: String) -> std::result::Result<(), CoreError> {
        let dir = self.shelf_entry_dir(&id)?;
        let mut meta = read_meta(&dir)?;
        meta.name = name.trim().to_owned();
        std::fs::write(
            dir.join(META_FILE),
            serde_json::to_vec_pretty(&meta).map_err(json_error)?,
        )?;
        Ok(())
    }
}

impl Repository {
    fn shelf_dir(&self) -> PathBuf {
        self.git_dir.join("gitdeck").join("shelf")
    }

    /// 条目目录；拒绝含路径分隔符的 id。
    fn shelf_entry_dir(&self, id: &str) -> Result<PathBuf> {
        if id.is_empty() || id.contains(['/', '\\']) || id.starts_with('.') {
            return Err(CoreError::Parse {
                detail: format!("invalid shelf id: {id:?}"),
            });
        }
        let dir = self.shelf_dir().join(id);
        if !dir.is_dir() {
            return Err(CoreError::Io {
                detail: format!("shelf {id} does not exist"),
            });
        }
        Ok(dir)
    }

    fn read_shelf(&self, id: &str) -> Result<ShelfEntry> {
        let dir = self.shelf_entry_dir(id)?;
        let meta = read_meta(&dir)?;
        let patch = std::fs::read_to_string(dir.join(PATCH_FILE))?;
        Ok(ShelfEntry {
            id: id.to_owned(),
            name: meta.name,
            time: meta.time,
            files: self.patch_files(patch)?,
        })
    }
}

fn read_meta(dir: &std::path::Path) -> Result<Metadata> {
    let data = std::fs::read(dir.join(META_FILE))?;
    serde_json::from_slice(&data).map_err(json_error)
}

fn json_error(e: serde_json::Error) -> CoreError {
    CoreError::Parse {
        detail: e.to_string(),
    }
}
