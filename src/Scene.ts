import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { Material, type MaterialType } from './Material';

export interface ObjectTransform {
    id: string;
    name: string;
    position: [number, number, number];
    rotation: [number, number, number];
    scale: [number, number, number];
    visible: boolean;
}

export interface MaterialEdit {
    objectId: string;
    materialType: MaterialType;
    baseColor: [number, number, number];
    lightIntensity?: number;
    refractionIndex?: number;
    surfaceRoughness?: number;
    absorptionCoefficient?: number;
    scatteringCoefficient?: number;
    anisotropyParameter?: number;
}

export interface WGSLVertex {
    pos: number[];
    normal: number[];
    uv: number[];
}

export interface WGSLBVHNode {
    object_type: number;
    sphere_radius: number;
    vertex_start: number;
    vertex_end: number;
    matrix_world: number[][];
    inv_matrix_world: number[][];
    normal_matrix: number[][];
    aabb: { min: [number, number, number]; max: [number, number, number] };
    left: number;
    right: number;
    material_id: number;
}

export interface WGSLSceneData {
    objects: WGSLBVHNode[];
    object_ids: number[];
    vertices: WGSLVertex[];
    materials: any[];
    light_ids: number[];
}

const SMOKE_DENSITY = 0.5;
const SMOKE_ANISOTROPY = 0.5;

export interface ObjectUpdateData {
    position?: { x?: number; y?: number; z?: number };
    rotation?: { x?: number; y?: number; z?: number };
    scale?: { x?: number; y?: number; z?: number };
    visible?: boolean;
    name?: string;
}

const SCENE_CONSTANTS = {
    DEFAULT_BVH_MAX_DEPTH: 30,
    BVH_LEAF_TRIANGLE_LIMIT: 1,

    AABB_INITIAL_MIN: 10000,
    AABB_INITIAL_MAX: -10000,

    DEFAULT_SCALE: [1, 1, 1] as const,
    DEFAULT_OBJECT_NAME: 'untitled',

    // WGSL 側 ObjectType の Mesh と一致させること
    GPU_OBJECT_TYPE_MESH: 3,
};

export class Vertex {
    constructor(
        public pos: THREE.Vector3,
        public normal: THREE.Vector3,
        public uv: THREE.Vector2,
    ) {}
}

/**
 * Axis-Aligned Bounding Box（軸整合バウンディングボックス）
 * BVH で使用するジオメトリの包含領域
 */
export class AABB {
    constructor(public min: THREE.Vector3, public max: THREE.Vector3) {}

    static fromTriangles(triangles: Triangle[]): AABB {
        const min = new THREE.Vector3(
            SCENE_CONSTANTS.AABB_INITIAL_MIN,
            SCENE_CONSTANTS.AABB_INITIAL_MIN,
            SCENE_CONSTANTS.AABB_INITIAL_MIN,
        );
        const max = new THREE.Vector3(
            SCENE_CONSTANTS.AABB_INITIAL_MAX,
            SCENE_CONSTANTS.AABB_INITIAL_MAX,
            SCENE_CONSTANTS.AABB_INITIAL_MAX,
        );

        for (const t of triangles) {
            const bbox = new THREE.Box3().setFromPoints([t.v1.pos, t.v2.pos, t.v3.pos]);
            min.min(bbox.min.clone());
            max.max(bbox.max.clone());
        }
        return new AABB(min, max);
    }
}

/**
 * 3D三角形 (パストレーシングでのレイ-三角形交差判定用)
 */
export class Triangle {
    constructor(public v1: Vertex, public v2: Vertex, public v3: Vertex) {}
}

/**
 * BVH ノード (高速なレイ-メッシュ交差判定のための空間分割)
 */
export class BVHNode {
    aabb: AABB;
    left: BVHNode | null = null;
    right: BVHNode | null = null;
    triangles: Triangle[] = [];

