# WebGPU Path Tracer

An interactive path tracer running on WebGPU compute shaders. Loads GLTF scenes and lets you edit materials and the camera live while rendering.

**Demo**: https://daikiad.github.io/webgpu-path-tracer/

Requires a WebGPU-capable browser (Chrome/Edge 113+, Safari 18+ on macOS 15+).

## Features

- Real-time path tracing on WebGPU compute shaders
- BVH (Bounding Volume Hierarchy) acceleration for ray–triangle intersection
- Progressive rendering with tile-based dispatch and an accumulation buffer
- Materials: `Diffuse`, `Specular`, `Dielectrics`, `GGX`, `Light`, `Smoke` (Henyey–Greenstein)
- GLTF (`.glb`) scene loader
- OrbitControls + Three.js debug overlay
- lil-gui panel for camera / material / rendering parameters
- Automatic preview-resolution switching during edits to avoid flicker
- PNG export of the rendered image

## Getting Started

```bash
npm install
npm run dev      # http://localhost:9000
```

Other scripts:

```bash
npm run build         # production build (outputs to dist/)
npm test              # unit tests with vitest
npm run type-check    # tsc --noEmit
```

## Tech Stack

- **WebGPU** + **WGSL** (compute shader)
- TypeScript / webpack
- [three.js](https://threejs.org/) — GLTFLoader, OrbitControls, debug overlay
- [webgpu-utils](https://github.com/greggman/webgpu-utils) — JS-side mirror of WGSL structs
- [gl-matrix](https://glmatrix.net/) — matrix math
- [lil-gui](https://lil-gui.georgealways.com/) — UI

## Project Layout

| File | Role |
| --- | --- |
| [src/main.ts](src/main.ts) | Entry point and frame loop |
| [src/PathTracer.ts](src/PathTracer.ts) | WebGPU resource management and compute dispatch |
| [src/shader.wgsl](src/shader.wgsl) | Path-tracing compute shader |
| [src/Scene.ts](src/Scene.ts) | BVH construction, GLTF loader, scene editing |
| [src/Material.ts](src/Material.ts) | Material definitions (BRDFs and participating media) |
| [src/Camera.ts](src/Camera.ts) | Camera, OrbitControls, debug overlay |
| [src/ui.ts](src/ui.ts) | lil-gui panel construction |

## Related

- [GPU Path Tracer (2024-07-06)](https://daikiad.github.io/2024/07/06/gpu-path-tracer.html) — write-up of an earlier version of this project
