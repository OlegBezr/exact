//! Drags from other apps into the reader's window (LLP 1094.001 D5): the
//! reader's root and its hosted fields hear Android's drag events and ask
//! here at the view's pixels, as a touch does.

use super::CanvasHost;
use crate::presenter::Dropped;
use exact_runner::DataSource;

impl<D: DataSource + Default> CanvasHost<D> {
    /// The drag is at pixels (`x`, `y`): its enters and leaves, and whether
    /// a node takes a drop there.
    pub fn drag_over(&mut self, x: f32, y: f32) -> bool {
        let held = self.p.modifiers();
        self.p
            .drag_over((x / self.scale, y / self.scale), held)
            .is_some()
    }

    /// The drag left the window, was cancelled, or a field took it.
    pub fn drag_left(&mut self) {
        self.p.drag_left();
    }

    /// The drag was released at pixels (`x`, `y`) before its items are
    /// copied: the drop's number, or 0 when nothing takes it there.
    pub fn drop_released(&mut self, x: f32, y: f32) -> u32 {
        let held = self.p.modifiers();
        self.p
            .drop_released((x / self.scale, y / self.scale), held)
            .unwrap_or(0)
    }

    /// Drop `id`'s items arrived, as the reader's JSON
    /// `{"paths": […], "text": "…", "url": "…"}`: whether its target took them.
    pub fn drop_landed(&mut self, id: u32, items: &str) -> bool {
        let dropped = parse(items);
        if dropped.is_none() {
            self.p
                .host_mut()
                .log(format!("drop: the reader's items were not JSON: {items}"));
        }
        self.p
            .drop_landed(id, &dropped.unwrap_or_default())
            .is_some()
    }

    /// Which node takes a drop over node `id`: 0 none, 1 the node itself,
    /// 2 one above it.
    pub fn drop_owner(&self, id: u32) -> i32 {
        self.p.drop_owner(id)
    }
}

/// The reader's items: absolute paths, text and a link.
fn parse(items: &str) -> Option<Dropped> {
    let value: serde_json::Value = serde_json::from_str(items).ok()?;
    let text = |key: &str| {
        value
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned()
    };
    let paths = value
        .get("paths")?
        .as_array()?
        .iter()
        .filter_map(|p| p.as_str().map(Into::into))
        .collect();
    Some(Dropped {
        paths,
        text: text("text"),
        url: text("url"),
    })
}