    constructor(aabb: AABB) {
        this.aabb = aabb;
    }
}

/**
 * BVH を構築する。三角形群を空間分割し、高速なレイ交差判定を可能にする。
 */
export function buildBVH(
    triangles: Triangle[],
    depth: number = 0,
    maxDepth: number = SCENE_CONSTANTS.DEFAULT_BVH_MAX_DEPTH,
): BVHNode {
    const aabb = AABB.fromTriangles(triangles);
    const node = new BVHNode(aabb);

    // 終了条件: 三角形数が少ないまたは最大深度に達した
    if (triangles.length <= SCENE_CONSTANTS.BVH_LEAF_TRIANGLE_LIMIT || depth >= maxDepth) {
        node.triangles = triangles;
        return node;
    }

    // 分割軸を決定 (X, Y, Z をサイクリックに交替)
    const splitAxis = depth % 3;

    // 三角形を選択した軸でソート
    triangles.sort((a, b) => {
        const aBox = new THREE.Box3().setFromPoints([a.v1.pos, a.v2.pos, a.v3.pos]);
        const bBox = new THREE.Box3().setFromPoints([b.v1.pos, b.v2.pos, b.v3.pos]);
        return aBox.min.getComponent(splitAxis) - bBox.min.getComponent(splitAxis);
    });

    // 中央で分割
    const mid = Math.floor(triangles.length / 2);
    node.left = buildBVH(triangles.slice(0, mid), depth + 1, maxDepth);
    node.right = buildBVH(triangles.slice(mid), depth + 1, maxDepth);

    return node;
}

export class SceneObject {
    id: string = '';
    objectName: string;

    meshVertices: Vertex[] = [];
    meshTriangles: Triangle[] = [];

    worldTranslation: THREE.Vector3;
    worldRotation: THREE.Euler;
    worldScale: THREE.Vector3;

    accelerationStructure: BVHNode | null = null;
    isVisible: boolean = true;
    material!: Material;
    debugMesh!: THREE.Mesh;

    private constructor() {
        this.objectName = SCENE_CONSTANTS.DEFAULT_OBJECT_NAME;
        this.worldTranslation = new THREE.Vector3();
        this.worldRotation = new THREE.Euler();
        this.worldScale = new THREE.Vector3(...SCENE_CONSTANTS.DEFAULT_SCALE);
    }

    static createMesh(
        vertices: Vertex[],
        worldMatrix: THREE.Matrix4,
        material: Material,
        name: string = SCENE_CONSTANTS.DEFAULT_OBJECT_NAME,
    ): SceneObject {
        const obj = new SceneObject();
        obj.objectName = name;
        obj.meshVertices = vertices;
        obj.material = material;

        // ワールド変換行列を分解して位置/回転/スケールを取得
        const quaternion = new THREE.Quaternion();
        worldMatrix.decompose(obj.worldTranslation, quaternion, obj.worldScale);
        obj.worldRotation.setFromQuaternion(quaternion);

        // 頂点配列から三角形配列を生成 (3 頂点ごとに 1 つの三角形)
        for (let i = 0; i < vertices.length; i += 3) {
            obj.meshTriangles.push(new Triangle(vertices[i], vertices[i + 1], vertices[i + 2]));
        }

        // BVH を構築
        obj.accelerationStructure = buildBVH(obj.meshTriangles, 0, SCENE_CONSTANTS.DEFAULT_BVH_MAX_DEPTH);
        return obj;
    }

    getDefinitions(vertices: Vertex[], materials: any[]): any[] {
        materials.push(this.material.getShaderDefinitions());
        return this.serializeBVHTree(vertices, materials.length - 1);
    }

