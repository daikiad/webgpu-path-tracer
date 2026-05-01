import { GUI } from 'lil-gui';
import type { Scene, SceneObject, ObjectTransform, MaterialEdit } from './Scene';
import { type CameraControls, DEFAULT_CAMERA_STATE } from './Camera';
import type { MaterialType } from './Material';

export interface RenderStats {
    fps: number;
    instantSppPerSecond: number;
    elapsedTime: number;
    currentSamplesPerPixel: number;
}

export interface PerformanceMode {
    sppPerDispatch: number;
    useUncappedFrameRate: boolean;
}

export interface UIActions {
    pauseRendering(): void;
    resumeRendering(): void;
    clearAccumulation(): void;
    saveImage(): void;
    setPerformanceMode(mode: PerformanceMode): void;
    applyCameraControls(controls: CameraControls): void;
    updateObjectTransform(t: ObjectTransform): void;
    updateObjectMaterial(e: MaterialEdit): void;
}

export interface UIController {
    updateStats(stats: RenderStats): void;
    updateCameraState(cs: CameraControls): void;
    /** GUI 全体を destroy + 再構築。loadScene 完了時 / マテリアルプリセット適用時に呼ぶ。 */
    rebuild(): void;
}

export function setupUI(scene: Scene, actions: UIActions): UIController {
    injectStyles();

    const stats: RenderStats = {
        fps: 0,
        instantSppPerSecond: 0,
        elapsedTime: 0,
        currentSamplesPerPixel: 0,
    };
    const uiState = { isRendering: true };
    const performanceMode: PerformanceMode = {
        sppPerDispatch: 1,
        useUncappedFrameRate: false,
    };
    const cameraState: CameraControls = {
        position: [...DEFAULT_CAMERA_STATE.position],
        target: [...DEFAULT_CAMERA_STATE.target],
        fov: DEFAULT_CAMERA_STATE.fov,
        zoom: DEFAULT_CAMERA_STATE.zoom,
    };

    let gui: GUI;
    let toggleButton: any;

    function build(): void {
        gui = new GUI({ title: 'Path Tracer Controls', width: 300 });
        buildQuickActions();
        buildPerformance();
        buildCamera();
        buildSceneObjects();
    }

    function refresh(): void {
        gui.destroy();
        build();
    }

    function buildQuickActions(): void {
        const folder = gui.addFolder('Quick Actions');
        folder.open();
        const handlers = {
            toggleRendering: () => {
                uiState.isRendering = !uiState.isRendering;
                if (uiState.isRendering) actions.resumeRendering();
                else actions.pauseRendering();
                toggleButton.name(uiState.isRendering ? 'Pause Rendering' : 'Resume Rendering');
            },
            clearAndRestart: () => actions.clearAccumulation(),
            saveImage: () => actions.saveImage(),
        };
        toggleButton = folder
            .add(handlers, 'toggleRendering')
            .name(uiState.isRendering ? 'Pause Rendering' : 'Resume Rendering');
        folder.add(handlers, 'clearAndRestart').name('Clear & Restart');
        folder.add(handlers, 'saveImage').name('Save Image');
    }

    function buildPerformance(): void {
        const folder = gui.addFolder('Performance');
        folder.open();

        const display = {
            get fps() { return `${stats.fps.toFixed(1)} FPS`; },
            get spp() { return `${stats.instantSppPerSecond.toFixed(2)} SPP/s`; },
            get samples() { return `${stats.currentSamplesPerPixel} samples`; },
            get elapsed() { return `${stats.elapsedTime.toFixed(1)}s`; },
        };
        folder.add(display, 'fps').name('FPS').listen().disable();
        folder.add(display, 'spp').name('SPP/s').listen().disable();
        folder.add(display, 'samples').name('Samples/Pixel').listen().disable();
        folder.add(display, 'elapsed').name('Elapsed').listen().disable();

        const fire = () => actions.setPerformanceMode({ ...performanceMode });
        folder.add(performanceMode, 'sppPerDispatch', 1, 32, 1).name('SPP per Frame').onChange(fire);
        folder.add(performanceMode, 'useUncappedFrameRate').name('Uncapped FPS').onChange(fire);
    }

    function buildCamera(): void {
        const folder = gui.addFolder('Camera');
        const fire = () => actions.applyCameraControls({ ...cameraState });
        folder.add(cameraState, 'fov', 10, 120).step(1).name('Field of View').onChange(fire);
        folder.add(cameraState, 'zoom', 0.1, 10).step(0.1).name('Zoom').onChange(fire);
    }

    function buildSceneObjects(): void {
        const folder = gui.addFolder('Scene Objects');

        if (scene.objects.length === 0) {
            const emptyState = { info: 'No objects loaded yet' };
            folder.add(emptyState, 'info').name('Status').listen().disable();
            return;
        }

        scene.objects.forEach((sceneObj, index) => {
            const objFolder = folder.addFolder(sceneObj.objectName || `Object ${index + 1}`);
            // SceneObject の現在値から UI 用の DTO を作る (lil-gui がスライダーを bind する先)
            const t = {
                visible: sceneObj.isVisible,
                px: sceneObj.worldTranslation.x,
                py: sceneObj.worldTranslation.y,
                pz: sceneObj.worldTranslation.z,
                rx: (sceneObj.worldRotation.x * 180) / Math.PI,
                ry: (sceneObj.worldRotation.y * 180) / Math.PI,
                rz: (sceneObj.worldRotation.z * 180) / Math.PI,
                sx: sceneObj.worldScale.x,
                sy: sceneObj.worldScale.y,
                sz: sceneObj.worldScale.z,
            };
            const fire = () => actions.updateObjectTransform({
                id: sceneObj.id,
                name: sceneObj.objectName,
                position: [t.px, t.py, t.pz],
                rotation: [t.rx, t.ry, t.rz],
                scale: [t.sx, t.sy, t.sz],
                visible: t.visible,
            });

            objFolder.add(t, 'visible').name('Visible').onChange(fire);

            const posFolder = objFolder.addFolder('Position');
            posFolder.add(t, 'px', -20, 20).step(0.1).name('X').onChange(fire);
            posFolder.add(t, 'py', -20, 20).step(0.1).name('Y').onChange(fire);
            posFolder.add(t, 'pz', -20, 20).step(0.1).name('Z').onChange(fire);

            const rotFolder = objFolder.addFolder('Rotation (deg)');
            rotFolder.add(t, 'rx', -180, 180).step(1).name('X').onChange(fire);
            rotFolder.add(t, 'ry', -180, 180).step(1).name('Y').onChange(fire);
            rotFolder.add(t, 'rz', -180, 180).step(1).name('Z').onChange(fire);

            const scaleFolder = objFolder.addFolder('Scale');
            scaleFolder.add(t, 'sx', 0.1, 5).step(0.1).name('X').onChange(fire);
            scaleFolder.add(t, 'sy', 0.1, 5).step(0.1).name('Y').onChange(fire);
            scaleFolder.add(t, 'sz', 0.1, 5).step(0.1).name('Z').onChange(fire);

            buildMaterial(objFolder, sceneObj);
        });
    }

    function buildMaterial(parentFolder: GUI, sceneObj: SceneObject): void {
        const folder = parentFolder.addFolder('Material');

        const m = sceneObj.material;
        const materialUI = {
            type: m.materialType,
            color: rgbToHex(m.baseColor),
            refractionIndex: m.refractionIndex,
            surfaceRoughness: m.surfaceRoughness,
            lightIntensity: m.lightIntensity,
        };

        const fire = () => {
            const hex = materialUI.color;
            const r = parseInt(hex.slice(1, 3), 16) / 255;
            const g = parseInt(hex.slice(3, 5), 16) / 255;
            const b = parseInt(hex.slice(5, 7), 16) / 255;
            const edit: MaterialEdit = {
                objectId: sceneObj.id,
                materialType: materialUI.type,
                baseColor: [r, g, b],
                lightIntensity: materialUI.lightIntensity,
                refractionIndex: materialUI.refractionIndex,
                surfaceRoughness: materialUI.surfaceRoughness,
            };
            actions.updateObjectMaterial(edit);
        };

        folder.add(materialUI, 'type', ['Diffuse', 'Specular', 'Dielectrics', 'GGX', 'Smoke', 'Light']).name('Type').onChange(fire);
        folder.addColor(materialUI, 'color').name('Base Color').onChange(fire);
        folder.add(materialUI, 'refractionIndex', 1, 3).step(0.01).name('Refraction (Glass)').onChange(fire);
        folder.add(materialUI, 'surfaceRoughness', 0, 1).step(0.01).name('Roughness (GGX)').onChange(fire);
        folder.add(materialUI, 'lightIntensity', 0, 100).step(1).name('Intensity (Light)').onChange(fire);

        const applyPreset = (type: MaterialType, color: string) => {
            materialUI.type = type;
            materialUI.color = color;
            fire();
            refresh();
        };
        const presets = {
            'Diffuse White': () => applyPreset('Diffuse', '#cccccc'),
            'Diffuse Red':   () => applyPreset('Diffuse', '#cc3333'),
            Mirror:          () => applyPreset('Specular', '#e6e6e6'),
            Glass:           () => { materialUI.refractionIndex = 1.5; applyPreset('Dielectrics', '#e6e6e6'); },
            Light:           () => { materialUI.lightIntensity = 10; applyPreset('Light', '#ffffff'); },
        };
        const presetsFolder = folder.addFolder('Presets');
        presetsFolder.add(presets, 'Diffuse White');
        presetsFolder.add(presets, 'Diffuse Red');
        presetsFolder.add(presets, 'Mirror');
        presetsFolder.add(presets, 'Glass');
        presetsFolder.add(presets, 'Light');
    }

    build();

    return {
        updateStats(s) {
            stats.fps = s.fps;
            stats.instantSppPerSecond = s.instantSppPerSecond;
            stats.elapsedTime = s.elapsedTime;
            stats.currentSamplesPerPixel = s.currentSamplesPerPixel;
        },
        updateCameraState(cs) {
            // FOV/Zoom スライダーが cameraState オブジェクトにバインドされているので
            // 参照を保ったまま in-place で書き換える (再代入だと bind が古いまま残る)
            cameraState.position = [...cs.position];
            cameraState.target = [...cs.target];
            cameraState.fov = cs.fov;
            cameraState.zoom = cs.zoom;
        },
        rebuild: refresh,
    };
}

function rgbToHex(rgb: [number, number, number]): string {
    const ch = (v: number) => Math.round(v * 255).toString(16).padStart(2, '0');
    return `#${ch(rgb[0])}${ch(rgb[1])}${ch(rgb[2])}`;
}

function injectStyles(): void {
    const style = document.createElement('style');
    style.textContent = `
        .lil-gui .folder > .title {
            background: #2a2a2a !important;
            color: #999999 !important;
            font-size: 10px !important;
            text-transform: uppercase !important;
            letter-spacing: 0.5px !important;
            padding-left: 8px !important;
            border-left: 2px solid #555555 !important;
        }
        .lil-gui .folder > .title:hover {
            background: #333333 !important;
            color: #bbbbbb !important;
        }
    `;
    document.head.appendChild(style);
}
