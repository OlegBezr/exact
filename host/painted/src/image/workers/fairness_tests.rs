//! Deterministic turns of the real worker loop, without process-pool competitors.
use super::*;
use crate::image::{control_tests, Images};
use exact_raster::{DecodeCost, Metadata, PixelSize, RequestStatus};
use exact_raster::{Demand, Priority, RasterKey, ViewKey};
use std::sync::atomic::{AtomicUsize, Ordering};

type Events = Arc<Mutex<Vec<&'static str>>>;

fn workers() -> Workers {
    Workers {
        gate: Gate::new(),
        backends: Mutex::new(Vec::new()),
        cursor: Mutex::new(0),
    }
}
fn pixels() -> Arc<[u8]> {
    let mut pixmap = tiny_skia::Pixmap::new(3, 3).unwrap();
    pixmap.fill(tiny_skia::Color::WHITE);
    pixmap.encode_png().unwrap().into()
}

const MIB: u64 = 1024 * 1024;

fn square_images(workers: &Workers) -> Images {
    let bytes = control_tests::encoded(1024, 1024, [71, 80, 90, 255]);
    let assets = Assets::selected(
        Default::default(),
        Arc::new(move |_| Ok(Some(bytes.clone()))),
    );
    Images::make(assets, Backend::with_downloads(workers, None))
}

fn prepare(images: &mut Images, k: &exact_kernel::Kernel, visible: &[u32]) {
    images.sync(k, visible);
    while images.backend.prepare() {}
    images.poll();
}

fn settle(workers: &Workers, images: &mut Images) {
    while let Some(permit) = workers.gate.next_decode() {
        workers.complete(permit);
        images.poll();
    }
    assert!(!images.pending());
}

fn pixel(view: u64, source: u64) -> Demand {
    let pixels = PixelSize {
        width: 1,
        height: 1,
    };
    Demand {
        view: ViewKey {
            view,
            generation: 0,
        },
        key: RasterKey {
            source,
            generation: 0,
            pixels,
            variant: 1,
            crop: Default::default(),
        },
        metadata: Metadata {
            natural: pixels,
            encoded_bytes: 4,
            header_bytes: 4,
        },
        cost: DecodeCost::checked(4, 1, 0, 0).unwrap(),
        priority: Priority::Visible,
    }
}

#[test]
fn distinct_upgrades_do_not_spend_cold_headroom_again_in_the_next_poll() {
    let workers = workers();
    let mut images = square_images(&workers);
    let k = control_tests::kernel(3);
    prepare(&mut images, &k, &[1]);
    settle(&workers, &mut images);
    let session = images.backend.session.clone();
    let _pressure = session.reserve_allocation(24 * MIB).unwrap();
    for visible in [&[1, 2][..], &[1, 2, 3]] {
        prepare(&mut images, &k, visible);
        assert!(workers.gate.next_decode().is_none());
        images.poll();
        settle(&workers, &mut images);
    }
    assert_eq!(images.bitmaps[&2].width(), 512);
    assert_eq!(images.bitmaps[&3].width(), 512);
    let second = images.views[&3].request;
    assert_eq!(session.available_bytes(), 2 * MIB);

    let blocker = workers.gate.session();
    blocker.request(pixel(1, 1)).unwrap();
    blocker.request(pixel(2, 2)).unwrap();
    let held = [
        workers.gate.next_decode().unwrap(),
        workers.gate.next_decode().unwrap(),
    ];
    images.sync(&k, &[2, 3]);
    let upgrade = images.views[&2].request.unwrap();
    assert_eq!(upgrade.1.width, 1024);
    assert_eq!(session.status(upgrade.0), Some(RequestStatus::Queued));
    assert_eq!(images.views[&3].request, second);
    images.poll();
    assert_eq!(
        images.views[&3].request, second,
        "both worker slots are still held"
    );

    drop(held);
    settle(&workers, &mut images);
    assert_eq!(images.bitmaps[&2].width(), 1024);
    assert_eq!(images.bitmaps[&3].width(), 512);
    assert_eq!(images.views[&3].request, second);
    assert!(images.stats().evicted > 0);
}

