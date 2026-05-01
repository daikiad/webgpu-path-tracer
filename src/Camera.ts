import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls';
import { mat4, vec3 } from 'gl-matrix';

export interface CameraState {
    position: [number, number, number];
    target: [number, number, number];
    fov: number;
    near: number;
    far: number;
    aspect: number;
    zoom: number;
}

export type CameraControls = Pick<CameraState, 'position' | 'target' | 'fov' | 'zoom'>;

export interface CameraControlConfig {
    enableDamping: boolean;
    dampingFactor: number;
    enableZoom: boolean;
    enableRotate: boolean;
    enablePan: boolean;
    minDistance: number;
    maxDistance: number;
    minPolarAngle: number;
    maxPolarAngle: number;
}

export interface CameraGPUData {
    position: Float32Array;
    inverseViewProjectionMatrix: Float32Array;
}

export const DEFAULT_CAMERA_CONFIG: CameraControlConfig = {
    enableDamping: false,
    dampingFactor: 0.05,
    enableZoom: true,
    enableRotate: true,
    enablePan: true,
    minDistance: 0,
    maxDistance: Infinity,
    minPolarAngle: 0,
    maxPolarAngle: Math.PI,
};

export const DEFAULT_CAMERA_STATE: CameraState = {
    position: [0, 0, 3],
    target: [0, 0, 0],
    fov: 45,
    near: 0.1,
    far: 1000,
    aspect: 1.0,
    zoom: 1,
};

export class Camera {
    private camera: THREE.PerspectiveCamera;
    private controls: OrbitControls | null = null;
    private currentState: CameraState;
    private dirty: boolean = true;
    private isCurrentlyMoving: boolean = false;

    private controlConfig: CameraControlConfig;

    private debugScene: THREE.Scene | null = null;
    private debugRenderer: THREE.WebGLRenderer | null = null;

    private wheelTimer: number | null = null;
    private readonly WHEEL_TIMEOUT = 150;
    private boundWheelHandler: ((event: Event) => void) | null = null;

    constructor(initialState?: Partial<CameraState>) {
        const state = { ...DEFAULT_CAMERA_STATE, ...initialState };
        this.camera = new THREE.PerspectiveCamera(state.fov, state.aspect, state.near, state.far);
        this.camera.position.set(...state.position);
        this.camera.lookAt(...state.target);
        this.camera.updateMatrixWorld();

        this.currentState = state;
        this.controlConfig = { ...DEFAULT_CAMERA_CONFIG };
    }

    getCamera(): THREE.PerspectiveCamera {
        return this.camera;
    }

    getCameraState(): CameraState {
        return { ...this.currentState };
    }

    setCameraState(state: CameraState): void {
        this.currentState = { ...state };
        this.dirty = true;
        this.camera.position.set(...state.position);
        this.camera.lookAt(...state.target);
        this.camera.fov = state.fov;
        this.camera.aspect = state.aspect;
        this.camera.near = state.near;
        this.camera.far = state.far;
        this.camera.zoom = state.zoom;

        this.camera.updateProjectionMatrix();
        this.camera.updateMatrixWorld();

        if (this.controls) {
            this.controls.target.set(...state.target);
            this.controls.update();
        }
    }

    enableControls(canvas: HTMLCanvasElement, config?: Partial<CameraControlConfig>): void {
        if (this.controls) this.disableControls();

        this.debugScene = new THREE.Scene();
        this.debugScene.add(new THREE.AmbientLight(0xffffff, 0.4));
        const directional = new THREE.DirectionalLight(0xffffff, 0.8);
        directional.position.set(5, 5, 5);
        this.debugScene.add(directional);

        this.debugRenderer = new THREE.WebGLRenderer({ canvas });
        this.debugRenderer.setSize(canvas.width, canvas.height);

        this.controlConfig = { ...DEFAULT_CAMERA_CONFIG, ...config };
        this.controls = new OrbitControls(this.camera, canvas);
        this.configureControls();
        this.setupControlEvents();
    }

    disableControls(): void {
        if (this.controls) {
            if (this.controls.domElement && this.boundWheelHandler) {
                this.controls.domElement.removeEventListener('wheel', this.boundWheelHandler);
                this.boundWheelHandler = null;
            }
            this.controls.dispose();
            this.controls = null;
        }
    }

