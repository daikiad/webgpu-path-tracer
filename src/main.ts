import { PathTracer } from './PathTracer';
import { Camera } from './Camera';
import { Scene, loadGLTFScene } from './Scene';
import { setupUI, type UIActions } from './ui';
import { DEFAULT_CAMERA_STATE } from './Camera';
import { INITIAL_RENDER_STATE, type RenderingConfig, type RenderState } from './PathTracer';

import glbPath from './scenes/cornell-box.glb';

interface DisplayUpdateConfig {
    interval: number;
    autoMode: boolean;
}

const RENDERING_DEFAULTS = {
    DEFAULT_ALGORITHM: 4,
    FULL_RESOLUTION: 1,
    DEFAULT_TILES_X: 4,
    DEFAULT_TILES_Y: 4,
    MIN_RAY_DEPTH: 0,
    MAX_RAY_DEPTH: 100,
};
const PREVIEW_RESOLUTION_SCALE = 4;
const FULL_RESOLUTION = 1;
const PREVIEW_DEBOUNCE_MS = 250;

interface WebGPUContext {
    device: GPUDevice;
    context: GPUCanvasContext;
    presentationFormat: GPUTextureFormat;
    canvas: HTMLCanvasElement;
}

async function initWebGPU(canvasElementId: string = 'webgpu-canvas'): Promise<WebGPUContext | null> {
    const adapter = await navigator.gpu?.requestAdapter();
    if (!adapter) {
        alert('WebGPU not supported');
        return null;
    }

    const device = await adapter.requestDevice();
    if (!device) {
        alert('Need a browser that supports WebGPU');
        return null;
    }

    const canvas = document.getElementById(canvasElementId) as HTMLCanvasElement;
    const context = canvas.getContext('webgpu');
    if (!context) {
        console.error('Unable to initialize WebGPU context');
        return null;
    }

    const presentationFormat = navigator.gpu.getPreferredCanvasFormat();
    context.configure({ device, format: presentationFormat });

    return { device, context, presentationFormat, canvas };
}

window.addEventListener('error', (e) => console.error('[unhandled error]', e.error ?? e.message));
window.addEventListener('unhandledrejection', (e) => console.error('[unhandled rejection]', e.reason));

function createPresenter(ctx: WebGPUContext) {
    const wgpuCanvas = ctx.canvas;
    const outputCanvas = document.createElement('canvas');
    outputCanvas.width = wgpuCanvas.width;
    outputCanvas.height = wgpuCanvas.height;
    outputCanvas.style.cssText = wgpuCanvas.style.cssText;
    outputCanvas.id = wgpuCanvas.id + '-output';
    wgpuCanvas.style.display = 'none';
    wgpuCanvas.parentNode?.insertBefore(outputCanvas, wgpuCanvas.nextSibling);
    const ctx2D = outputCanvas.getContext('2d');
    if (!ctx2D) throw new Error('Canvas 2D context not available');

    let readBuffer: GPUBuffer | undefined;

    async function present(texture: GPUTexture): Promise<void> {
        const width = texture.width;
        const height = texture.height;
        const bytesPerRow = Math.ceil((width * 4) / 256) * 256;
        const bufferSize = bytesPerRow * height;

        if (!readBuffer || readBuffer.size !== bufferSize) {
            readBuffer?.destroy();
            readBuffer = ctx.device.createBuffer({
                size: bufferSize,
                usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
            });
        }

        const encoder = ctx.device.createCommandEncoder();
        encoder.copyTextureToBuffer(
            { texture },
            { buffer: readBuffer, bytesPerRow },
            { width, height, depthOrArrayLayers: 1 },
        );
        ctx.device.queue.submit([encoder.finish()]);

        await readBuffer.mapAsync(GPUMapMode.READ);
        const arrayBuffer = readBuffer.getMappedRange();

        // bytesPerRow は 256 の倍数にパディングされているので、パディングを取り除いて putImageData する
        if (outputCanvas.width !== width || outputCanvas.height !== height) {
            outputCanvas.width = width;
            outputCanvas.height = height;
        }
        const padded = new Uint8ClampedArray(arrayBuffer);
        const imageData = new Uint8ClampedArray(width * height * 4);
        const rowBytes = width * 4;
        for (let y = 0; y < height; y++) {
            const src = y * bytesPerRow;
            const dst = y * rowBytes;
            for (let x = 0; x < rowBytes; x++) imageData[dst + x] = padded[src + x];
        }
        ctx2D!.putImageData(new ImageData(imageData, width, height), 0, 0);

        readBuffer.unmap();
    }

    return { present, outputCanvas };
}

