//! The runner's refusals of process requests (LLP 1133.007 D12, D13): a
//! model's tool handler starts no program, and a kind the package does not
//! declare reaches no host, from any origin.
use super::*;
use crate::{Answer, DataError, FailureKind, Outcome, Request, Store};
use exact_kernel::{Kernel, NodeType};
use exact_plan::{builder::PlanBuilder, Plan, TypeKind};
use std::sync::{Arc, Mutex};

/// A source whose tool handler asks `execFile` and whose one resource
/// answers now.
struct Source(&'static str);

impl DataSource for Source {
    fn query(&mut self, _: &str, _: &[Value]) -> Result<Value, DataError> {
        unreachable!("the fixture implements answer")
    }

    fn answer(&mut self, _: &mut Store, source: &str, _: &[Value]) -> Result<Answer, DataError> {
        Ok(match source {
            "tool:probe" | crate::SCRIPT_MESSAGE => Answer::Later(Request::process(
                br#"{"kind":"execFile","program":"path:ssh"}"#.to_vec(),
                false,
                4096,
            )),
            _ => Answer::Now(Value::str("x")),
        })
    }

    fn parse(
        &mut self,
        _: &mut Store,
        _: &str,
        _: &[Value],
        o: Outcome,
    ) -> Result<Answer, DataError> {
        let text = match o {
            Outcome::Failed { message, .. } => message,
            _ => "ran".into(),
        };
        Ok(Answer::Now(Value::str(&text)))
    }

    fn grants(&self) -> &str {
        self.0
    }
}

fn runner(grants: &'static str) -> Runner<Source> {
    let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    let string = b.primitive(TypeKind::String);
    let r = b.resource("r", "r", &[], string, Some(&Value::str("")));
    b.set_resource_reader(r, true);
    b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    let mut plan: Plan = b.finish().unwrap();
    // A package's handlers are the module seam's: the plan names one.
    plan.add_view("probe", ("probe", "@fixture/probe"), false, &[], "{}");
    Runner::boot(
        plan,
        Source(grants),
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap()
}

#[test]
fn a_model_handler_starts_no_program() {
    let mut r = runner("process.spawn path:ssh");
    r.take_requests();
    let answered = Arc::new(Mutex::new(None));
    let to = answered.clone();
    let reply = Box::new(move |text: String| *to.lock().unwrap() = Some(text));
    r.run_handler(
        "probe".into(),
        "tool:probe".into(),
        "{}".to_owned(),
        crate::runner::provenance::Cause::model_tool(),
        To::Implementation(reply),
        None,
    );
    // Nothing goes to the host; the refusal settles the handler's request.
    assert!(r
        .take_requests()
        .iter()
        .all(|out| !out.request.is_process()));
    let (ticket, outcome) = r
        .take_request_refusal(true)
        .expect("the request is refused");
    match &outcome {
        Outcome::Failed { kind, message } => {
            assert_eq!(*kind, FailureKind::Refused);
            assert!(message.starts_with("person-required"), "{message}");
        }
        other => panic!("{other:?}"),
    }
    r.fulfill(ticket, outcome).unwrap();
    let text = answered
        .lock()
        .unwrap()
        .clone()
        .expect("the handler answered");
    assert!(text.contains("person-required"), "{text}");
}

#[test]
fn a_script_message_needs_the_receivers_grant_and_cannot_start_a_process() {
    let message = serde_json::json!({
        "extension": "browser-automation", "handle": "script.message", "handler": "script.message",
        "args": {"params": {"channel": "playback", "json": "\"pause\"", "source": {"realm": "old", "origin": "null", "context": "video"}}}
    }).to_string();
    for (grants, reason) in [
        ("process.spawn path:ssh", "NotAllowedError"),
        (
            "process.spawn path:ssh\nbrowser.automation",
            "person-required",
        ),
    ] {
        let mut r = runner(grants);
        r.take_requests();
        let heard = Arc::new(Mutex::new(None));
        let to = heard.clone();
        r.invoke_module(
            &message,
            Box::new(move |answer| *to.lock().unwrap() = Some(answer)),
        );
        assert!(r
            .take_requests()
            .iter()
            .all(|out| !out.request.is_process()));
        if let Some((ticket, refused)) = r.take_request_refusal(true) {
            r.fulfill(ticket, refused).unwrap();
        }
        let answer = heard.lock().unwrap().take().expect("the handler answered");
        assert!(answer.contains(reason), "{answer}");
    }
}

#[test]
fn a_channel_overflow_journals_without_starting_a_guest_handler() {
    let mut r = runner("browser.automation");
    let message = serde_json::json!({
        "extension": "browser-automation", "handle": "script.message", "handler": "script.message",
        "args": {"overflow": true}
    });
    r.invoke_module(
        &message.to_string(),
        Box::new(|reply| assert_eq!(reply, "{}")),
    );
    assert!(r.take_request_refusal(true).is_none());
    assert_eq!(
        r.journal()
            .filter(|line| line.contains("dropped oldest unsent"))
            .count(),
        1
    );
}

#[test]
fn an_undeclared_kind_is_refused_from_the_apps_origin() {
    let mut r = runner("process.spawn path:ssh");
    for kind in ["processStatus", "child.write", "shell"] {
        let body = format!(r#"{{"kind":"{kind}","program":"path:ssh"}}"#);
        let mut request = Request::process(body.into_bytes(), false, 4096);
        request.reach.origin = crate::CallOrigin::App;
        let why = r.process_refusal(&request).expect(kind);
        assert!(why.contains("does not declare"), "{kind}: {why}");
    }
}
