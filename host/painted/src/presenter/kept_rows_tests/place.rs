//! A row's place in its set (`aria-posinset`, `aria-setsize`) and its kept
//! recording (`CommitReceipt::placed`).
use super::*;
use exact_kernel::{Op, PropValue, StyleId, StyleProps, StyleValue};

/// A windowed list of four rows, each kept, painted once.
fn list() -> (Presenter<()>, Rc<RefCell<Heard>>) {
    let (p, heard) = kept_phone_of(
        "component App\n  view\n    list virtualized=true estimated-item-height=50 width=200 height=400\n      for x in [0, 1, 2, 3] key=x\n        box height=50 width=200 visibility=\"visible\" pointer-events=\"auto\" testId=`r${x}`\n",
    );
    assert_eq!(heard.borrow().begun.len(), 4, "the rows are kept");
    (p, heard)
}

/// The wrapper the runner put round row `x`, which holds its place.
fn wrapper(p: &Presenter<()>, x: u32) -> ViewId {
    let k = p.host.kernel();
    let row = k.find_by_test_id(&format!("r{x}"))[0];
    k.node_by_key(row).unwrap().parent.unwrap()
}

fn size(id: ViewId) -> Op {
    Op::SetProp {
        id,
        prop: PropId::AccessibilitySetSize,
        value: PropValue::Int(9),
    }
}

fn style(id: ViewId, row: StyleId, value: &str) -> Op {
    let mut patch = StyleProps::default();
    patch
        .set_dynamic(row, &StyleValue::Text(value.into()))
        .unwrap();
    Op::SetStyle {
        id,
        patch: Box::new(patch),
    }
}

/// How many rows the next frame records after `ops`.
fn recorded(p: &mut Presenter<()>, heard: &Rc<RefCell<Heard>>, ops: &[Op]) -> usize {
    heard.borrow_mut().begun.clear();
    let receipt = p.host.runner_mut().kernel_mut().apply(0, 0, ops).unwrap();
    p.host.row_dirty.commit(&receipt, 0.0);
    let _ = p.frame();
    heard.borrow().begun.len()
}

/// A row given only a new place in its set (a row inserted above it) draws
/// as it did; another change to its wrapper records it again.
#[test]
fn a_rows_place_in_the_list_keeps_its_recording() {
    let (mut p, heard) = list();
    let w = wrapper(&p, 1);
    let place = Op::SetProp {
        id: w,
        prop: PropId::AccessibilityPosInSet,
        value: PropValue::Int(9),
    };
    assert_eq!(recorded(&mut p, &heard, &[place, size(w)]), 0);
    let label = Op::SetProp {
        id: w,
        prop: PropId::AccessibilityLabel,
        value: PropValue::Str("r".into()),
    };
    assert_eq!(recorded(&mut p, &heard, &[label]), 1);
}

/// A reorder or arrange spring moves a row's wrapper by its presentation,
/// with no commit: the row is recorded again, whatever its place did.
#[test]
fn a_placed_row_moved_by_its_presentation_is_recorded_again() {
    let (mut p, heard) = list();
    let w = wrapper(&p, 1);
    let key = p.host.kernel().node(w).unwrap().key;
    p.host.row_dirty.node(key);
    assert_eq!(recorded(&mut p, &heard, &[size(w)]), 1);
}

/// The row before one deleted loses the list's separator under it, and is
/// recorded again though only its place changed.
#[test]
fn a_placed_row_is_recorded_again_when_its_separator_goes() {
    let (mut p, heard) = list();
    let rows: Vec<_> = (0..4).map(|x| wrapper(&p, x)).collect();
    assert!(p.host.kernel().row_separator(rows[2]));
    let mut ops = vec![Op::DestroyView { id: rows[3] }];
    ops.extend(rows[..3].iter().map(|w| size(*w)));
    assert_eq!(recorded(&mut p, &heard, &ops), 1);
    assert!(!p.host.kernel().row_separator(rows[2]));
}

/// A grouped row's separator follows the next row shown: hiding that row
/// records the one before it again, though only its place changed.
#[test]
fn a_placed_row_is_recorded_again_when_its_grouped_separator_goes() {
    let (mut p, heard) = list();
    let rows: Vec<_> = (0..4).map(|x| wrapper(&p, x)).collect();
    let grouped: Vec<_> = (rows.iter())
        .map(|&id| Op::SetProp {
            id,
            prop: PropId::GroupedRowSeparator,
            value: PropValue::Bool(true),
        })
        .collect();
    assert_eq!(recorded(&mut p, &heard, &grouped), 4);
    assert!(p.host.kernel().grouped_separator(rows[2]).is_some());
    let key = p.host.kernel().node(rows[2]).unwrap().key;
    let kept = p.brush.retained_row_id(key);
    let ops = [style(rows[3], StyleId::Display, "none"), size(rows[2])];
    recorded(&mut p, &heard, &ops);
    assert!(p.host.kernel().grouped_separator(rows[2]).is_none());
    assert!(heard.borrow().begun.iter().any(|(_, was)| *was == kept));
}

/// A wrapper inherits `visibility` and `pointer-events` from its list, even
/// where the author's row inside it sets its own: a change to them records
/// every row again, though each row's place changed in the same commit.
#[test]
fn a_placed_row_is_recorded_again_when_what_it_inherits_changes() {
    for (row, value) in [
        (StyleId::Visibility, "hidden"),
        (StyleId::PointerEvents, "none"),
    ] {
        let (mut p, heard) = list();
        let w = wrapper(&p, 0);
        let list = p.host.kernel().node(w).unwrap().parent.unwrap();
        let mut ops = vec![style(list, row, value)];
        ops.extend((0..4).map(|x| size(wrapper(&p, x))));
        assert_eq!(recorded(&mut p, &heard, &ops), 4, "{row:?}");
    }
}
