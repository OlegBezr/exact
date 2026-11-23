//! LLP 1133.023 D7a: what the host observes of the page is the device's,
//! a drag handle's release is the person's, and a world's message under a
//! tool's mark keeps D4a's command rules.

use crate::request::Request;
use crate::{Answer, CallOrigin, DataError, DataSource, Event, Outcome, Runner, Store, Value};
use exact_kernel::Kernel;

/// Every send answers later.
struct Later;

impl DataSource for Later {
    fn query(&mut self, _: &str, _: &[Value]) -> Result<Value, DataError> {
        unreachable!("answers through answer")
    }

    fn answer(&mut self, _: &mut Store, _: &str, _: &[Value]) -> Result<Answer, DataError> {
        Ok(Answer::Later(Request::native(b"{}".to_vec())))
    }

    fn parse(
        &mut self,
        _: &mut Store,
        _: &str,
        _: &[Value],
        _: Outcome,
    ) -> Result<Answer, DataError> {
        Ok(Answer::Now(Value::Number(0.0)))
    }
}

const FRAME: &str = "component App\n  mutation m as shape number\n  tool ping writes \"Ping.\" = loaded\n  action loaded\n    send m = save(1)\n  action heard(text: string)\n    focus(\"x\")\n  view\n    iframe \"/deck/index.html\" load=loaded message=heard testId=\"deck\"\n";

fn boot() -> (Runner<Later>, exact_kernel::ViewId) {
    boot_with(FRAME, "deck")
}

fn boot_with(source: &str, test_id: &str) -> (Runner<Later>, exact_kernel::ViewId) {
    let plan = contract::compile(source).unwrap();
    let r = Runner::boot(
        plan,
        Later,
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    let key = r.kernel().find_by_test_id(test_id)[0];
    let id = r.kernel().node_by_key(key).unwrap().id;
    (r, id)
}

#[test]
fn a_load_the_host_observes_is_the_devices() {
    let (mut r, frame) = boot();
    r.take_requests();
    r.dispatch(frame, Event::Load).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent[0].request.reach.origin, CallOrigin::Device);
}

/// A sheet's or a photo's drag handle reports the geometry it reads, which
/// is the device's, and the release of the person's drag, which is theirs.
#[test]
fn a_drag_handles_release_is_the_persons() {
    const HANDLES: &str = "component App\n  mutation m as shape number\n  action geometry(bw: number, bh: number, pw: number, ph: number)\n    send m = save(1)\n  action release(x: number, y: number, scale: number, vx: number, vy: number, vs: number)\n    send m = save(2)\n  action snap(height: number, velocity: number)\n    send m = save(3)\n  view\n    column\n      column id=\"sheet\" height=360 box-sizing=\"border-box\"\n        column testId=\"sheet-handle\" heightDragFor=\"sheet\" heightrelease=snap\n      column overflow=\"hidden\"\n        column id=\"photo\" width=\"100%\" height=\"100%\" box-sizing=\"border-box\"\n          column testId=\"photo-handle\" transformDragFor=\"photo\" transformgeometry=geometry transformrelease=release\n";
    let origin = |id: &str, event: Event| {
        let (mut r, handle) = boot_with(HANDLES, id);
        r.take_requests();
        r.dispatch(handle, event).unwrap();
        r.take_requests()[0].request.reach.origin
    };
    let snap = Event::HeightRelease {
        height: 180.0,
        velocity: 0.0,
    };
    assert_eq!(origin("sheet-handle", snap), CallOrigin::App);
    let release = Event::TransformRelease {
        x: 0.,
        y: 0.,
        scale: 1.,
        vx: 0.,
        vy: 0.,
        vscale: 0.,
    };
    assert_eq!(origin("photo-handle", release), CallOrigin::App);
    let geometry = Event::TransformGeometry {
        box_width: 100.,
        box_height: 100.,
        port_width: 100.,
        port_height: 100.,
    };
    assert_eq!(origin("photo-handle", geometry), CallOrigin::Device);
}

#[test]
fn a_worlds_message_under_a_tools_mark_keeps_the_calls_command_rules() {
    let (mut r, frame) = boot();
    r.dispatch(frame, Event::Message("\u{1}origin:tool\u{1}hi".into()))
        .unwrap();
    let lines: Vec<String> = r.journal().map(str::to_owned).collect();
    assert!(
        lines
            .iter()
            .any(|l| l.contains("focus: skipped in a tool call")),
        "{lines:?}"
    );
    // The app's own message runs it.
    r.dispatch(frame, Event::Message("hi".into())).unwrap();
    let skipped = r.journal().filter(|l| l.contains("focus: skipped")).count();
    assert_eq!(skipped, 1);
}