    private serializeBVHTree(vertices: Vertex[], materialId: number): any[] {
        if (!this.accelerationStructure) return [];

        const serializedData = [];
        const nodeQueue: (BVHNode | null)[] = [this.accelerationStructure];
        const nodeIndices = new Map<BVHNode, number>();
        let currentIndex = 0;

        // ワールド変換行列を構築
        const worldMatrix = new THREE.Matrix4();
        const quaternion = new THREE.Quaternion();
        quaternion.setFromEuler(this.worldRotation);
        worldMatrix.compose(this.worldTranslation, quaternion, this.worldScale);

        // 法線変換用の正規化行列
        const normalMatrix = new THREE.Matrix3();
        normalMatrix.getNormalMatrix(worldMatrix);

        // 逆行列 (レイ変換用)
        const inverseWorldMatrix = new THREE.Matrix4();
        inverseWorldMatrix.copy(worldMatrix).invert();

        // BVH ノードを幅優先探索でシリアライズ
        while (nodeQueue.length > 0) {
            const node = nodeQueue.shift();
            if (!node) continue;

            nodeIndices.set(node, currentIndex);

            const leftIndex = node.left ? (nodeIndices.get(node.left) ?? currentIndex + 1 + nodeQueue.length) : -1;
            const rightIndex = node.right
                ? (nodeIndices.get(node.right) ?? currentIndex + 1 + nodeQueue.length + (node.left ? 1 : 0))
                : -1;

            // リーフノードの三角形をワールド座標に変換して頂点配列に追加
            for (const t of node.triangles) {
                const p1 = t.v1.pos.clone().applyMatrix4(worldMatrix);
                const p2 = t.v2.pos.clone().applyMatrix4(worldMatrix);
                const p3 = t.v3.pos.clone().applyMatrix4(worldMatrix);
                const n1 = t.v1.normal.clone().applyMatrix3(normalMatrix);
                const n2 = t.v2.normal.clone().applyMatrix3(normalMatrix);
                const n3 = t.v3.normal.clone().applyMatrix3(normalMatrix);

                vertices.push(new Vertex(p1, n1, t.v1.uv));
                vertices.push(new Vertex(p2, n2, t.v2.uv));
                vertices.push(new Vertex(p3, n3, t.v3.uv));
            }

            // リーフノードのみマテリアル ID を設定
            const finalMaterialId = (leftIndex === -1 && rightIndex === -1) ? materialId : -1;

            const gpuNode = {
                object_type: SCENE_CONSTANTS.GPU_OBJECT_TYPE_MESH,
                sphere_radius: 0,
                vertex_start: vertices.length - node.triangles.length * 3,
                vertex_end: vertices.length,
                matrix_world: [
                    [worldMatrix.elements[0], worldMatrix.elements[1], worldMatrix.elements[2], worldMatrix.elements[3]],
                    [worldMatrix.elements[4], worldMatrix.elements[5], worldMatrix.elements[6], worldMatrix.elements[7]],
                    [worldMatrix.elements[8], worldMatrix.elements[9], worldMatrix.elements[10], worldMatrix.elements[11]],
                    [worldMatrix.elements[12], worldMatrix.elements[13], worldMatrix.elements[14], worldMatrix.elements[15]],
                ],
                inv_matrix_world: [
                    [inverseWorldMatrix.elements[0], inverseWorldMatrix.elements[1], inverseWorldMatrix.elements[2], inverseWorldMatrix.elements[3]],
                    [inverseWorldMatrix.elements[4], inverseWorldMatrix.elements[5], inverseWorldMatrix.elements[6], inverseWorldMatrix.elements[7]],
                    [inverseWorldMatrix.elements[8], inverseWorldMatrix.elements[9], inverseWorldMatrix.elements[10], inverseWorldMatrix.elements[11]],
                    [inverseWorldMatrix.elements[12], inverseWorldMatrix.elements[13], inverseWorldMatrix.elements[14], inverseWorldMatrix.elements[15]],
                ],
                normal_matrix: [
                    [normalMatrix.elements[0], normalMatrix.elements[1], normalMatrix.elements[2]],
                    [normalMatrix.elements[3], normalMatrix.elements[4], normalMatrix.elements[5]],
                    [normalMatrix.elements[6], normalMatrix.elements[7], normalMatrix.elements[8]],
                ],
                aabb: {
                    min: [node.aabb.min.x, node.aabb.min.y, node.aabb.min.z],
                    max: [node.aabb.max.x, node.aabb.max.y, node.aabb.max.z],
                },
                left: leftIndex,
                right: rightIndex,
                material_id: finalMaterialId,
            };

            serializedData.push(gpuNode);

            if (node.left) nodeQueue.push(node.left);
            if (node.right) nodeQueue.push(node.right);

            currentIndex++;
        }

        return serializedData;
    }
}


