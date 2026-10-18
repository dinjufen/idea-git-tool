//! Changelist（IDEA 的更改列表）：把本地改动分组，可分别提交。
//!
//! Changelist 不是 git 的概念，保存在 `.git/gitdeck/changelists.json`，不进入版本库。
//! 每个已跟踪文件的改动属于且只属于一个列表；新出现的改动归入活动列表，
//! 不再有改动的文件自动从列表中移除。未跟踪文件与冲突文件不归入列表（与 IDEA 一致）。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::git::status::ChangeKind;
use crate::repo::Repository;

/// 默认列表的名称（IDEA 的 “Changes”）。UI 可本地化显示，但存储时使用该名称。
pub const DEFAULT_CHANGELIST: &str = "Changes";

/// 默认列表的名称（UniFFI 不导出常量，客户端经此函数获取）。
#[uniffi::export]
pub fn default_changelist_name() -> String {
    DEFAULT_CHANGELIST.to_owned()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Changelist {
    pub name: String,
    /// 列表说明（IDEA 用作该列表的默认提交信息）。
    #[serde(default)]
    pub comment: String,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Changelists {
    /// 活动列表：新出现的改动归入该列表。
    pub active: String,
    /// 按创建顺序排列；第一个为默认列表。
    pub lists: Vec<Changelist>,
}

impl Default for Changelists {
    fn default() -> Self {
        Changelists {
            active: DEFAULT_CHANGELIST.into(),
            lists: vec![Changelist {
                name: DEFAULT_CHANGELIST.into(),
                comment: String::new(),
                paths: Vec::new(),
            }],
        }
    }
}

#[uniffi::export]
impl Repository {
    /// 当前的 Changelist：先与工作区状态同步（新改动归入活动列表，移除已无改动的文件）。
    pub fn changelists(&self) -> std::result::Result<Changelists, CoreError> {
        self.update_changelists(|_| Ok(()))
    }

    pub fn add_changelist(
        &self,
        name: String,
        comment: String,
        make_active: bool,
    ) -> std::result::Result<Changelists, CoreError> {
        let name = valid_name(&name)?;
        self.update_changelists(|state| {
            if state.lists.iter().any(|l| l.name == name) {
                return Err(duplicate(&name));
            }
            state.lists.push(Changelist {
                name: name.clone(),
                comment,
                paths: Vec::new(),
            });
            if make_active {
                state.active = name;
            }
            Ok(())
        })
    }

    pub fn edit_changelist(
        &self,
        name: String,
        new_name: String,
        comment: String,
    ) -> std::result::Result<Changelists, CoreError> {
        let new_name = valid_name(&new_name)?;
        self.update_changelists(|state| {
            if new_name != name && state.lists.iter().any(|l| l.name == new_name) {
                return Err(duplicate(&new_name));
            }
            let list = state
                .lists
                .iter_mut()
                .find(|l| l.name == name)
                .ok_or_else(|| missing(&name))?;
            list.name = new_name.clone();
            list.comment = comment;
            if state.active == name {
                state.active = new_name;
            }
            Ok(())
        })
    }

    /// 删除列表，其中的文件移到活动列表（删除的是活动列表时改为第一个其他列表）。至少保留一个列表。
    pub fn remove_changelist(&self, name: String) -> std::result::Result<Changelists, CoreError> {
        self.update_changelists(|state| {
            let index = state
                .lists
                .iter()
                .position(|l| l.name == name)
                .ok_or_else(|| missing(&name))?;
            if state.lists.len() == 1 {
                return Err(CoreError::Parse {
                    detail: "cannot remove the last changelist".into(),
                });
            }
            let removed = state.lists.remove(index);
            if state.active == name {
                state.active = state.lists[0].name.clone();
            }
            let active = state.active.clone();
            if let Some(target) = state.lists.iter_mut().find(|l| l.name == active) {
                target.paths.extend(removed.paths);
            }
            Ok(())
        })
    }

    pub fn set_active_changelist(
        &self,
        name: String,
    ) -> std::result::Result<Changelists, CoreError> {
        self.update_changelists(|state| {
            if !state.lists.iter().any(|l| l.name == name) {
                return Err(missing(&name));
            }
            state.active = name;
            Ok(())
        })
    }

    /// 把文件移到指定列表（IDEA 的 Move to Another Changelist）。
    pub fn move_to_changelist(
        &self,
        paths: Vec<String>,
        name: String,
    ) -> std::result::Result<Changelists, CoreError> {
        self.update_changelists(|state| {
            if !state.lists.iter().any(|l| l.name == name) {
                return Err(missing(&name));
            }
            for list in &mut state.lists {
                list.paths.retain(|p| !paths.contains(p));
            }
            if let Some(target) = state.lists.iter_mut().find(|l| l.name == name) {
                target.paths.extend(paths.iter().cloned());
            }
            Ok(())
        })
    }
}

impl Repository {
    fn changelists_path(&self) -> PathBuf {
        self.git_dir.join("gitdeck").join("changelists.json")
    }

    /// 读取、同步、修改后写回。
    fn update_changelists(
        &self,
        change: impl FnOnce(&mut Changelists) -> Result<()>,
    ) -> Result<Changelists> {
        let path = self.changelists_path();
        let mut state: Changelists = std::fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .filter(|s: &Changelists| !s.lists.is_empty())
            .unwrap_or_default();
        if !state.lists.iter().any(|l| l.name == state.active) {
            state.active = state.lists[0].name.clone();
        }
        change(&mut state)?;

        // 与工作区同步。
        let status = self.status()?;
        let changed: Vec<&str> = status
            .changes
            .iter()
            .filter(|c| {
                c.conflict.is_none()
                    && !matches!(c.unstaged, ChangeKind::Untracked | ChangeKind::Ignored)
            })
            .map(|c| c.path.as_str())
            .collect();
        let mut seen = std::collections::HashSet::new();
        for list in &mut state.lists {
            list.paths
                .retain(|p| changed.contains(&p.as_str()) && seen.insert(p.clone()));
            list.paths.sort();
        }
        let active = state.active.clone();
        if let Some(target) = state.lists.iter_mut().find(|l| l.name == active) {
            for path in changed.iter().filter(|p| !seen.contains(**p)) {
                target.paths.push((*path).to_owned());
            }
            target.paths.sort();
        }

        std::fs::create_dir_all(path.parent().unwrap_or(&self.git_dir))?;
        let json = serde_json::to_vec_pretty(&state).map_err(|e| CoreError::Parse {
            detail: e.to_string(),
        })?;
        std::fs::write(&path, json)?;
        Ok(state)
    }
}

fn valid_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() {
        Err(CoreError::Parse {
            detail: "changelist name is empty".into(),
        })
    } else {
        Ok(name.to_owned())
    }
}

fn duplicate(name: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("changelist {name:?} already exists"),
    }
}

fn missing(name: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("changelist {name:?} does not exist"),
    }
}
