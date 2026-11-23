use super::{crop, png_decode::DecodePlan, View, PARTS};
use exact_raster::{PixelSize, RasterSession};

/// A raster already decoded (or decoding) a little larger serves this view
/// too. Otherwise a box that clips the picture can ask for its visible part.
pub(super) fn for_view(
    session: &RasterSession,
    view: &View,
    source: u64,
    decode: DecodePlan,
    budget: u64,
) -> DecodePlan {
    let header = decode.header;
    // An SVG is drawn for its box. A larger box can resolve a different scene.
    if header.is_svg() {
        return decode;
    }
    let wanted = u64::from(decode.pixels.width) * u64::from(decode.pixels.height);
    let held = session.covering(
        source,
        view.key.generation,
        decode.storage(),
        decode.pixels,
        wanted * 5 / 2,
    );
    if let Some(pixels) = held {
        return (pixels != decode.pixels)
            .then(|| DecodePlan::new(header, (pixels.width, pixels.height)).ok())
            .flatten()
            .filter(|p| p.peak_bytes() <= budget)
            .unwrap_or(decode);
    }
    (!view.resized && *PARTS)
        .then_some(view.fit)
        .flatten()
        .and_then(|fit| crop::part(decode.natural(), decode.pixels, view.desired, fit))
        .and_then(|(x, y, pixels)| decode.part(x, y, pixels).ok())
        .unwrap_or(decode)
}

pub(super) fn sharper(next: PixelSize, current: PixelSize) -> bool {
    next != current && next.width >= current.width && next.height >= current.height
}