#[test]
fn a_first_load_gets_a_budget_wake_while_an_upgrade_waits() {
    let workers = workers();
    let mut images = square_images(&workers);
    let k = control_tests::kernel(3);
    prepare(&mut images, &k, &[1]);
    settle(&workers, &mut images);
    let session = images.backend.session.clone();
    let held = images.bitmaps[&1].clone();
    let _pressure = session.reserve_allocation(24 * MIB + MIB / 2).unwrap();
    prepare(&mut images, &k, &[1, 2]);
    assert!(workers.gate.next_decode().is_none());
    images.poll();
    settle(&workers, &mut images);
    let thumbnail = images.bitmaps[&2].clone();

    images.sync(&k, &[2]);
    let upgrade = images.views[&2].request.unwrap().0;
    assert!(workers.gate.next_decode().is_none());
    assert_eq!(session.status(upgrade), Some(RequestStatus::WaitingBudget));
    images.backend.notify_budget_wait();
    prepare(&mut images, &k, &[2, 3]);
    let first = images.views[&3].request.unwrap().0;
    let seen = images.revision();
    assert!(workers.gate.next_decode().is_none());
    assert_eq!(session.status(first), Some(RequestStatus::WaitingBudget));
    assert_eq!(session.status(upgrade), Some(RequestStatus::WaitingBudget));
    images.backend.notify_budget_wait();
    assert!(
        images.revision() > seen,
        "the host must be woken before polling"
    );

    images.poll();
    let permit = workers.gate.next_decode().unwrap();
    workers.complete(permit);
    images.poll();
    assert_eq!(images.bitmaps[&3].width(), 512);
    assert!(Arc::ptr_eq(&images.bitmaps[&2], &thumbnail));
    drop(held);
    settle(&workers, &mut images);
}

#[test]
fn an_upgrade_leaves_the_last_subscription_for_a_first_load() {
    let workers = workers();
    let mut images = square_images(&workers);
    let k = control_tests::kernel(2);
    let session = images.backend.session.clone();
    let pressure = session.reserve_allocation(29 * MIB).unwrap();
    prepare(&mut images, &k, &[1]);
    assert!(workers.gate.next_decode().is_none());
    images.poll();
    settle(&workers, &mut images);
    let thumbnail = images.views[&1].request;
    assert_eq!(images.bitmaps[&1].width(), 512);

    let filler = session.request(pixel(1, 1)).unwrap();
    workers
        .gate
        .next_decode()
        .unwrap()
        .complete((), ResidentBytes { output: 4, copy: 0 })
        .unwrap();
    assert!(session.take_ready(filler).is_some());
    for view in 2..(SUBSCRIPTIONS - 1) as u64 {
        session.request_cached(pixel(view, 1)).unwrap();
    }
    assert_eq!(session.stats().subscribers, SUBSCRIPTIONS - 1);
    drop(pressure);
    images.poll();
    prepare(&mut images, &k, &[1, 2]);
    assert_eq!(images.views[&2].refusal, None);
    assert_eq!(images.views[&1].request, thumbnail);
    settle(&workers, &mut images);
    assert_eq!(images.bitmaps[&2].width(), 1024);
}
struct Known {
    backend: Arc<Backend>,
    _assets: Arc<Assets>,
    _sources: Vec<Arc<SourceOwner>>,
    demands: Vec<Demand>,
}
impl Known {
    fn new(workers: &Workers, events: &Events, decoded: &Arc<AtomicUsize>) -> Self {
        let backend = Backend::for_workers(workers);
        let generation = backend.generation();
        let bytes = pixels();
        let assets = Arc::new(Assets::selected(
            Default::default(),
            Arc::new(move |_| Ok(Some(bytes.clone()))),
        ));
        let mut sources = Vec::new();
        let mut demands = Vec::new();
        for id in 1..=2 {
            let source = backend
                .source(generation, &id.to_string(), &assets, false)
                .unwrap();
            assert!(backend.prepare());
            let Prepared::Ready(header) = backend.prepared(source.id).unwrap() else {
                panic!("fixture header")
            };
            let plan = png_decode::DecodePlan::new(header, (3, 3)).unwrap();
            demands.push(Demand {
                key: RasterKey {
                    source: source.id,
                    generation,
                    pixels: plan.pixels,
                    variant: 1,
                    crop: exact_raster::Crop::default(),
                },
                view: ViewKey {
                    view: id,
                    generation,
                },
                metadata: header.metadata,
                cost: plan.cost,
                priority: Priority::Visible,
            });
            sources.push(source);
        }
        let events = events.clone();
        let decoded = decoded.clone();
        *backend.hook.lock().unwrap() = Some(Arc::new(move |_, _| {
            decoded.fetch_add(1, Ordering::SeqCst);
            events.lock().unwrap().push("decode");
        }));
        Self {
            backend,
            _assets: assets,
            _sources: sources,
            demands,
        }
    }
    fn enqueue(&self) {
        for demand in &self.demands {
            self.backend.request(*demand, false).unwrap();
        }
    }
}
fn metadata(workers: &Workers, events: &Events, name: &'static str) -> (Arc<Backend>, Arc<Assets>) {
    let backend = Backend::for_workers(workers);
    let events = events.clone();
    let bytes = pixels();
    let assets = Arc::new(Assets::selected(
        Default::default(),
        Arc::new(move |_| {
            events.lock().unwrap().push(name);
            Ok(Some(bytes.clone()))
        }),
    ));
    (backend, assets)
}