function createPerf() {
    const BROWSER_FPS_SAMPLES = 60;
    let renderStartTime = performance.now();
    let lastSpp = 0;
    let lastSppTime = performance.now();
    let lastInstantSppPerSecond = 0;
    const browserFrameTimes: number[] = [];
    let lastBrowserFrameTime = performance.now();

    function startBrowserRenderTracking() {
        const tick = () => {
            const now = performance.now();
            browserFrameTimes.push(now - lastBrowserFrameTime);
            lastBrowserFrameTime = now;
            if (browserFrameTimes.length > BROWSER_FPS_SAMPLES) browserFrameTimes.shift();
            requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
    }

    function computeBrowserFps(): number {
        if (browserFrameTimes.length === 0) return 0;
        const avgMs = browserFrameTimes.reduce((a, b) => a + b, 0) / browserFrameTimes.length;
        if (avgMs <= 0) return 0;
        return Math.round((1000 / avgMs) * 10) / 10;
    }

    function reset() {
        renderStartTime = performance.now();
        lastSpp = 0;
        lastSppTime = performance.now();
        lastInstantSppPerSecond = 0;
    }

    function recordFrameAndComputeMetrics(currentSpp: number) {
        const now = performance.now();
        let sppPerSecond = lastInstantSppPerSecond;
        if (currentSpp > lastSpp) {
            const dt = (now - lastSppTime) / 1000;
            if (dt > 0.001) {
                sppPerSecond = (currentSpp - lastSpp) / dt;
                lastInstantSppPerSecond = sppPerSecond;
            }
            lastSpp = currentSpp;
            lastSppTime = now;
        }
        return {
            browserFps: computeBrowserFps(),
            sppPerSecond: Math.round(sppPerSecond * 1000) / 1000,
            elapsedTime: Math.round((now - renderStartTime) / 100) / 10,
        };
    }

    return { startBrowserRenderTracking, reset, recordFrameAndComputeMetrics };
}

async function main() {
    const ctx = await initWebGPU();
    if (!ctx) return;

    const renderingConfig: RenderingConfig = {
        width: ctx.canvas.width,
        height: ctx.canvas.height,
        algorithm: RENDERING_DEFAULTS.DEFAULT_ALGORITHM,
        resolution: RENDERING_DEFAULTS.FULL_RESOLUTION,
        numtilesx: RENDERING_DEFAULTS.DEFAULT_TILES_X,
        numtilesy: RENDERING_DEFAULTS.DEFAULT_TILES_Y,
        mindepth: RENDERING_DEFAULTS.MIN_RAY_DEPTH,
        maxdepth: RENDERING_DEFAULTS.MAX_RAY_DEPTH,
        sppPerDispatch: 1,
        useHighPerformanceMode: false,
    };

    const pathTracer = new PathTracer(ctx.device, renderingConfig);
    const scene = new Scene();
    const presenter = createPresenter(ctx);
    const camera = new Camera();
    const threeCanvas = document.getElementById('three-canvas') as HTMLCanvasElement;
    camera.enableControls(threeCanvas);
    const perf = createPerf();
    perf.startBrowserRenderTracking();

    let frameCount = 0;
    let isRendering = true;
    let lastDisplayUpdate = 0;
    let state: RenderState = { ...INITIAL_RENDER_STATE };
    let isEditing = false;
    let previewDebounceTimer: number | null = null;
    const displayUpdateConfig: DisplayUpdateConfig = { interval: 1, autoMode: true };

    function resetAccumulation(): void {
        pathTracer.clearAccumulation();
        state = { ...INITIAL_RENDER_STATE };
    }

    // 連続編集中はプレビュー解像度に落としてチラつきを抑える。debounce は last-call wins。
    function beginPreview(): void {
        if (!isEditing) {
            renderingConfig.resolution = PREVIEW_RESOLUTION_SCALE;
            pathTracer.updateSettings(renderingConfig, state);
            isEditing = true;
        } else if (previewDebounceTimer !== null) {
            clearTimeout(previewDebounceTimer);
        }
        previewDebounceTimer = setTimeout(endPreview, PREVIEW_DEBOUNCE_MS) as unknown as number;
    }

    function endPreview(): void {
        if (!isEditing) return;
        isEditing = false;
        previewDebounceTimer = null;
        resetAccumulation();
    }

    function advanceTile(): void {
        let { spp, tilex, tiley } = state;
        tilex++;
        if (tilex >= renderingConfig.numtilesx) {
            tilex = 0;
            tiley++;
            if (tiley >= renderingConfig.numtilesy) {
                tiley = 0;
                spp++;
            }
        }
        state = { spp, tilex, tiley };
    }

    function shouldUpdateDisplay(): boolean {
        if (camera.isMoving()) return true;
        const elapsed = frameCount - lastDisplayUpdate;
        if (displayUpdateConfig.autoMode) {
            const spp = state.spp;
            let autoInterval = 1;
            if (spp > 100) autoInterval = 10;
            else if (spp > 50) autoInterval = 5;
            else if (spp > 20) autoInterval = 3;
            else if (spp > 10) autoInterval = 2;
            return elapsed >= autoInterval;
        }
        return elapsed >= displayUpdateConfig.interval;
    }

    const actions: UIActions = {
        pauseRendering: () => { isRendering = false; },
        resumeRendering: () => { isRendering = true; },
        clearAccumulation: () => {
            resetAccumulation();
            perf.reset();
        },
        saveImage: () => {
            const dataURL = presenter.outputCanvas.toDataURL('image/png');
            const link = document.createElement('a');
            link.href = dataURL;
            link.download = `pathtracer-${Date.now()}.png`;
            link.click();
        },
        setPerformanceMode: (mode) => {
            renderingConfig.sppPerDispatch = mode.sppPerDispatch;
            renderingConfig.useHighPerformanceMode = mode.useUncappedFrameRate;
            pathTracer.updateSettings(renderingConfig, state);
        },
        applyCameraControls: (controls) => {
            const cs = camera.getCameraState();
            camera.setCameraState({
                ...cs,
                position: controls.position,
                target: controls.target,
                fov: controls.fov,
                zoom: controls.zoom,
            });
        },
        updateObjectTransform: (t) => scene.editObjectTransform(t),
        updateObjectMaterial: (e) => scene.editObjectMaterial(e),
    };

    const ui = setupUI(scene, actions);

    const result = await loadGLTFScene(glbPath);

    const cs0 = camera.getCameraState();
    camera.setCameraState({
        ...cs0,
        position: result.gltfCameraPosition ?? ([...DEFAULT_CAMERA_STATE.position] as [number, number, number]),
        target: [...DEFAULT_CAMERA_STATE.target] as [number, number, number],
    });

    for (const o of result.objects) {
        scene.addObject(o.sceneObject);
        camera.addDebugMesh(o.sceneObject.debugMesh);
    }

    scene.dirty = true;

    const cs1 = camera.getCameraState();
    ui.updateCameraState({ position: cs1.position, target: cs1.target, fov: cs1.fov, zoom: cs1.zoom });
    ui.rebuild();

    async function frame(): Promise<void> {
        frameCount++;

        if (camera.update()) {
            const gpuData = camera.getGPUData();
            pathTracer.updateCamera({
                position: gpuData.position,
                invCameraMatrix: gpuData.inverseViewProjectionMatrix,
            });
            const cs = camera.getCameraState();
            ui.updateCameraState({ position: cs.position, target: cs.target, fov: cs.fov, zoom: cs.zoom });
            if (!camera.isMoving()) {
                resetAccumulation();
                beginPreview();
            }
        }

        if (camera.isMoving()) {
            resetAccumulation();
            renderingConfig.resolution = PREVIEW_RESOLUTION_SCALE;
        }

        if (scene.dirty) {
            pathTracer.updateScene(scene.getWgslData());
            scene.dirty = false;
            state = { ...INITIAL_RENDER_STATE };
            perf.reset();
            resetAccumulation();
            beginPreview();
        }

        if (isRendering) {
            if (!camera.isMoving() && !isEditing) {
                renderingConfig.resolution = FULL_RESOLUTION;
            }

            try {
                const sppPerDispatch = renderingConfig.sppPerDispatch || 1;
                let lastResult = null;
                for (let i = 0; i < sppPerDispatch; i++) {
                    pathTracer.updateSettings(renderingConfig, state);
                    lastResult = pathTracer.render();
                    advanceTile();
                }
                if (shouldUpdateDisplay() && lastResult) {
                    await presenter.present(lastResult.texture);
                    lastDisplayUpdate = frameCount;
                    camera.renderDebugOverlay();
                }
            } catch (error) {
                console.error('render-frame error:', error);
            }

            const m = perf.recordFrameAndComputeMetrics(state.spp);
            ui.updateStats({
                fps: m.browserFps || 0,
                instantSppPerSecond: m.sppPerSecond,
                elapsedTime: m.elapsedTime,
                currentSamplesPerPixel: state.spp,
            });
        }

        const useUncapped = renderingConfig.useHighPerformanceMode && !camera.isMoving();
        if (useUncapped) {
            if (isRendering) setTimeout(frame, 0);
        } else {
            requestAnimationFrame(frame);
        }
    }

    frame();

    (window as any).debug = { scene, camera, perf };
}

main().catch((err) => console.error('Initialization failed:', err));