/// A source that is not ready until the test says: `prep` answers at
/// once, every other send later.
struct Unready(bool);

impl DataSource for Unready {
    fn query(&mut self, _: &str, _: &[Value]) -> Result<Value, DataError> {
        unreachable!("answers through answer")
    }

    fn answer(&mut self, _: &mut Store, source: &str, _: &[Value]) -> Result<Answer, DataError> {
        Ok(match source {
            "prep" => Answer::Now(Value::Number(1.0)),
            _ => Answer::Later(Request::native(b"{}".to_vec())),
        })
    }

    fn parse(
        &mut self,
        _: &mut Store,
        _: &str,
        _: &[Value],
        _: Outcome,
    ) -> Result<Answer, DataError> {
        Ok(Answer::Now(Value::Number(0.0)))
    }

    fn ready(&self) -> bool {
        self.0
    }
}

/// A send made before the data source was ready answers at `data_ready`.
/// What its answer opens, a root task and a component's mounted task, is
/// the sender's work, as it would be had the source been ready: the
/// person's. With a device's send waiting too, it is no one's.
#[test]
fn what_a_deferred_sends_answer_opens_keeps_the_senders_cause() {
    const DEFERRED: &str = "component App\n  mutation prepared as shape number\n  mutation seen as shape number\n  mutation m as shape number\n  derive ready = match prepared { case some(p) => p == 1, case none => false }\n  action start\n    send prepared = prep(1)\n  action loaded\n    send seen = prep(2)\n  action fire\n    send m = save(1)\n  task armed when ready\n    after(1, fire)\n  view\n    column\n      button press=start testId=\"start\"\n        text \"Start\"\n      iframe \"/deck/index.html\" load=loaded testId=\"deck\"\n      if ready\n        Child()\ncomponent Child\n  mutation c as shape number\n  action go\n    send c = save(2)\n  task beat mount\n    after(1, go)\n  view\n    text \"child\"\n";
    for device_waits in [false, true] {
        let plan = contract::compile(DEFERRED).unwrap();
        let mut r = Runner::boot(
            plan,
            Unready(false),
            Kernel::with_monospace(),
            Default::default(),
            "/",
        )
        .unwrap();
        let node = |r: &Runner<Unready>, id: &str| {
            let key = r.kernel().find_by_test_id(id)[0];
            r.kernel().node_by_key(key).unwrap().id
        };
        if device_waits {
            let deck = node(&r, "deck");
            r.dispatch(deck, Event::Load).unwrap();
        }
        let start = node(&r, "start");
        r.dispatch(start, Event::Press).unwrap();
        r.data().0 = true;
        r.data_ready().unwrap();
        let at = r.now_ms() + 1.0;
        r.advance(at).unwrap();
        let sent = r.take_requests();
        assert_eq!(sent.len(), 2, "{:?}", r.journal().collect::<Vec<_>>());
        let expected = match device_waits {
            false => CallOrigin::App,
            true => CallOrigin::Device,
        };
        for s in sent {
            assert_eq!(
                s.request.reach.origin, expected,
                "device waits {device_waits}"
            );
        }
    }
}

/// A resource the boot asked before the data source was ready answers at
/// `data_ready`, with no send waiting: a task its answer opens is the boot's,
/// the app's.
#[test]
fn a_task_a_boot_asks_answer_opens_is_the_apps() {
    const ASKED: &str = "component App\n  resource level = prep(1) as shape number\n  mutation m as shape number\n  action fire\n    send m = save(1)\n  task armed when level == 1\n    after(1, fire)\n  view\n    text \"level\"\n";
    let plan = contract::compile(ASKED).unwrap();
    let mut r = Runner::boot(
        plan,
        Unready(false),
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    r.data().0 = true;
    r.data_ready().unwrap();
    let at = r.now_ms() + 1.0;
    r.advance(at).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent.len(), 1, "{:?}", r.journal().collect::<Vec<_>>());
    assert_eq!(sent[0].request.reach.origin, CallOrigin::App);
}
