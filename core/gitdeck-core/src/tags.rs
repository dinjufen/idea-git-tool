//! 标签（IDEA 的 New Tag、分支弹窗中的标签与推送 / 删除标签）。

use crate::error::{CoreError, Result};
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagInfo {
    pub name: String,
    /// 标签指向的提交（附注标签已解引用）。
    pub target: String,
    pub annotated: bool,
    /// 附注标签的说明（第一行）。
    pub message: Option<String>,
}

#[uniffi::export]
impl Repository {
    /// 所有标签，按版本号从新到旧排序。
    pub fn tags(&self) -> std::result::Result<Vec<TagInfo>, CoreError> {
        let out = self.git.run(
            &self.root,
            [
                "for-each-ref",
                "--sort=-v:refname",
                "--format=%(refname:short)%1f%(objecttype)%1f%(objectname)%1f%(*objectname)%1f%(contents:subject)%1e",
                "refs/tags",
            ],
        )?;
        let text = String::from_utf8_lossy(&out.stdout);
        Ok(text
            .split('\x1e')
            .map(|r| r.trim_start_matches('\n'))
            .filter(|r| !r.is_empty())
            .filter_map(|r| {
                let f: Vec<&str> = r.splitn(5, '\x1f').collect();
                let [name, kind, object, peeled, subject] = f[..] else {
                    return None;
                };
                let annotated = kind == "tag";
                Some(TagInfo {
                    name: name.to_owned(),
                    target: if annotated { peeled } else { object }.to_owned(),
                    annotated,
                    message: (annotated && !subject.is_empty()).then(|| subject.to_owned()),
                })
            })
            .collect())
    }

    pub fn is_valid_tag_name(&self, name: String) -> bool {
        let reference = format!("refs/tags/{name}");
        !name.is_empty()
            && !name.starts_with('-')
            && self
                .git
                .run(&self.root, ["check-ref-format", reference.as_str()])
                .is_ok()
    }

    /// 在 `target`（默认 HEAD）上创建标签；提供 `message` 时创建附注标签。
    pub fn create_tag(
        &self,
        name: String,
        target: Option<String>,
        message: Option<String>,
    ) -> std::result::Result<(), CoreError> {
        if !self.is_valid_tag_name(name.clone()) {
            return Err(CoreError::InvalidTagName { name });
        }
        if let Some(target) = target.as_deref().filter(|t| t.starts_with('-')) {
            return Err(CoreError::Parse {
                detail: format!("invalid revision: {target:?}"),
            });
        }
        let message = message.filter(|m| !m.trim().is_empty());
        let mut args: Vec<&str> = vec!["tag"];
        if let Some(message) = message.as_deref() {
            args.extend(["-a", "-m", message]);
        }
        args.push(name.as_str());
        args.extend(target.as_deref());
        self.git.run(&self.root, args)?;
        Ok(())
    }

    pub fn delete_tag(&self, name: String) -> std::result::Result<(), CoreError> {
        let reference = format!("refs/tags/{name}");
        self.git
            .run(&self.root, ["update-ref", "-d", reference.as_str()])?;
        Ok(())
    }

    pub fn push_tag(&self, remote: String, name: String) -> std::result::Result<(), CoreError> {
        let refspec = format!("refs/tags/{name}:refs/tags/{name}");
        self.push_refspec(&remote, &refspec)
    }

    pub fn delete_remote_tag(
        &self,
        remote: String,
        name: String,
    ) -> std::result::Result<(), CoreError> {
        let refspec = format!(":refs/tags/{name}");
        self.push_refspec(&remote, &refspec)
    }
}

impl Repository {
    fn push_refspec(&self, remote: &str, refspec: &str) -> Result<()> {
        if remote.starts_with('-') {
            return Err(CoreError::Parse {
                detail: format!("invalid remote: {remote:?}"),
            });
        }
        self.git
            .run(&self.root, ["push", "--end-of-options", remote, refspec])
            .map_err(CoreError::classify_remote)?;
        Ok(())
    }
}
