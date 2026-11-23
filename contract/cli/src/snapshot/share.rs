//! The share handler's plan (LLP 1133.024 D4, amended 2026-11-22): one empty
//! root, which a runner boots, and one source row, `share_target.handle`, as a
//! widget's `snapshot_refresh` is. The extension boots it headless and asks
//! that source once.
use exact_plan::{builder::PlanBuilder, Plan, TypeKind, SHARE_ENTRY};

/// The plan whose source takes the share's members, each a string or null as
/// the `action` route would receive it, and answers `{outcome, message}`. The
/// records are unnamed, so no shape of the app's can collide with them.
pub fn compile_share(app_id: &str, handle: &str) -> Result<Plan, String> {
    let root = crate::compile("component Share\n  view\n    column\n")
        .map_err(|e| format!("share handler plan: {e}"))?;
    let mut b = PlanBuilder::from_plan(root);
    let string = b.primitive(TypeKind::String);
    let member = b.option(string);
    let share = b.record("", &[("title", member), ("text", member), ("url", member)]);
    let outcome = b.string_enum(&["done".into(), "refused".into(), "open".into()]);
    let reply = b.record("", &[("outcome", outcome), ("message", member)]);
    let source = b.source(handle, &[share], reply);
    let mut plan = b
        .finish()
        .map_err(|e| format!("share handler plan: {e:?}"))?;
    plan.snapshot_refresh = Some(source);
    plan.snapshot_entry = SHARE_ENTRY.into();
    plan.app_id = app_id.into();
    // The extension's reader checks it with the same validating decoder.
    Plan::decode_snapshot(&plan.encode(), SHARE_ENTRY)
        .map_err(|e| format!("share handler plan: {e:?}"))
}
