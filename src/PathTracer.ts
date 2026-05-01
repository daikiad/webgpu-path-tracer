import {
    getSizeAndAlignmentOfUnsizedArrayElement,
    makeShaderDataDefinitions,
    makeStructuredView,
    StructuredView,
} from 'webgpu-utils';
import { vec3, mat4 } from 'gl-matrix';
import shaderCode from './shader.wgsl';

export interface RenderingConfig {
    width: number;
    height: number;
    algorithm: number;
    resolution: number;
    numtilesx: number;
    numtilesy: number;
    mindepth: number;
    maxdepth: number;
    sppPerDispatch: number;
    useHighPerformanceMode: boolean;
}

export interface RenderState {
    spp: number;
    tilex: number;
    tiley: number;
}

export const INITIAL_RENDER_STATE: RenderState = { spp: 0, tilex: 0, tiley: 0 };

const PATHTRACER_CONSTANTS = {
    // shader.wgsl の @workgroup_size(X, Y, 1) と一致させること
    WORKGROUP_SIZE_X: 16,
    WORKGROUP_SIZE_Y: 16,
    WORKGROUP_SIZE: 16,

    BYTES_PER_FLOAT: 4,
    VEC3_SIZE: 3,
    MAT4_SIZE: 16,

    LOG_FIRST_DISPATCHES: 5,
};

export interface CameraGPUState {
    position: vec3;
    invCameraMatrix: mat4;
}

export interface RenderResult {
    texture: GPUTexture;
    outputBuffer?: GPUBuffer;
}

export class PathTracer {
    private gpuDevice: GPUDevice;
    private config: RenderingConfig;

    // バッファは zero-size 防止のため最低 1 要素確保されるので、shader 側は
    // settings.light_count で本当の長さを参照する。
    private lightCount: number = 0;

    private computePipeline!: GPUComputePipeline;
    private renderPipeline!: GPURenderPipeline;
    private texture!: GPUTexture;
    private accumulationBuffer!: GPUBuffer;
    private clearBuffer!: GPUBuffer;

    private objectsBuffer!: GPUBuffer;
    private materialsBuffer!: GPUBuffer;
    private verticesBuffer!: GPUBuffer;
    private objectIdsBuffer!: GPUBuffer;
    private lightIdsBuffer!: GPUBuffer;

    private settingsBuffer!: GPUBuffer;
    private cameraPosBuffer!: GPUBuffer;
    private invCameraMatrixBuffer!: GPUBuffer;
    
    private bindGroup!: GPUBindGroup;
    private renderBindGroup!: GPUBindGroup;

    private shaderDefs: any;
    private settingsView: StructuredView;

    constructor(device: GPUDevice, config: RenderingConfig) {
        this.gpuDevice = device;
        this.config = config;

        let shaderTypes = '';
        const matches = shaderCode.match(/\/\/ type-definition-start([\s\S]*?)\/\/ type-definition-end/gm);
        if (matches) {
            shaderTypes = matches.join('\n');
        } else {
            console.warn('No shader type definitions found!');
        }

        try {
            this.shaderDefs = makeShaderDataDefinitions(shaderTypes);
            this.settingsView = makeStructuredView(this.shaderDefs.uniforms.settings);
        } catch (error) {
            console.error('Error creating shader definitions:', error);
            throw error;
        }

        this.initializeResources();
    }
    
