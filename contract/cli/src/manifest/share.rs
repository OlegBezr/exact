//! `share_target.handle` (LLP 1133.024 D4, amended 2026-11-22): the data
//! source a share extension runs on a share before it goes to the inbox.
use super::Manifest;
use exact_plan::{entry_identifier, SHARE_ENTRY};
use serde_json::Value;

impl Manifest {
    /// The source `share_target.handle` names, or none. The handler answers in
    /// Apple's confirmation, so `"presentation": "compose"` beside it is refused,
    /// and its plan's kind, `share`, is no widget's or activity's.
    pub fn share_handle(&self) -> Result<Option<String>, String> {
        let Some(target) = self.json.get("share_target").filter(|t| !t.is_null()) else {
            return Ok(None);
        };
        let Some(handle) = target.get("handle") else {
            return Ok(None);
        };
        let handle = handle
            .as_str()
            .filter(|v| entry_identifier(v) && !v.contains('-'))
            .ok_or(
                "share_target.handle must name a data source, an identifier such as `submitShared`",
            )?;
        if target
            .pointer("/apple/presentation")
            .and_then(Value::as_str)
            == Some("compose")
        {
            return Err("share_target.handle answers in Apple's confirmation, which shows its line under the checkmark; remove `\"presentation\": \"compose\"` (the confirmation is the default with a handler)".into());
        }
        let taken = self
            .widgets()?
            .iter()
            .map(|w| w.kind.clone())
            .chain(self.live_activities()?.iter().map(|a| a.kind.clone()))
            .any(|kind| kind.eq_ignore_ascii_case(SHARE_ENTRY));
        if taken {
            return Err(format!("a widget or activity has the kind `{SHARE_ENTRY}`, which names the share handler's plan; rename it"));
        }
        Ok(Some(handle.to_owned()))
    }
}
