//! 提交图布局：把按顺序排列的提交分配到泳道（lane），并生成每行需要绘制的线段。
//!
//! 每行分上下两半绘制：
//! - `Top`：从行顶部的泳道 `from_lane` 连到本行节点（`to_lane` 即节点所在泳道）；
//! - `Bottom`：从本行节点连到行底部的泳道 `to_lane`（指向父提交）；
//! - `Full`：穿过本行的泳道，从顶部 `from_lane` 连到底部 `to_lane`。
//!
//! 每行结束后会压缩空出的泳道，因此 `from_lane` 与 `to_lane` 可能不同，绘制为斜线。

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EdgePart {
    Full,
    Top,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct GraphEdge {
    pub from_lane: u32,
    pub to_lane: u32,
    pub part: EdgePart,
    /// 颜色序号，由 UI 映射到调色板。
    pub color: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GraphRow {
    /// 节点所在泳道。
    pub lane: u32,
    pub color: u32,
    pub edges: Vec<GraphEdge>,
    /// 本行用到的泳道数，用于计算图形列宽。
    pub width: u32,
}

struct Lane<'a> {
    /// 该泳道等待的下一个提交。
    target: &'a str,
    color: u32,
}

/// `commits` 按显示顺序排列（子提交在父提交之前），每项为 `(哈希, 父提交)`。
pub fn layout<'a, P>(commits: &'a [(String, P)]) -> Vec<GraphRow>
where
    P: AsRef<[String]> + 'a,
{
    let mut rows = Vec::with_capacity(commits.len());
    let mut lanes: Vec<Lane<'a>> = Vec::new();
    let mut next_color = 0u32;
    let mut alloc_color = || {
        let c = next_color;
        next_color += 1;
        c
    };

    for (hash, parents) in commits {
        let parents = parents.as_ref();
        let incoming: Vec<usize> = lanes
            .iter()
            .enumerate()
            .filter(|(_, l)| l.target == hash)
            .map(|(i, _)| i)
            .collect();
        // 没有泳道在等待它：这是一个分支的顶端，放在最右侧的新泳道。
        let (node_lane, color) = match incoming.first() {
            Some(&i) => (i, lanes[i].color),
            None => (lanes.len(), alloc_color()),
        };

        let mut edges: Vec<GraphEdge> = incoming
            .iter()
            .map(|&i| GraphEdge {
                from_lane: i as u32,
                to_lane: node_lane as u32,
                part: EdgePart::Top,
                color: lanes[i].color,
            })
            .collect();

        let mut next: Vec<Option<Lane<'a>>> = lanes
            .iter()
            .enumerate()
            .map(|(i, l)| {
                (!incoming.contains(&i)).then_some(Lane {
                    target: l.target,
                    color: l.color,
                })
            })
            .collect();
        if node_lane == next.len() {
            next.push(None);
        }

        // 每个父提交落到的泳道（压缩前的下标）与连线颜色。
        let mut parent_slots: Vec<(usize, u32)> = Vec::with_capacity(parents.len());
        for (index, parent) in parents.iter().enumerate() {
            let parent = parent.as_str();
            if let Some(j) = next
                .iter()
                .position(|l| l.as_ref().is_some_and(|l| l.target == parent))
            {
                // 父提交已被其他泳道等待：本分支汇入该泳道。
                parent_slots.push((j, color));
            } else if index == 0 && next[node_lane].is_none() {
                // 第一个父提交沿用当前泳道和颜色。
                next[node_lane] = Some(Lane {
                    target: parent,
                    color,
                });
                parent_slots.push((node_lane, color));
            } else {
                // 其他父提交（合并进来的分支）开新泳道：优先使用节点右侧的空位。
                let c = alloc_color();
                let slot = (node_lane + 1..next.len())
                    .find(|&k| next[k].is_none())
                    .unwrap_or_else(|| {
                        next.push(None);
                        next.len() - 1
                    });
                next[slot] = Some(Lane {
                    target: parent,
                    color: c,
                });
                parent_slots.push((slot, c));
            }
        }

        // 压缩空泳道：旧下标 → 新下标。
        let mut compacted = vec![0usize; next.len()];
        let mut k = 0;
        for (i, lane) in next.iter().enumerate() {
            compacted[i] = k;
            if lane.is_some() {
                k += 1;
            }
        }

        for (i, lane) in lanes.iter().enumerate() {
            if !incoming.contains(&i) {
                edges.push(GraphEdge {
                    from_lane: i as u32,
                    to_lane: compacted[i] as u32,
                    part: EdgePart::Full,
                    color: lane.color,
                });
            }
        }
        for &(slot, c) in &parent_slots {
            edges.push(GraphEdge {
                from_lane: node_lane as u32,
                to_lane: compacted[slot] as u32,
                part: EdgePart::Bottom,
                color: c,
            });
        }

        let before = lanes.len();
        lanes = next.into_iter().flatten().collect();
        rows.push(GraphRow {
            lane: node_lane as u32,
            color,
            edges,
            width: before.max(lanes.len()).max(node_lane + 1) as u32,
        });
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commits(spec: &[(&str, &[&str])]) -> Vec<(String, Vec<String>)> {
        spec.iter()
            .map(|(h, ps)| (h.to_string(), ps.iter().map(|p| p.to_string()).collect()))
            .collect()
    }

    fn edge(from: u32, to: u32, part: EdgePart, color: u32) -> GraphEdge {
        GraphEdge {
            from_lane: from,
            to_lane: to,
            part,
            color,
        }
    }

    #[test]
    fn linear_history_stays_in_one_lane() {
        let rows = layout(&commits(&[("c", &["b"]), ("b", &["a"]), ("a", &[])]));
        assert!(
            rows.iter()
                .all(|r| r.lane == 0 && r.color == 0 && r.width == 1)
        );
        assert_eq!(rows[0].edges, [edge(0, 0, EdgePart::Bottom, 0)]);
        assert_eq!(
            rows[1].edges,
            [
                edge(0, 0, EdgePart::Top, 0),
                edge(0, 0, EdgePart::Bottom, 0)
            ]
        );
        assert_eq!(rows[2].edges, [edge(0, 0, EdgePart::Top, 0)]);
    }

    #[test]
    fn branch_and_merge() {
        // m 合并 b，a 与 b 都基于 base。
        let rows = layout(&commits(&[
            ("m", &["a", "b"]),
            ("b", &["base"]),
            ("a", &["base"]),
            ("base", &[]),
        ]));

        // m：第一个父提交留在泳道 0，第二个父提交开新泳道 1。
        assert_eq!((rows[0].lane, rows[0].width), (0, 2));
        assert_eq!(
            rows[0].edges,
            [
                edge(0, 0, EdgePart::Bottom, 0),
                edge(0, 1, EdgePart::Bottom, 1)
            ]
        );
        // b 在泳道 1，泳道 0 穿过。
        assert_eq!((rows[1].lane, rows[1].color), (1, 1));
        assert!(rows[1].edges.contains(&edge(0, 0, EdgePart::Full, 0)));
        assert!(rows[1].edges.contains(&edge(1, 1, EdgePart::Bottom, 1)));
        // a 汇入等待 base 的泳道 1；压缩后该泳道移到 0，穿过线画成斜线。
        assert_eq!(rows[2].lane, 0);
        assert!(rows[2].edges.contains(&edge(1, 0, EdgePart::Full, 1)));
        assert!(rows[2].edges.contains(&edge(0, 0, EdgePart::Bottom, 0)));
        // base 只有一条入线。
        assert_eq!(rows[3].lane, 0);
        assert_eq!(rows[3].edges, [edge(0, 0, EdgePart::Top, 1)]);
    }

    #[test]
    fn two_branch_heads_share_history() {
        // 两个分支顶端 x、y 都指向 base。
        let rows = layout(&commits(&[
            ("x", &["base"]),
            ("y", &["base"]),
            ("base", &[]),
        ]));
        assert_eq!(rows[0].lane, 0);
        assert_eq!((rows[1].lane, rows[1].color), (1, 1));
        // y 的父提交已在泳道 0 等待：y 汇入泳道 0。
        assert!(rows[1].edges.contains(&edge(1, 0, EdgePart::Bottom, 1)));
        assert_eq!(rows[2].edges, [edge(0, 0, EdgePart::Top, 0)]);
    }

    #[test]
    fn parent_outside_list_keeps_lane_open() {
        // 分页或筛选后父提交不在列表中：线条延伸到底部。
        let rows = layout(&commits(&[("b", &["a"])]));
        assert_eq!(rows[0].edges, [edge(0, 0, EdgePart::Bottom, 0)]);
    }
}