// 編集系 API (editObjectTransform / editObjectMaterial) は SceneObject を同期更新したうえで
// dirty フラグを立てるだけ。GPU シーンバッファの再構築は main.ts のフレームループが行う。
export class Scene {
    sceneObjects: SceneObject[] = [];
    dirty: boolean = false;

    // 呼び出し側が事前に obj.id を設定すること
    addObject(sceneObject: SceneObject): void {
        this.sceneObjects.push(sceneObject);
    }

    updateObject(id: string, updates: ObjectUpdateData): void {
        const target = this.sceneObjects.find((obj) => obj.id === id);
        if (!target) {
            console.warn(`[Scene] ` + `SceneObject with id "${id}" not found`);
            return;
        }

        let transformChanged = false;

        if (updates.position) {
            target.worldTranslation.set(
                updates.position.x ?? target.worldTranslation.x,
                updates.position.y ?? target.worldTranslation.y,
                updates.position.z ?? target.worldTranslation.z,
            );
            transformChanged = true;
        }

        if (updates.rotation) {
            target.worldRotation.set(
                updates.rotation.x ?? target.worldRotation.x,
                updates.rotation.y ?? target.worldRotation.y,
                updates.rotation.z ?? target.worldRotation.z,
            );
            transformChanged = true;
        }

        if (updates.scale) {
            target.worldScale.set(
                updates.scale.x ?? target.worldScale.x,
                updates.scale.y ?? target.worldScale.y,
                updates.scale.z ?? target.worldScale.z,
            );
            transformChanged = true;
        }

        if (updates.visible !== undefined) {
            target.isVisible = updates.visible;
            if (target.debugMesh) target.debugMesh.visible = updates.visible;
        }

        if (updates.name !== undefined) {
            target.objectName = updates.name;
        }

        if (transformChanged) {
            if (target.meshTriangles.length > 0) {
                target.accelerationStructure = buildBVH(target.meshTriangles, 0, SCENE_CONSTANTS.DEFAULT_BVH_MAX_DEPTH);
            }
            if (target.debugMesh) {
                target.debugMesh.position.copy(target.worldTranslation);
                target.debugMesh.rotation.copy(target.worldRotation);
                target.debugMesh.scale.copy(target.worldScale);
                target.debugMesh.updateMatrix();
                target.debugMesh.updateMatrixWorld(true);
            }
        }
    }

    updateObjectTransform(id: string, transform: ObjectTransform): void {
        this.updateObject(id, {
            position: { x: transform.position[0], y: transform.position[1], z: transform.position[2] },
            rotation: {
                x: (transform.rotation[0] * Math.PI) / 180,
                y: (transform.rotation[1] * Math.PI) / 180,
                z: (transform.rotation[2] * Math.PI) / 180,
            },
            scale: { x: transform.scale[0], y: transform.scale[1], z: transform.scale[2] },
            visible: transform.visible,
            name: transform.name,
        });
    }

    updateObjectMaterial(id: string, material: Material): void {
        const target = this.sceneObjects.find((obj) => obj.id === id);
        if (!target) {
            console.warn(`[Scene] ` + `SceneObject with id "${id}" not found for material update`);
            return;
        }
        target.material = material;
    }

    get objects(): SceneObject[] {
        return this.sceneObjects;
    }

