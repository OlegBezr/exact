//! The share handler (LLP 1133.024 D4, amended 2026-11-22) as the iOS share
//! extension runs it: the share entry's plan booted headless by the Apple
//! bridge, the app's TypeScript admitted by its receipt, the share's members
//! from the input buffer, and a real `fetch` through the bridge's executor to
//! a server on 127.0.0.1. Each outcome, a throw, a store write and the bound.
#![cfg(all(exact_js_engine, target_os = "macos"))]
use exact_apple::abi::{Bridge, Hooks};
use exact_apple::link::{IoLinks, Links};
use exact_js::Module;
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::mpsc::{channel, Receiver};

const HBC: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/share.hbc"));
const APP: &str = "test.share-js";
const GRANTS: &str = "net.fetch local-network development\nsecret.keep session\n";

fn plan() -> Vec<u8> {
    contract::snapshot::compile_share(APP, "submitShared")
        .unwrap()
        .encode()
}

fn receipt() -> String {
    let plan = plan();
    serde_json::json!({"version":1,"abi":1,"bytecodeVersion":exact_js::BYTECODE_VERSION,
        "appId":APP,"grants":GRANTS,"module":{"file":"app.hbc","bytes":HBC.len(),
        "sha256":format!("{:x}",Sha256::digest(HBC))},
        "plans":{"share":{"file":"plans/share.plan","bytes":plan.len(),"sha256":format!("{:x}",Sha256::digest(&plan))}}})
    .to_string()
}

/// The session `secret.keep` holds, as the extension reads it from the shared Keychain group.
fn kept(_: Option<&ibex2::host::Bindings>, _: &str) -> Result<Vec<(String, Vec<u8>)>, String> {
    Ok(vec![("session".into(), b"kept".to_vec())])
}
/// The app's grants bound to stores in memory, as the extension binds them to the Keychain.
fn endow(grants: &str, _: &str, _: bool) -> exact_apple::store::Endowed {
    let grants = ibex2::grant::GrantSet::parse(&exact_runner::io_grants(grants)).unwrap();
    let bindings = ibex2::host::Host::new()
        .with_secret_store(Box::new(ibex2::secrets::MemoryStore::new()))
        .with_kv_store(Box::new(ibex2::kv::MemoryStore::new()))
        .endow(grants);
    exact_apple::store::Endowed {
        bindings: Some(bindings),
        ..exact_apple::store::Endowed::none()
    }
}

/// A server on 127.0.0.1: `/score` answers 200 with a line naming the body and the bearer it got, `/expired` 401,
/// and `/hang` never. Each request's first line and body are sent on `seen`.
fn server() -> (u16, Receiver<(String, String)>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, seen) = channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let tx = tx.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let (mut first, mut bearer, mut length) = (String::new(), String::new(), 0);
                reader.read_line(&mut first).unwrap();
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                    let lower = line.to_ascii_lowercase();
                    if let Some(v) = lower.strip_prefix("content-length:") {
                        length = v.trim().parse().unwrap_or(0);
                    }
                    if let Some(v) = line
                        .strip_prefix("authorization: ")
                        .or_else(|| line.strip_prefix("Authorization: "))
                    {
                        bearer = v.trim().to_owned();
                    }
                }
                let mut body = vec![0; length];
                reader.read_exact(&mut body).unwrap();
                let body = String::from_utf8(body).unwrap();
                let _ = tx.send((first.clone(), body.clone()));
                if first.contains(" /hang ") {
                    std::thread::sleep(std::time::Duration::from_secs(30));
                    return;
                }
                let reply = if first.contains(" /expired ") {
                    "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                        .to_owned()
                } else {
                    let line = format!("Ranked 2 of 4 ({body}, {bearer})");
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{line}",
                        line.len()
                    )
                };
                let _ = stream.write_all(reply.as_bytes());
            });
        }
    });
    (port, seen)
}

fn ask(bridge: &mut Bridge<Module>, text: &str, remaining_ms: f64) -> serde_json::Value {
    let share = serde_json::json!({"text": text}).to_string();
    bridge.input_write(share.as_bytes());
    let len = bridge.entry_timeline_module(0., remaining_ms, share.len(), receipt().as_bytes(), HBC)
        as usize;
    serde_json::from_slice(bridge.output_bytes(len)).unwrap()
}

/// One booted share entry per ask, as each share is its own extension run.
fn booted() -> Bridge<Module> {
    let plan = plan();
    let mut bridge = Bridge::with_links(Links {
        io: Some(IoLinks {
            endow,
            snapshot: kept,
            ..IoLinks::LINKED
        }),
        ..Links::ALL
    });
    bridge.input_write(&[plan.as_slice(), b"share"].concat());
    let len = bridge.boot_entry(
        plan.len(),
        5,
        0,
        0,
        Module::new(Vec::new(), APP, GRANTS),
        Hooks::none(),
        1.,
        1.,
    ) as usize;
    let boot: serde_json::Value = serde_json::from_slice(bridge.output_bytes(len)).unwrap();
    assert!(boot["error"].is_null(), "{boot}");
    bridge
}

#[test]
fn the_handler_submits_the_share_and_answers_each_outcome() {
    let (port, seen) = server();
    let done = ask(
        &mut booted(),
        &format!("Puzzle 0:39 http://127.0.0.1:{port}/score"),
        9_000.,
    );
    assert_eq!(
        done,
        serde_json::json!({"outcome": "done", "message": "Ranked 2 of 4 (Puzzle 0:39, Bearer kept)"})
    );
    let (first, body) = seen.recv().unwrap();
    assert!(first.starts_with("POST /score "), "{first}");
    assert_eq!(body, "Puzzle 0:39");
    assert_eq!(
        ask(&mut booted(), "hello", 9_000.),
        serde_json::json!({"outcome": "refused", "message": "That is not a puzzle result."})
    );
    assert_eq!(
        ask(
            &mut booted(),
            &format!("Puzzle http://127.0.0.1:{port}/expired"),
            9_000.
        ),
        serde_json::json!({"outcome": "open", "message": null})
    );
    // A throw and a store write end the run with an error, which the extension takes as `open`.
    assert!(ask(&mut booted(), "throw", 9_000.)["error"].is_string());
    let write = ask(&mut booted(), "write", 9_000.);
    assert!(
        write["error"]
            .as_str()
            .is_some_and(|e| e.contains("cannot write")),
        "{write}"
    );
}

#[test]
fn a_handler_past_its_bound_is_ended() {
    let (port, _seen) = server();
    let started = std::time::Instant::now();
    let hung = ask(
        &mut booted(),
        &format!("Puzzle http://127.0.0.1:{port}/hang"),
        1_500.,
    );
    assert!(hung["error"].is_string(), "{hung}");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "{:?}",
        started.elapsed()
    );
}
