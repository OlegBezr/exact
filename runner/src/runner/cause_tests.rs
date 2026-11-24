//! LLP 1133.023 D7a: what the host observes of a page takes the cause of
//! whoever showed it, a drag handle's release is the app's, and a world's
//! message under a tool's mark and a remote Play keep D4a's command rules.

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

/// A camera preview's `load` may start the camera.
#[test]
fn a_load_the_host_observes_is_the_apps() {
    let (mut r, frame) = boot();
    r.take_requests();
    r.dispatch(frame, Event::Load).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent[0].request.reach.origin, CallOrigin::App);
}

/// A sheet's or a photo's drag handle reports the geometry it reads and the
/// release of the person's drag.
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
    assert_eq!(origin("photo-handle", geometry), CallOrigin::App);
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

/// expo/exact#1424: a `keepRunning` window the person shows again by
/// launching the app reaches the app only as its page becoming visible, and
/// what that starts is the person's, as at a cold launch.
#[test]
fn a_page_shown_again_starts_work_as_the_apps() {
    const SHOWN: &str = "shape Page\n  visibilityState: string\n  persisted: bool\n\ncomponent App\n  resource page = exactPage() as shape Page\n  mutation frozen as shape number\n  task arrive when page.visibilityState == \"visible\" and not page.persisted\n    after(1, begin)\n  action begin\n    send frozen = save(1)\n  view\n    text \"x\" testId=\"x\"\n";
    let (mut r, _) = boot_with(SHOWN, "x");
    r.advance(1.0).unwrap();
    assert_eq!(r.take_requests().len(), 1, "the cold launch's capture");
    let away = crate::Page {
        hidden: true,
        persisted: true,
        ..r.page()
    };
    r.set_page(away).unwrap();
    let shown = crate::Page {
        hidden: false,
        persisted: false,
        restores: 1,
        ..r.page()
    };
    // The host says the person's later launch is what shows it.
    r.person_shows_page();
    r.set_page(shown).unwrap();
    r.advance(10.0).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent.len(), 1, "the warm launch's capture");
    assert_eq!(sent[0].request.reach.origin, CallOrigin::App);
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

fn boot_unready(source: &str) -> Runner<Unready> {
    let plan = contract::compile(source).unwrap();
    Runner::boot(
        plan,
        Unready(false),
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap()
}

/// What `data_ready`'s answers open (a root task, a component's mounted
/// task) is the work of the sends that waited for it: a person's press is
/// the app's, as it would be had the source been ready; joined by a send
/// the device made, it is the device's.
#[test]
fn what_a_waiting_sends_answer_opens_is_the_join_of_the_waiting_causes() {
    const DEFERRED: &str = "component App\n  mutation prepared as shape number\n  mutation seen as shape number\n  mutation m as shape number\n  derive ready = match prepared { case some(p) => p == 1, case none => false }\n  action start\n    send prepared = prep(1)\n  action observed\n    send seen = prep(2)\n  action fire\n    send m = save(1)\n  task armed when ready\n    after(1, fire)\n  view\n    column\n      button press=start testId=\"start\"\n        text \"Start\"\n      if ready\n        Child()\ncomponent Child\n  mutation c as shape number\n  action go\n    send c = save(2)\n  task beat mount\n    after(1, go)\n  view\n    text \"child\"\n";
    for (device_waits, expected) in [(false, CallOrigin::App), (true, CallOrigin::Device)] {
        let mut r = boot_unready(DEFERRED);
        if device_waits {
            r.act_from(CallOrigin::Device, "observed", vec![]).unwrap();
        }
        let key = r.kernel().find_by_test_id("start")[0];
        let start = r.kernel().node_by_key(key).unwrap().id;
        r.dispatch(start, Event::Press).unwrap();
        r.data().0 = true;
        r.data_ready().unwrap();
        let at = r.now_ms() + 1.0;
        r.advance(at).unwrap();
        let sent = r.take_requests();
        assert_eq!(sent.len(), 2, "{:?}", r.journal().collect::<Vec<_>>());
        for s in sent {
            assert_eq!(
                s.request.reach.origin, expected,
                "device waits {device_waits}"
            );
        }
    }
}

/// A resource the boot asked before the data source was ready answers at
/// `data_ready`: a task its answer opens is the boot's, the app's.
#[test]
fn a_task_a_boot_asks_answer_opens_is_the_apps() {
    const ASKED: &str = "component App\n  resource level = prep(1) as shape number\n  mutation m as shape number\n  action fire\n    send m = save(1)\n  task armed when level == 1\n    after(1, fire)\n  view\n    text \"level\"\n";
    let mut r = boot_unready(ASKED);
    r.data().0 = true;
    r.data_ready().unwrap();
    let at = r.now_ms() + 1.0;
    r.advance(at).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent.len(), 1, "{:?}", r.journal().collect::<Vec<_>>());
    assert_eq!(sent[0].request.reach.origin, CallOrigin::App);
}

/// A page the host hides (a wake's headless boot, a closed window) is not the
/// person's act, and a load it renders hidden is not either.
#[test]
fn what_a_hidden_page_arms_or_loads_is_no_ones() {
    const AWAY: &str = "shape Page\n  visibilityState: string\n\ncomponent App\n  resource page = exactPage() as shape Page\n  mutation m as shape number\n  task away when page.visibilityState == \"hidden\"\n    after(1, gone)\n  action gone\n    send m = save(1)\n  action loaded\n    send m = save(2)\n  view\n    iframe \"/deck/index.html\" load=loaded testId=\"deck\"\n";
    let (mut r, deck) = boot_with(AWAY, "deck");
    r.take_requests();
    let hidden = crate::Page {
        hidden: true,
        ..r.page()
    };
    r.set_page(hidden).unwrap();
    r.advance(1.0).unwrap();
    r.dispatch(deck, Event::Load).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent.len(), 2);
    for s in sent {
        assert_eq!(s.request.reach.origin, CallOrigin::Device);
    }
}

