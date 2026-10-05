// Same generator, checksum, and run count as bench/compare/harness.zig.

use std::hint::black_box;
use std::time::Instant;

const RUNS: usize = 9;

fn points(xs: &mut [u32], ys: &mut [u32], bits: u32) {
    let mut s: u64 = 0x1234567;
    let shift = 32 - bits;
    for (x, y) in xs.iter_mut().zip(ys.iter_mut()) {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        let r = s.wrapping_mul(0x2545F4914F6CDD1D);
        *x = ((r >> 32) as u32) >> shift;
        *y = (r as u32) >> shift;
    }
}

fn checksum(hs: &[u64]) -> u64 {
    hs.iter()
        .enumerate()
        .fold(0u64, |acc, (i, &h)| acc.wrapping_add(h.wrapping_mul(i as u64 | 1)))
}

fn median(mut f: impl FnMut()) -> f64 {
    f();
    let mut samples = [0u128; RUNS];
    for s in samples.iter_mut() {
        let start = Instant::now();
        f();
        *s = start.elapsed().as_nanos();
    }
    samples.sort_unstable();
    samples[RUNS / 2] as f64
}

fn main() {
    let n: usize = std::env::args().nth(1).map(|a| a.parse().unwrap()).unwrap_or(8_388_608);
    let mut xs = vec![0u32; n];
    let mut ys = vec![0u32; n];
    let mut hs = vec![0u64; n];
    let mut bx = vec![0u32; n];
    let mut by = vec![0u32; n];
    for bits in [32u32, 16] {
        points(&mut xs, &mut ys, bits);
        let order = bits as u8;
        let e = median(|| {
            for ((x, y), h) in xs.iter().zip(ys.iter()).zip(hs.iter_mut()) {
                *h = fast_hilbert::xy2h(*x, *y, order);
            }
            black_box(&hs);
        }) / n as f64;
        let sum = checksum(&hs);
        let d = median(|| {
            for ((h, x), y) in hs.iter().zip(bx.iter_mut()).zip(by.iter_mut()) {
                let (px, py) = fast_hilbert::h2xy::<u32>(*h, order);
                *x = px;
                *y = py;
            }
            black_box((&bx, &by));
        }) / n as f64;
        let ok = xs == bx && ys == by;
        println!("rust-fast_hilbert-2.1.0 encode {bits} {e:.3} {sum:016x}");
        println!(
            "rust-fast_hilbert-2.1.0 decode {bits} {d:.3} {}",
            if ok { "roundtrip-ok" } else { "ROUNDTRIP-FAILED" }
        );
    }
}