    getWgslData(): WGSLSceneData {
        const allMaterials: any[] = [];
        const allVertices: Vertex[] = [];

        const processedObjects = this.sceneObjects
            .filter((obj) => obj.isVisible)
            .map((obj) => obj.getDefinitions(allVertices, allMaterials));

        let cumulativeSum = 0;
        const objectStartIndices: number[] = [];
        processedObjects.forEach((data) => {
            objectStartIndices.push(cumulativeSum);
            cumulativeSum += data.length;
        });

        const allObjectNodes = processedObjects.flat();

        const wgslVertices = allVertices.map((v) => ({
            pos: [v.pos.x, v.pos.y, v.pos.z],
            normal: [v.normal.x, v.normal.y, v.normal.z],
            uv: [v.uv.x, v.uv.y],
        }));

        // material_type = 0 (Light) のオブジェクトのインデックスを収集
        const lightObjectIndices: number[] = [];
        for (let i = 0; i < allObjectNodes.length; i++) {
            if (allObjectNodes[i].material_id === -1) continue;
            if (allMaterials[allObjectNodes[i].material_id].material_type === 0) {
                lightObjectIndices.push(i);
            }
        }

        return {
            objects: allObjectNodes,
            object_ids: objectStartIndices,
            light_ids: lightObjectIndices,
            vertices: wgslVertices,
            materials: allMaterials,
        };
    }

    editObjectTransform(transform: ObjectTransform): void {
        const target = this.sceneObjects.find((o) => o.id === transform.id);
        if (!target) {
            console.warn(`[Scene] ` + `object ${transform.id} not found for transform update`);
            return;
        }
        this.updateObjectTransform(transform.id, transform);
        this.dirty = true;
    }

    editObjectMaterial(edit: MaterialEdit): void {
        const target = this.sceneObjects.find((o) => o.id === edit.objectId);
        if (!target) {
            console.warn(`[Scene] ` + `object ${edit.objectId} not found for material update`);
            return;
        }
        const newMaterial = Material.fromProperties({
            materialType: edit.materialType,
            color: edit.baseColor,
            refractionIndex: edit.refractionIndex,
            roughness: edit.surfaceRoughness,
            intensity: edit.lightIntensity,
            sigmaA: edit.absorptionCoefficient,
            sigmaS: edit.scatteringCoefficient,
        });
        target.material = newMaterial;
        target.debugMesh.material = newMaterial.getThreeMaterial();
        this.dirty = true;
    }
}

export interface LoadedSceneObject {
    sceneObject: SceneObject;
    transform: ObjectTransform;
}

export interface LoadedScene {
    objects: LoadedSceneObject[];
    gltfCameraPosition?: [number, number, number];
}