#[test]
fn metadata_arriving_after_the_scan_is_not_lost_before_an_unbounded_wait() {
    let workers = workers();
    let events = Events::default();
    let (backend, assets) = metadata(&workers, &events, "metadata");
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| {
            let mut source = None;
            let mut turn = true;
            workers.turn(&mut turn, || {
                source = Some(
                    backend
                        .source(backend.generation(), "new", &assets, false)
                        .unwrap(),
                );
            });
            workers.turn(&mut turn, || {
                panic!("the announced header must be prepared")
            });
            done_tx.send(()).unwrap();
            drop(source);
        });
        let completed = done_rx.recv_timeout(Duration::from_secs(3));
        // Release a missed wake before joining, so a regression cannot strand
        // the scoped thread. The timeout only bounds a hang, not performance.
        backend.session.wake();
        worker.join().unwrap();
        completed.unwrap();
    });
    assert_eq!(*events.lock().unwrap(), ["metadata"]);
}

#[test]
fn waited_decode_must_give_the_next_turn_to_metadata() {
    let workers = workers();
    let events = Events::default();
    let known = Known::new(&workers, &events, &Arc::new(AtomicUsize::new(0)));
    let (b, assets) = metadata(&workers, &events, "metadata");
    let mut queued = None;
    let mut turn = true;
    workers.turn(&mut turn, || {
        // Work arrives after this worker's empty metadata scan, before wait_decode.
        queued = Some(b.source(b.generation(), "new", &assets, false).unwrap());
        known.enqueue();
    });
    assert_eq!(*events.lock().unwrap(), ["decode"]);
    workers.turn(&mut turn, || panic!("ready work must not wait"));
    assert_eq!(*events.lock().unwrap(), ["decode", "metadata"]);
    drop(queued);
}

#[test]
fn competing_metadata_turns_still_leave_known_decode_progress() {
    let workers = workers();
    let events = Events::default();
    let known = Known::new(&workers, &events, &Arc::new(AtomicUsize::new(0)));
    let (b, ba) = metadata(&workers, &events, "metadata-b");
    let (c, ca) = metadata(&workers, &events, "metadata-c");
    let _b = b.source(b.generation(), "new", &ba, false).unwrap();
    let _c = c.source(c.generation(), "new", &ca, false).unwrap();
    known.enqueue();
    let mut turn = false;
    for _ in 0..4 {
        workers.turn(&mut turn, || panic!("ready work must not wait"));
    }
    let events = events.lock().unwrap();
    assert_eq!(events[0], "decode");
    assert_eq!(events[2], "decode");
    assert!(events[1].starts_with("metadata-") && events[3].starts_with("metadata-"));
    assert_ne!(events[1], events[3]);
}

#[test]
fn metadata_already_claimed_does_not_block_other_workers_decode_progress() {
    let workers = workers();
    let events = Events::default();
    let decoded = Arc::new(AtomicUsize::new(0));
    let known: Vec<_> = (0..4)
        .map(|_| Known::new(&workers, &events, &decoded))
        .collect();
    let b = Backend::for_workers(&workers);
    let (claimed_tx, claimed_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Mutex::new(release_rx);
    let observed = Arc::new(AtomicUsize::new(usize::MAX));
    let late = observed.clone();
    let count = decoded.clone();
    let bytes = pixels();
    let assets = Arc::new(Assets::selected(
        Default::default(),
        Arc::new(move |_| {
            claimed_tx.send(()).unwrap();
            release_rx
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .map_err(|e| e.to_string())?;
            late.store(count.load(Ordering::SeqCst), Ordering::SeqCst);
            Ok(Some(bytes.clone()))
        }),
    ));
    let source = b.source(b.generation(), "new", &assets, false).unwrap();
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| workers.turn(&mut true, || panic!("metadata available")));
        claimed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(b.prepared(source.id), Some(Prepared::Reading)));
        for a in &known {
            a.enqueue();
        }
        let mut turn = false;
        for _ in 0..8 {
            workers.turn(&mut turn, || {});
        }
        let count = decoded.load(Ordering::SeqCst);
        // Release before assertions so the scoped worker cannot be stranded.
        release_tx.send(()).unwrap();
        worker.join().unwrap();
        assert_eq!(count, 8);
        assert_eq!(
            observed.load(Ordering::SeqCst),
            8,
            "a late callback sample can exceed four after prompt metadata admission"
        );
    });
}