    addDebugMesh(mesh: THREE.Mesh): void {
        this.debugScene?.add(mesh);
    }

    renderDebugOverlay(): void {
        if (this.debugScene && this.debugRenderer) {
            this.debugRenderer.render(this.debugScene, this.camera);
        }
    }

    isMoving(): boolean {
        return this.isCurrentlyMoving;
    }

    update(): boolean {
        this.camera.updateMatrixWorld();
        const newState = this.extractCurrentState();
        const changed = this.dirty || this.isCurrentlyMoving || this.hasStateChanged(newState);
        if (changed) {
            this.currentState = newState;
            this.dirty = false;
            return true;
        }
        return false;
    }

    getCameraPosition(): Float32Array {
        const p = vec3.fromValues(this.camera.position.x, this.camera.position.y, this.camera.position.z);
        return new Float32Array(p);
    }

    getInverseCameraMatrix(): Float32Array {
        const view = new Float32Array(this.camera.matrixWorldInverse.elements);
        const proj = new Float32Array(this.camera.projectionMatrix.elements);
        const pv = mat4.create();
        mat4.multiply(pv, proj, view);
        const inv = mat4.invert(mat4.create(), pv)!;
        return new Float32Array(inv);
    }

    getGPUData(): CameraGPUData {
        return {
            position: this.getCameraPosition(),
            inverseViewProjectionMatrix: this.getInverseCameraMatrix(),
        };
    }

    private configureControls(): void {
        if (!this.controls) return;
        const c = this.controlConfig;
        this.controls.enableDamping = c.enableDamping;
        this.controls.dampingFactor = c.dampingFactor;
        this.controls.enableZoom = c.enableZoom;
        this.controls.enableRotate = c.enableRotate;
        this.controls.enablePan = c.enablePan;
        this.controls.minDistance = c.minDistance;
        this.controls.maxDistance = c.maxDistance;
        this.controls.minPolarAngle = c.minPolarAngle;
        this.controls.maxPolarAngle = c.maxPolarAngle;
        this.controls.target.set(...this.currentState.target);
        this.controls.update();
    }

    private setupControlEvents(): void {
        if (!this.controls) return;

        this.controls.addEventListener('start', () => {
            this.isCurrentlyMoving = true;
        });

        this.controls.addEventListener('end', () => {
            this.isCurrentlyMoving = false;
            this.camera.updateMatrixWorld();
        });

        this.controls.addEventListener('change', () => {
            this.dirty = true;
            this.camera.updateMatrixWorld();
        });

        if (this.controls.domElement) {
            this.boundWheelHandler = this.handleWheelEvent.bind(this);
            this.controls.domElement.addEventListener('wheel', this.boundWheelHandler, { passive: false });
        }
    }

    private extractCurrentState(): CameraState {
        const target: [number, number, number] = this.controls
            ? [this.controls.target.x, this.controls.target.y, this.controls.target.z]
            : this.currentState.target;
        return {
            position: [this.camera.position.x, this.camera.position.y, this.camera.position.z],
            target,
            fov: this.camera.fov,
            near: this.camera.near,
            far: this.camera.far,
            aspect: this.camera.aspect,
            zoom: this.camera.zoom,
        };
    }

    private hasStateChanged(next: CameraState, threshold: number = 0.01): boolean {
        const cur = this.currentState;
        for (let i = 0; i < 3; i++) {
            if (Math.abs(next.position[i] - cur.position[i]) > threshold) return true;
            if (Math.abs(next.target[i] - cur.target[i]) > threshold) return true;
        }
        return (
            Math.abs(next.fov - cur.fov) > threshold ||
            Math.abs(next.aspect - cur.aspect) > threshold ||
            Math.abs(next.near - cur.near) > threshold ||
            Math.abs(next.far - cur.far) > threshold ||
            Math.abs(next.zoom - cur.zoom) > threshold
        );
    }

    private handleWheelEvent(_event: Event): void {
        this.isCurrentlyMoving = true;
        if (this.wheelTimer !== null) clearTimeout(this.wheelTimer);
        this.wheelTimer = window.setTimeout(() => {
            this.isCurrentlyMoving = false;
            this.camera.updateMatrixWorld();
            this.wheelTimer = null;
        }, this.WHEEL_TIMEOUT);
    }
}