export async function loadGLTFScene(glbPath: string): Promise<LoadedScene> {
    const loader = new GLTFLoader();
    const gltf = await loader.loadAsync(glbPath);

    const result: LoadedScene = { objects: [] };

    const gltfCamera = gltf.cameras?.[0];
    if (gltfCamera) {
        result.gltfCameraPosition = [gltfCamera.position.x, gltfCamera.position.y, gltfCamera.position.z];
    }

    let nextObjectIndex = 0;
    for (const meshChild of gltf.scene.children) {
        if (!(meshChild as THREE.Mesh).isMesh) continue;
        const mesh = meshChild as THREE.Mesh;
        const meshMaterial = mesh.material as THREE.MeshStandardMaterial;
        const geometry = mesh.geometry;
        const positionAttribute = geometry.getAttribute('position') as THREE.BufferAttribute;
        const normalAttribute = geometry.getAttribute('normal') as THREE.BufferAttribute;
        const uvAttribute = geometry.getAttribute('uv') as THREE.BufferAttribute;
        const indices = geometry.index;
        if (!indices) continue;

        const pathTracingMaterial = pickPathTracingMaterial(mesh, meshMaterial);

        const pathTracingVertices: Vertex[] = [];
        for (let i = 0; i < indices.array.length; i++) {
            const vi = indices.array[i];
            pathTracingVertices.push(
                new Vertex(
                    new THREE.Vector3().fromBufferAttribute(positionAttribute, vi),
                    new THREE.Vector3().fromBufferAttribute(normalAttribute, vi),
                    new THREE.Vector2().fromBufferAttribute(uvAttribute, vi),
                ),
            );
        }

        const sceneObject = SceneObject.createMesh(pathTracingVertices, mesh.matrixWorld, pathTracingMaterial, mesh.name);

        const objectId = `object_${nextObjectIndex++}`;
        sceneObject.id = objectId;
        const transform: ObjectTransform = {
            id: objectId,
            name: mesh.name || `Object ${nextObjectIndex}`,
            position: [mesh.position.x, mesh.position.y, mesh.position.z],
            rotation: [
                (mesh.rotation.x * 180) / Math.PI,
                (mesh.rotation.y * 180) / Math.PI,
                (mesh.rotation.z * 180) / Math.PI,
            ],
            scale: [mesh.scale.x, mesh.scale.y, mesh.scale.z],
            visible: mesh.visible,
        };

        sceneObject.debugMesh = buildDebugMesh(mesh, pathTracingVertices, pathTracingMaterial);

        result.objects.push({ sceneObject, transform });
    }

    return result;
}

function pickPathTracingMaterial(mesh: THREE.Mesh, meshMaterial: THREE.MeshStandardMaterial): Material {
    const baseColor: [number, number, number] = [meshMaterial.color.r, meshMaterial.color.g, meshMaterial.color.b];

    if (mesh.name.startsWith('Smoke')) {
        return Material.createSmoke(baseColor, SMOKE_DENSITY, SMOKE_ANISOTROPY);
    }
    const emissive = meshMaterial.emissive;
    if (emissive.r > 0 && emissive.g > 0 && emissive.b > 0 && (meshMaterial.emissiveIntensity ?? 0) > 0) {
        return Material.createLight([emissive.r, emissive.g, emissive.b], meshMaterial.emissiveIntensity);
    }
    if (meshMaterial.metalness === 1) {
        return Material.createSpecular(baseColor);
    }
    const physical = meshMaterial as unknown as { transmission?: number; ior?: number };
    if (physical.transmission === 1) {
        return Material.createDielectrics(baseColor, physical.ior ?? 1.5);
    }
    return Material.createDiffuse(baseColor);
}

function buildDebugMesh(originalMesh: THREE.Mesh, vertices: Vertex[], material: Material): THREE.Mesh {
    const positions = new Float32Array(vertices.length * 3);
    const normals = new Float32Array(vertices.length * 3);
    const uvs = new Float32Array(vertices.length * 2);
    for (let i = 0; i < vertices.length; i++) {
        positions[i * 3] = vertices[i].pos.x;
        positions[i * 3 + 1] = vertices[i].pos.y;
        positions[i * 3 + 2] = vertices[i].pos.z;
        normals[i * 3] = vertices[i].normal.x;
        normals[i * 3 + 1] = vertices[i].normal.y;
        normals[i * 3 + 2] = vertices[i].normal.z;
        uvs[i * 2] = vertices[i].uv.x;
        uvs[i * 2 + 1] = vertices[i].uv.y;
    }

    const geom = new THREE.BufferGeometry();
    geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geom.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
    geom.setAttribute('uv', new THREE.BufferAttribute(uvs, 2));

    const debugMesh = new THREE.Mesh(geom, material.getThreeMaterial() as THREE.Material);
    debugMesh.position.copy(originalMesh.position);
    debugMesh.rotation.copy(originalMesh.rotation);
    debugMesh.scale.copy(originalMesh.scale);
    debugMesh.visible = originalMesh.visible;
    return debugMesh;
}
