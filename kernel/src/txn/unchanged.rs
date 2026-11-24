use super::CommitReceipt;

impl CommitReceipt {
    /// Whether the batch changed no node: a host has nothing to lay out or
    /// present for it.
    pub fn unchanged(&self) -> bool {
        !self.layout_invalidated
            && self.created.is_empty()
            && self.destroyed.is_empty()
            && self.touched.is_empty()
            && self.exits.is_empty()
            && self.handoffs.is_empty()
            && self.display_changed.is_empty()
            && self.timelines.is_empty()
            && self.renewed.is_empty()
            && self.revealed.is_empty()
    }
}
