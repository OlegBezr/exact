//! A component's members written in other files (LLP 1091.002). The parser
//! records each `members "…"` line and where it stands; the loader reads the
//! files, scopes each through its own `use` lines with every member of the
//! component bound, then splices each file's block in at its line.

use crate::{Component, Span, SyntaxError};

/// A `members "./file.contract"` line in a component's body (D1).
#[derive(Debug, Clone, PartialEq)]
pub struct MembersLine {
    /// The path as written.
    pub path: String,
    /// The line's place among the component's own members.
    pub at: Splice,
    /// Where.
    pub span: Span,
}

/// How many of each kind of member the component declares before a line:
/// where that file's members are inserted (D4).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Splice {
    /// `state`s before the line.
    pub states: usize,
    /// `persist` states before the line.
    pub persist: usize,
    /// `derive`s before the line.
    pub derives: usize,
    /// `resource`s before the line.
    pub resources: usize,
    /// `mutation`s before the line.
    pub mutations: usize,
    /// `action`s before the line.
    pub actions: usize,
    /// `task`s before the line.
    pub tasks: usize,
    /// `sequence`s before the line.
    pub sequences: usize,
}

impl Splice {
    /// Where a line written after `c`'s members so far stands.
    pub fn after(c: &Component) -> Self {
        Splice {
            states: c.states.len(),
            persist: c.persist.len(),
            derives: c.derives.len(),
            resources: c.resources.len(),
            mutations: c.mutations.len(),
            actions: c.actions.len(),
            tasks: c.tasks.len(),
            sequences: c.sequences.len(),
        }
    }
}

/// A flat list of resource names used by a mutation's `refreshes` clause.
#[derive(Debug, Clone, PartialEq)]
pub struct RefreshGroup {
    /// Name used in a mutation's refresh list.
    pub name: String,
    /// Location of the declaration.
    pub span: Span,
    /// Resource names and their source locations, in declaration order.
    pub resources: Vec<(String, Span)>,
}

/// A component's members files and the names they share (D5).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Members {
    /// Refresh groups waiting for all the component's resources to be in scope.
    pub refresh_groups: Vec<RefreshGroup>,
    /// Its `members` lines, in order.
    pub lines: Vec<MembersLine>,
    /// For a members block, the component's props and injects.
    pub props: Vec<String>,
    /// Members of the component declared in its other files, each with
    /// whether it is an action. The loader fills this and `props` so that
    /// scoping binds every member, as the type checker will.
    pub outer: Vec<(String, bool)>,
}

/// A refusal the parser cannot decide in a file that is part of a component
/// across files: whether a method's name (`trim`) is an action, which another
/// of the component's files may declare (LLP 1116.015 D2, 1116.016 D2). The
/// loader decides it once the component is whole, as the parser would in the
/// one file the members are pasted into: against the actions of every
/// component of the file that lists the block, for a call in a block, or of
/// this file, for a call in a file that lists members files.
#[derive(Debug, Clone, PartialEq)]
pub struct Deferred {
    /// The method's name.
    pub name: String,
    /// Whether `error` is raised when the component has an action of the
    /// name (a method call it would capture), rather than when it has none
    /// (a free call that is no action's).
    pub if_action: bool,
    /// Whether the call is in a members block.
    pub in_block: bool,
    /// The refusal.
    pub error: SyntaxError,
}

/// The names `c` declares in its body, each with whether it is callable.
pub fn declared(c: &Component) -> impl Iterator<Item = (&str, bool, Span)> {
    fn plain(b: (&String, Span)) -> (&str, bool, Span) {
        (b.0, false, b.1)
    }
    let props = c.props.iter().chain(&c.injects);
    props
        .map(|p| (p.name.as_str(), true, p.span))
        .chain(c.states.iter().map(|b| plain((&b.name, b.span))))
        .chain(c.derives.iter().map(|b| plain((&b.name, b.span))))
        .chain(c.resources.iter().map(|r| plain((&r.name, r.span))))
        .chain(c.mutations.iter().map(|m| plain((&m.name, m.span))))
        .chain(c.actions.iter().map(|a| (a.name.as_str(), true, a.span)))
}

/// Insert `block`'s members into `host` where `at` says. Lines are spliced
/// last first, so each `at`, counted among the host's own members, holds.
pub fn splice(host: &mut Component, at: Splice, block: Component) {
    fn put<T>(into: &mut Vec<T>, at: usize, items: Vec<T>) {
        into.splice(at..at, items);
    }
    host.members
        .refresh_groups
        .extend(block.members.refresh_groups);
    put(&mut host.states, at.states, block.states);
    put(&mut host.persist, at.persist, block.persist);
    put(&mut host.derives, at.derives, block.derives);
    put(&mut host.resources, at.resources, block.resources);
    put(&mut host.mutations, at.mutations, block.mutations);
    put(&mut host.actions, at.actions, block.actions);
    put(&mut host.tasks, at.tasks, block.tasks);
    put(&mut host.sequences, at.sequences, block.sequences);
}

/// Resolve the groups once the component includes all its members files.
pub fn expand_refresh_groups(c: &mut Component) -> Result<(), SyntaxError> {
    use std::collections::{HashMap, HashSet};

    if c.members.refresh_groups.is_empty() {
        return Ok(());
    }
    let resources: HashSet<_> = c.resources.iter().map(|r| r.name.as_str()).collect();
    let mut groups = HashMap::new();
    for group in &c.members.refresh_groups {
        if resources.contains(group.name.as_str())
            || groups.insert(&group.name, &group.resources).is_some()
        {
            return Err(SyntaxError {
                id: "syntax-refresh-group-name",
                message: format!("refresh group `{}` needs a name distinct from this component's resources and refresh groups", group.name),
                span: group.span,
            });
        }
        let mut seen = HashSet::new();
        for (name, span) in &group.resources {
            if !resources.contains(name.as_str()) {
                return Err(SyntaxError {
                    id: "type-refreshes-not-resource",
                    message: format!(
                        "refresh group `{}` names `{name}`: expected a resource of this component",
                        group.name
                    ),
                    span: *span,
                });
            }
            if !seen.insert(name) {
                return Err(SyntaxError {
                    id: "type-refreshes-duplicate",
                    message: format!("refresh group `{}` names `{name}` twice", group.name),
                    span: *span,
                });
            }
        }
    }
    for mutation in &mut c.mutations {
        let mut expanded = Vec::new();
        for (name, span) in std::mem::take(&mut mutation.refreshes) {
            if let Some(resources) = groups.get(&name) {
                expanded.extend(resources.iter().map(|(name, _)| (name.clone(), span)));
            } else {
                expanded.push((name, span));
            }
        }
        mutation.refreshes = expanded;
    }
    c.members.refresh_groups.clear();
    Ok(())
}