    private initializeResources() {
        this.computePipeline = this.createComputePipeline();

        this.texture = this.createTexture();
        this.accumulationBuffer = this.createAccumulationBuffer();
        this.clearBuffer = this.createClearBuffer();

        this.settingsBuffer = this.gpuDevice.createBuffer({
            size: this.settingsView.arrayBuffer.byteLength,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        this.cameraPosBuffer = this.gpuDevice.createBuffer({
            size: 3 * Float32Array.BYTES_PER_ELEMENT,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        this.invCameraMatrixBuffer = this.gpuDevice.createBuffer({
            size: 16 * Float32Array.BYTES_PER_ELEMENT,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        this.updateSettings(this.config, INITIAL_RENDER_STATE);
    }
    
    private createComputePipeline(): GPUComputePipeline {
        try {
            const module = this.gpuDevice.createShaderModule({ code: shaderCode });
            module.getCompilationInfo().then(info => {
                info.messages.forEach(msg => {
                    const type = msg.type === 'error' ? console.error : console.warn;
                    type(`Shader compilation ${msg.type} [${msg.lineNum}:${msg.linePos}]: ${msg.message}`);
                });
            });

            const bindGroupLayout = this.gpuDevice.createBindGroupLayout({
                entries: [
                    { binding: 0, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba8unorm' } },
                    { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
                    { binding: 2, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
                    { binding: 3, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
                    { binding: 4, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
                    { binding: 5, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
                    { binding: 6, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
                    { binding: 7, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
                    { binding: 8, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
                    { binding: 9, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
                ],
            });
            const pipelineLayout = this.gpuDevice.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] });
            const pipeline = this.gpuDevice.createComputePipeline({
                layout: pipelineLayout,
                compute: { module, entryPoint: 'main' }
            });
            return pipeline;
        } catch (error) {
            console.error('Error creating compute pipeline:', error);
            throw error;
        }
    }
    
    private createTexture(): GPUTexture {
        return this.gpuDevice.createTexture({
            size: [this.config.width, this.config.height, 1],
            format: "rgba8unorm",
            usage: GPUTextureUsage.STORAGE_BINDING
                | GPUTextureUsage.TEXTURE_BINDING
                | GPUTextureUsage.COPY_DST
                | GPUTextureUsage.COPY_SRC
                | GPUTextureUsage.RENDER_ATTACHMENT,
        });
    }
    
    private createAccumulationBuffer(): GPUBuffer {
        return this.gpuDevice.createBuffer({
            size: this.config.width * this.config.height * 4 * 4,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST
        });
    }
    
    private createClearBuffer(): GPUBuffer {
        const buffer = this.gpuDevice.createBuffer({
            size: this.config.width * this.config.height * 4 * 4,
            usage: GPUBufferUsage.COPY_SRC,
            mappedAtCreation: true,
        });
        const zeroArray = new Float32Array(buffer.getMappedRange());
        zeroArray.fill(0.0);
        buffer.unmap();
        return buffer;
    }
    
    private createStructuredArrayBuffer(definition: any, arrayLength: number): GPUBuffer {
        // WebGPU は size 0 の storage buffer を bind できない。空のとき (例: ユーザが
        // 全 Light を invisible にした) は最低 1 要素分のバイトを確保する。shader 側は
        // settings.light_count などの side-channel で「論理的な長さ」を知る。
        const elementSize = getSizeAndAlignmentOfUnsizedArrayElement(definition).size;
        const safeLength = Math.max(arrayLength, 1);
        return this.gpuDevice.createBuffer({
            size: safeLength * elementSize,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });
    }
    
    private writeStructuredArrayToBuffer(buffer: GPUBuffer, definition: any, array: any) {
        const structuredView = makeStructuredView(
            definition,
            new ArrayBuffer(array.length * getSizeAndAlignmentOfUnsizedArrayElement(definition).size)
        );
        structuredView.set(array);
        this.gpuDevice.queue.writeBuffer(buffer, 0, structuredView.arrayBuffer);
    }
    
    private createBindGroup(): GPUBindGroup {
        return this.gpuDevice.createBindGroup({
            layout: this.computePipeline.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: this.texture.createView() },
                { binding: 1, resource: { buffer: this.accumulationBuffer } },
                { binding: 2, resource: { buffer: this.lightIdsBuffer } },
                { binding: 3, resource: { buffer: this.objectsBuffer } },
                { binding: 4, resource: { buffer: this.cameraPosBuffer } },
                { binding: 5, resource: { buffer: this.invCameraMatrixBuffer } },
                { binding: 6, resource: { buffer: this.verticesBuffer } },
                { binding: 7, resource: { buffer: this.settingsBuffer } },
                { binding: 8, resource: { buffer: this.objectIdsBuffer } },
                { binding: 9, resource: { buffer: this.materialsBuffer } },
            ]
        });
    }

    updateScene(sceneData: any) {
        this.objectsBuffer?.destroy();
        this.materialsBuffer?.destroy();
        this.objectIdsBuffer?.destroy();
        this.lightIdsBuffer?.destroy();
        this.verticesBuffer?.destroy();

        this.lightCount = sceneData.light_ids.length;

        this.objectsBuffer = this.createStructuredArrayBuffer(this.shaderDefs.storages.objects, sceneData.objects.length);
        this.materialsBuffer = this.createStructuredArrayBuffer(this.shaderDefs.storages.materials, sceneData.materials.length);
        this.objectIdsBuffer = this.createStructuredArrayBuffer(this.shaderDefs.storages.object_ids, sceneData.object_ids.length);
        this.lightIdsBuffer = this.createStructuredArrayBuffer(this.shaderDefs.storages.light_ids, sceneData.light_ids.length);
        this.verticesBuffer = this.createStructuredArrayBuffer(this.shaderDefs.storages.vertices, sceneData.vertices.length);

        this.writeStructuredArrayToBuffer(this.objectsBuffer, this.shaderDefs.storages.objects, sceneData.objects);
        this.writeStructuredArrayToBuffer(this.materialsBuffer, this.shaderDefs.storages.materials, sceneData.materials);
        this.writeStructuredArrayToBuffer(this.objectIdsBuffer, this.shaderDefs.storages.object_ids, sceneData.object_ids);
        this.writeStructuredArrayToBuffer(this.lightIdsBuffer, this.shaderDefs.storages.light_ids, sceneData.light_ids);
        this.writeStructuredArrayToBuffer(this.verticesBuffer, this.shaderDefs.storages.vertices, sceneData.vertices);

        this.bindGroup = this.createBindGroup();
    }

    updateCamera(cameraState: CameraGPUState) {
        const cameraPositionArray = new Float32Array(cameraState.position);
        const inverseCameraMatrixArray = new Float32Array(cameraState.invCameraMatrix);

        this.gpuDevice.queue.writeBuffer(this.cameraPosBuffer, 0, cameraPositionArray.buffer);
        this.gpuDevice.queue.writeBuffer(this.invCameraMatrixBuffer, 0, inverseCameraMatrixArray.buffer);
    }

    updateSettings(config: RenderingConfig, state: RenderState) {
        this.config = config;
        this.settingsView.set({ ...config, ...state, light_count: this.lightCount });
        this.gpuDevice.queue.writeBuffer(this.settingsBuffer, 0, this.settingsView.arrayBuffer);
    }

    clearAccumulation() {
        const commandEncoder = this.gpuDevice.createCommandEncoder();
        commandEncoder.copyBufferToBuffer(
            this.clearBuffer,
            0,
            this.accumulationBuffer,
            0,
            this.clearBuffer.size
        );
        const colorAttachment: GPURenderPassColorAttachment = {
            view: this.texture.createView(),
            loadOp: 'clear',
            clearValue: { r: 0, g: 0, b: 0, a: 0 },
            storeOp: 'store',
        };
        const passEncoder = commandEncoder.beginRenderPass({ colorAttachments: [colorAttachment] });
        passEncoder.end();
        this.gpuDevice.queue.submit([commandEncoder.finish()]);
    }

    render(): RenderResult {
        const commandEncoder = this.gpuDevice.createCommandEncoder();
        const passEncoder = commandEncoder.beginComputePass();

        passEncoder.setPipeline(this.computePipeline);
        passEncoder.setBindGroup(0, this.bindGroup);

        const workgroupDimensionX = PATHTRACER_CONSTANTS.WORKGROUP_SIZE_X;
        const workgroupDimensionY = PATHTRACER_CONSTANTS.WORKGROUP_SIZE_Y;
        let workgroupsX, workgroupsY;
        if (this.config.resolution === 1) {
            // インターリーブドレンダリング: 画面全体をタイル数で割ったベース領域だけ dispatch し、
            // shader 側がタイル内の特定位置のピクセルのみ書き込む
            const baseWidth = Math.ceil(this.config.width / this.config.numtilesx);
            const baseHeight = Math.ceil(this.config.height / this.config.numtilesy);

            workgroupsX = Math.ceil(baseWidth / workgroupDimensionX);
            workgroupsY = Math.ceil(baseHeight / workgroupDimensionY);

            passEncoder.dispatchWorkgroups(workgroupsX, workgroupsY, 1);
        } else {
            workgroupsX = Math.ceil(this.config.width / workgroupDimensionX / this.config.resolution);
            workgroupsY = Math.ceil(this.config.height / workgroupDimensionY / this.config.resolution);
            passEncoder.dispatchWorkgroups(workgroupsX, workgroupsY, 1);
        }

        passEncoder.end();
        this.gpuDevice.queue.submit([commandEncoder.finish()]);

        return { texture: this.texture };
    }

    get device(): GPUDevice {
        return this.gpuDevice;
    }

}
