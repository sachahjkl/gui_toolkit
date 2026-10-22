// wgsl2hlsl <out.hlsl> <shader model: 50> <group.binding=register ...> -- <in.wgsl> [more.wgsl ...]
//
// The toolkit's shaders are written once, in WGSL. This writes the HLSL of a module (the WGSL files concatenated, in order, a
// newline between) for the Direct3D 11 backend, with naga, the translator wgpu uses. A register is b<N> (uniform buffer),
// t<N> (texture, read-only storage buffer: a ByteAddressBuffer) or s<N> (sampler); naga knows the kind from the resource,
// only the number is taken from the map, so the groups are flattened onto Direct3D 11's slots.
use naga::back::hlsl;
use naga::valid::{Capabilities, ValidationFlags, Validator};
use std::collections::BTreeMap;

fn target(register: u32) -> hlsl::BindTarget {
    hlsl::BindTarget { space: 0, register, binding_array_size: None, dynamic_storage_buffer_offsets_index: None, restrict_indexing: false }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        eprintln!("usage: wgsl2hlsl <out.hlsl> <model> <g.b=reg>... -- <in.wgsl>...");
        std::process::exit(2);
    }
    let out = &args[0];
    let model = match args[1].as_str() {
        "50" => hlsl::ShaderModel::V5_0,
        m => {
            eprintln!("shader model {m}: only 50 (Direct3D 11)");
            std::process::exit(2)
        }
    };
    let sep = args.iter().position(|a| a == "--").expect("missing --");
    let mut opts = hlsl::Options::default();
    opts.shader_model = model;
    opts.fake_missing_bindings = false;
    // the samplers of each group in the order of their bindings: naga indexes them (see direct_samplers)
    let mut samplers: BTreeMap<(u32, u32), u32> = BTreeMap::new();
    for a in &args[2..sep] {
        let (gb, reg) = a.split_once('=').expect("g.b=reg");
        let (g, b) = gb.split_once('.').expect("g.b");
        let (g, b): (u32, u32) = (g.parse().unwrap(), b.parse().unwrap());
        let n: u32 = reg[1..].parse().expect("register number");
        opts.binding_map.insert(naga::ResourceBinding { group: g, binding: b }, target(n));
        if reg.starts_with('s') {
            samplers.insert((g, b), n);
        }
    }
    // Direct3D 12's sampler heaps are unused (direct_samplers), but the writer wants a slot for each group's index buffer
    for g in 0..4 {
        opts.sampler_buffer_binding_map.insert(hlsl::SamplerIndexBufferKey { group: g }, target(100 + g));
    }
    let mut src = String::new();
    for f in &args[sep + 1..] {
        src.push_str(&std::fs::read_to_string(f).unwrap_or_else(|e| {
            eprintln!("{f}: {e}");
            std::process::exit(1)
        }));
        src.push('\n');
    }
    let module = naga::front::wgsl::parse_str(&src).unwrap_or_else(|e| {
        eprintln!("{}", e.emit_to_string(&src));
        std::process::exit(1)
    });
    let info = Validator::new(ValidationFlags::all(), Capabilities::all()).validate(&module).unwrap_or_else(|e| {
        eprintln!("validation: {e:?}");
        std::process::exit(1)
    });
    let mut text = String::new();
    let pipeline = hlsl::PipelineOptions::default();
    let mut writer = hlsl::Writer::new(&mut text, &opts, &pipeline);
    writer.write(&module, &info, None).unwrap_or_else(|e| {
        eprintln!("hlsl: {e:?}");
        std::process::exit(1)
    });
    std::fs::write(out, direct_samplers(&text, &samplers)).unwrap();
}

// naga's HLSL writer reaches samplers through the sampler heaps of Direct3D 12: an array of SamplerState indexed by a
// per-group buffer. Direct3D 11 has neither: each sampler becomes a plain SamplerState in the slot the map gives it.
fn direct_samplers(text: &str, samplers: &BTreeMap<(u32, u32), u32>) -> String {
    let mut out = String::new();
    for line in text.lines() {
        if line.starts_with("SamplerState nagaSamplerHeap")
            || line.starts_with("SamplerComparisonState nagaComparisonSamplerHeap")
            || (line.starts_with("StructuredBuffer<uint> naga") && line.contains("SamplerIndexArray"))
        {
            continue;
        }
        if let Some(rest) = line.strip_prefix("static const SamplerState ") {
            let (name, rhs) = rest.split_once(" = nagaSamplerHeap[nagaGroup").expect("sampler line");
            let (g, rhs) = rhs.split_once("SamplerIndexArray[").expect("sampler group");
            let (k, _) = rhs.split_once(']').expect("sampler index");
            let (g, k): (u32, usize) = (g.parse().unwrap(), k.parse().unwrap());
            let slots: Vec<u32> = samplers.iter().filter(|((gg, _), _)| *gg == g).map(|(_, r)| *r).collect();
            out.push_str(&format!("SamplerState {name} : register(s{});\n", slots[k]));
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}