/// A remote Play is the person's act on one declared control outside the
/// app's UI: an `action`, as a control's press is, whose command rules
/// hold. The element's own `play` while the page shows stays the app's.
#[test]
fn a_remote_play_is_an_action() {
    const PLAYER: &str = "component App\n  mutation m as shape number\n  action started\n    send m = save(1)\n    focus(\"v\")\n  view\n    audio \"https://example.com/a.mp3\" play=started testId=\"v\"\n";
    let (mut r, audio) = boot_with(PLAYER, "v");
    r.take_requests();
    let play = |how: &str| Event::Media(exact_plan::EventKind::Play, how.into());
    r.dispatch(audio, play("remote")).unwrap();
    let sent = r.take_requests();
    assert_eq!(sent[0].request.reach.origin, CallOrigin::Action);
    let skipped = |r: &Runner<Later>| r.journal().filter(|l| l.contains("focus: skipped")).count();
    assert_eq!(skipped(&r), 1, "{:?}", r.journal().collect::<Vec<_>>());
    r.dispatch(audio, play("")).unwrap();
    assert_eq!(r.take_requests()[0].request.reach.origin, CallOrigin::App);
    assert_eq!(skipped(&r), 1);
}

const SHOWN: &str = "shape Page\n  visibilityState: string\n  persisted: bool\n\ncomponent App\n  resource page = exactPage() as shape Page\n  mutation m as shape number\n  task arrive when page.visibilityState == \"visible\" and not page.persisted\n    after(1, begin)\n  action begin\n    send m = save(1)\n  action bring\n    focus()\n  action loaded\n    send m = save(2)\n  view\n    iframe \"/deck/index.html\" load=loaded testId=\"deck\"\n";

/// Hide the page, let `show` say who shows it again, show it, and return
/// the origins of what the showing and a frame's load asked.
fn shown_again(show: impl FnOnce(&mut Runner<Later>)) -> Vec<CallOrigin> {
    let (mut r, deck) = boot_with(SHOWN, "deck");
    r.advance(1.0).unwrap();
    r.take_requests();
    let page = r.page();
    let away = crate::Page {
        hidden: true,
        persisted: true,
        ..page
    };
    r.set_page(away).unwrap();
    show(&mut r);
    let back = crate::Page {
        restores: 1,
        ..page
    };
    r.set_page(back).unwrap();
    r.advance(10.0).unwrap();
    r.dispatch(deck, Event::Load).unwrap();
    let sent = r.take_requests();
    sent.iter().map(|s| s.request.reach.origin).collect()
}

/// The page's cause is set only by the host's word: a showing it cannot
/// explain is no one's, a window a device's `focus()` brought forward is the
/// device's, and a background action, which may not bring it forward, does
/// not make it the app's.
#[test]
fn a_page_shown_without_the_persons_act_is_not_the_apps() {
    use CallOrigin::{App, Device};
    assert_eq!(shown_again(|_| {}), [Device, Device], "unexplained");
    let device = shown_again(|r| {
        r.act_from(Device, "bring", vec![]).unwrap();
    });
    assert_eq!(device, [Device, Device], "a device's focus()");
    let action = shown_again(|r| {
        r.act_from(CallOrigin::Action, "bring", vec![]).unwrap();
        let refused = r.journal().any(|l| l.contains("focus: refused"));
        assert!(refused, "{:?}", r.journal().collect::<Vec<_>>());
    });
    assert_eq!(action, [Device, Device], "a background action's focus()");
    let app = shown_again(|r| {
        r.act_from(App, "bring", vec![]).unwrap();
    });
    assert_eq!(app, [App, App], "the app's own focus()");
    assert_eq!(shown_again(Runner::person_shows_page), [App, App]);
}

/// The person's input in a window something else showed makes the page
/// theirs; the device's `focus()` while it shows makes it the device's.
#[test]
fn the_persons_input_and_a_later_request_retake_the_page() {
    let (mut r, deck) = boot_with(SHOWN, "deck");
    r.take_requests();
    let origin = |r: &mut Runner<Later>| {
        r.dispatch(deck, Event::Load).unwrap();
        r.take_requests()[0].request.reach.origin
    };
    assert_eq!(origin(&mut r), CallOrigin::App, "the launch's");
    r.act_from(CallOrigin::Device, "bring", vec![]).unwrap();
    r.take_requests();
    assert_eq!(origin(&mut r), CallOrigin::Device);
    // A press the frame has no handler for still says the person is there.
    let _ = r.dispatch(deck, Event::Press);
    assert_eq!(origin(&mut r), CallOrigin::App);
}

/// A launch made to run a call boots under the call's cause, as does the
/// page it shows: what the boot asks and observes is not the app's.
#[test]
fn a_calls_cold_launch_boots_as_the_call() {
    for (by, expected) in [
        (crate::LaunchedBy::Call { press: false }, CallOrigin::Tool),
        (crate::LaunchedBy::Call { press: true }, CallOrigin::Action),
        (crate::LaunchedBy::Person, CallOrigin::App),
    ] {
        let launch = crate::time::Launch {
            by,
            ..crate::time::Launch::NONE
        };
        let (mut r, deck) = crate::time::launching_with(launch, || boot_with(SHOWN, "deck"));
        r.advance(1.0).unwrap();
        r.dispatch(deck, Event::Load).unwrap();
        let sent = r.take_requests();
        assert_eq!(sent.len(), 2, "{by:?}");
        for s in sent {
            assert_eq!(s.request.reach.origin, expected, "{by:?}");
        }
    }
}
