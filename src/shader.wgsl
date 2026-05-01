// type-definition-start

// WORKGROUP_SIZE_X/Y は @workgroup_size(...) の値と一致させること
// (PathTracer.ts の PATHTRACER_CONSTANTS.WORKGROUP_SIZE_X/Y とも同期)
const WORKGROUP_SIZE_X: u32 = 16u;
const WORKGROUP_SIZE_Y: u32 = 16u;

const pi = 3.14159265358979;
const eps = 0.00001; // 0.00001より小さくするとshadow acneができ始める
const inf = 1000000.0;
const null_hit = HitInfo(false, inf, vec2f(), mat4x4f(),  -1, -1);
const null_material = Material(-1, vec3f(), 0, 0, -1, 0, 0, 0);

struct Settings {
    algorithm: u32,
    resolution: u32,
    spp: u32,
    numtilesx: u32,
    numtilesy: u32,
    tilex: u32,
    tiley: u32,
    mindepth: u32,
    maxdepth: u32,
    light_count: u32  // light_ids の論理的な長さ。バッファは zero-size 防止のため最低 1 要素確保される
}
struct Ray {
    origin: vec3f,
    dir: vec3f,
}
struct Vertex {
    pos: vec3f,
    normal: vec3f,
    uv: vec2f,
}
struct Material {
    // -1: none, 0: light, 1: diffuse, 2: metalic, 3: dielectrics
    material_type: i32,
    color: vec3f,
    refraction_index: f32,
    roughness: f32,

    medium_type: i32, // -1: none, 0: beer lambert
    sigma_a: f32,
    sigma_s: f32,
    g: f32,
}
struct AABB {
    min: vec3f,
    max: vec3f,
}
@group(0) @binding(9) var<storage, read> materials: array<Material>;
struct Object {
    object_type: u32,
    vertex_start: u32,
    vertex_end: u32,
    sphere_radius: f32,
    matrix_world: mat4x4f,
    inv_matrix_world: mat4x4f,
    normal_matrix: mat3x3f,
    material_id: i32,
    // v1: Vertex,
    // v2: Vertex,
    // v3: Vertex,

    left: i32,
    right: i32,
    aabb: AABB,
};
// fn null_object() -> Object {
//     return Object(
//         0, 0, 0, 0, mat4x4f(), mat4x4f(), mat3x3f(), -1, 
//         // Vertex(vec3f(), vec3f(), vec2f()),
//         // Vertex(vec3f(), vec3f(), vec2f()),
//         // Vertex(vec3f(), vec3f(), vec2f()),
//         -1, -1, AABB(vec3f(), vec3f()),
//     );
// }

// fn null_material() -> Material {
//     return Material(-1, vec3f(), 0, 0,0, 0);
// }
struct HitInfo{
    hit: bool,
    t: f32,
    uv: vec2f,
    tbn: mat4x4f,
    object_id: i32,
    triangle_id: i32,
};

struct AreaSample {
    point: vec3f,
    uv: vec2f,
    tbn: mat4x4f,
    pdf: f32,
}

struct BSDFSample {
    scattered: bool,
    wi : vec3f,
    f: vec3f,
    bsdf: vec3f,
    pdf: f32,
}
struct VolumeIntegrationResult {
    result: bool,
    weight: vec3f,
    transmittance: vec3f,
    L: vec3f,
    wo: Ray,
}


struct MediumStack {
    ids: array<i32, 8>,
    // entered_p: array<vec3f, 64>,
    top: i32,
}
@group(0) @binding(0) var outputTex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(1) var<storage, read_write> imgBuffer: array<vec4<f32>>;

@group(0) @binding(3) var<storage, read> objects: array<Object>;

@group(0) @binding(6) var<storage, read> vertices: array<Vertex>;
@group(0) @binding(8) var<storage, read> object_ids: array<u32>;
@group(0) @binding(2) var<storage, read> light_ids: array<u32>;

@group(0) @binding(4) var<uniform> camerapos: vec3f;
@group(0) @binding(5) var<uniform> invCameraMat: mat4x4f;
@group(0) @binding(7) var<uniform> settings: Settings;
// type-definition-end

fn xorshift32(seed: u32) -> u32 {
    var x = seed;
    x ^= (x << 13);
    x ^= (x >> 17);
    x ^= (x << 5);
    return x;
}

fn rand(seed: ptr<function, u32>) -> f32 {
    *seed = xorshift32(*seed);
    return f32(*seed)/ 4294967296.0;
}




fn sphere_center(obj: Object) -> vec3f {
    return vec3f(vertices[obj.vertex_start].pos);
}
// fn triangle_p1(obj: Object) -> vec3f{
//     // let p = obj.matrix_world * vec4f(vertices[obj.vertex_start].pos, 1);
//     // return p.xyz/p.w;
//     return vertices[obj.vertex_start].pos;
// }
// fn triangle_p2(obj: Object) -> vec3f{
//     // let p = obj.matrix_world * vec4f(vertices[obj.vertex_start+1].pos, 1);
//     // return p.xyz/p.w;
//     return vertices[obj.vertex_start+1].pos;
// }
// fn triangle_p3(obj: Object) -> vec3f{
//     // let p = obj.matrix_world * vec4f(vertices[obj.vertex_start+2].pos, 1);
//     // return p.xyz/p.w;
//     return vertices[obj.vertex_start+2].pos;
// }
fn triangle_uv1(obj: Object) -> vec2f{
    return vertices[obj.vertex_start].uv;
}
fn triangle_uv2(obj: Object) -> vec2f{
    return vertices[obj.vertex_start+1].uv;
}
fn triangle_uv3(obj: Object) -> vec2f{
    return vertices[obj.vertex_start+2].uv;
}
fn triangle_normal1(obj: Object) -> vec3f{
    // return normalize(obj.normal_matrix * vertices[obj.vertex_start].normal);
    return normalize(vertices[obj.vertex_start].normal);
}
fn triangle_normal2(obj: Object) -> vec3f{
    // return normalize(obj.normal_matrix * vertices[obj.vertex_start+1].normal);
    return normalize(vertices[obj.vertex_start+1].normal);
}
fn triangle_normal3(obj: Object) -> vec3f{
    // return normalize(obj.normal_matrix * vertices[obj.vertex_start+2].normal);
    return normalize(vertices[obj.vertex_start+2].normal);
}

// fn triangle_p1(obj: Object) -> vec3f{
//     let p = obj.matrix_world * vec4f(obj.v1.pos, 1);
//     return p.xyz/p.w;
// }
// fn triangle_p2(obj: Object) -> vec3f{
//     let p = obj.matrix_world * vec4f(obj.v2.pos, 1);
//     return p.xyz/p.w;
// }
// fn triangle_p3(obj: Object) -> vec3f{
//     let p = obj.matrix_world * vec4f(obj.v3.pos, 1);
//     return p.xyz/p.w;
// }
// fn triangle_uv1(obj: Object) -> vec2f{
//     return obj.v1.uv;
// }
// fn triangle_uv2(obj: Object) -> vec2f{
//     return obj.v2.uv;
// }
// fn triangle_uv3(obj: Object) -> vec2f{
//     return obj.v3.uv;
// }
// fn triangle_normal1(obj: Object) -> vec3f{
//     return normalize(obj.normal_matrix * obj.v1.normal);
// }
// fn triangle_normal2(obj: Object) -> vec3f{
//     return normalize(obj.normal_matrix * obj.v2.normal);
// }
// fn triangle_normal3(obj: Object) -> vec3f{
//     return normalize(obj.normal_matrix * obj.v3.normal);
// }



fn local_to_world_dir(local_vector:vec3f, local_coord:mat4x4f) -> vec3f {
    return (local_coord * vec4f(local_vector, 0)).xyz;
}
fn world_to_local_dir(world_vector:vec3f, local_coord:mat4x4f) -> vec3f {
    return (transpose(local_coord) * vec4f(world_vector, 0)).xyz;
}



fn hit_sphere(ray: Ray, tmin: f32, tmax: f32, object_id: i32) -> HitInfo {
    let object = objects[object_id];
    let center = sphere_center(object);
    let radius = object.sphere_radius;
    let oc = center-ray.origin;
    let a = dot(ray.dir, ray.dir);
    let h =  dot(oc, ray.dir);
    let c = dot(oc, oc) - radius * radius;
    let discriminant = h*h-a*c;
    if (discriminant < 0.0) {
        return null_hit;
    }
    
    let sqrtd = sqrt(discriminant);
    var root = (h-sqrtd)/a;
    if (root <= tmin || tmax <= root) {
        root = (h+sqrtd)/a;
        if (root <= tmin || tmax <= root) {
            return null_hit;
        }
    }

    let point = ray.origin+ root*normalize(ray.dir);
    let normal = normalize(point - center);


    let theta = acos(normal.z);
    var phi = atan2(normal.y, normal.x);
    let uv = vec2f(
        phi/(2.0*pi)+0.5,
        theta/pi,
    );

    let tbn = get_tbn_sphere(object, point, uv);

    return HitInfo(
        true,
        root,
        uv,
        tbn,
        object_id,
        0
    );
}
fn hit_aabb(ray: Ray, tmin:f32, tmax: f32, aabb: AABB) -> bool {
    var t_min = (aabb.min.x - ray.origin.x) / ray.dir.x;
    var t_max = (aabb.max.x - ray.origin.x) / ray.dir.x;
    if (t_min > t_max) {
        let tmp = t_min;
        t_min = t_max;
        t_max = tmp;
    }
    // // aabbのtの領域が入力の[tmin, tmax]の範囲と被っていなければfalseを返す
    if (t_max < tmin || t_min > tmax) {
        return false;
    }

    var ty_min = (aabb.min.y - ray.origin.y) / ray.dir.y;
    var ty_max = (aabb.max.y - ray.origin.y) / ray.dir.y;

    if (ty_min > ty_max) {
        let tmp = ty_min;
        ty_min = ty_max;
        ty_max = tmp;
    }
    if (t_min > ty_max || ty_min > t_max) {
        return false;
    }
    if (ty_min > t_min) {
        t_min = ty_min;
    }
    if (ty_min < t_max) {
        t_max = ty_max;
    }
    // // aabbのtの領域が入力の[tmin, tmax]の範囲と被っていなければfalseを返す
    if (t_max < tmin || t_min > tmax) {
        return false;
    }

    var tz_min = (aabb.min.z - ray.origin.z) / ray.dir.z;
    var tz_max = (aabb.max.z - ray.origin.z) / ray.dir.z;

    if (tz_min > tz_max) {
        let tmp = tz_min;
        tz_min = tz_max;
        tz_max = tmp;
    }
    if (t_min > tz_max || tz_min > t_max) {
        return false;
    }
    if (tz_min > t_min) {
        t_min = tz_min;
    }
    if (tz_max < t_max) {
        t_max = tz_max;
    }

    // // aabbのtの領域が入力の[tmin, tmax]の範囲と被っていなければfalseを返す
    if (t_max < tmin || t_min > tmax) {
        return false;
    }

    return true;
}


fn get_local_ray(ray: Ray, object: Object) -> Ray {
    let tmp = object.inv_matrix_world * vec4f(ray.origin, 1);
    let local_origin = tmp.xyz/tmp.w;
    let local_dir = (object.inv_matrix_world*vec4f(ray.dir, 0)).xyz;
    return Ray(local_origin, local_dir);
}
fn hit_object(ray: Ray, tmin:f32, tmax: f32, object_id: u32) -> HitInfo {

    let root = objects[object_id];
    let root_local_ray = get_local_ray(ray, root);
   
    var nearest = null_hit;
    nearest.t = tmax;
    if (!hit_aabb(root_local_ray, tmin, nearest.t, root.aabb)) {
        return nearest;
    }


    var stack = array<i32, 128>(); // ここ配列の要素数が多いと時間かかる。ボトルネックになってしまうので注意
    for (var i = 0; i < 128; i++) {
        stack[i] = -1;
    }
    var stack_index = 0u;
    stack[stack_index] = i32(object_id);
    stack_index++;



    while (stack_index > 0) {
        stack_index--;
        let node_index = stack[stack_index];
        if (node_index == -1) {
            continue;
        }

        let node = objects[node_index];
       

        if (node.left == -1 && node.right==-1) {
            let hitinfo = hit_single_object(ray, tmin, nearest.t, node_index);
            if (hitinfo.hit == false) {
                continue;
            }
            // if (nearest.hit == true && hitinfo.t > nearest.t) {
            //     continue;
            // }
            nearest = hitinfo;
        } else {
            if (node.left != -1) {
                let left_index = i32(object_id)+node.left;
                // let local_ray = get_local_ray(ray, objects[left_index]); 
                // ここでいちいちlocal rayを計算すると時間がかかる。
                if (hit_aabb(root_local_ray, tmin, nearest.t, objects[left_index].aabb)) {
                    stack[stack_index] = left_index;
                    stack_index++;
                }
            }
            if (node.right != -1) {
                let right_index = i32(object_id)+node.right;
                // let local_ray = get_local_ray(ray, objects[right_index]);
                // ここでいちいちlocal rayを計算すると時間がかかる。
                if (hit_aabb(root_local_ray, tmin, nearest.t, objects[right_index].aabb)) {
                    stack[stack_index] = right_index;
                    stack_index++;
                }
            }
        }
    }
    return nearest;
}

fn hit_single_object(ray: Ray, tmin: f32, tmax: f32, object_id: i32) -> HitInfo {
    if (objects[object_id].object_type==0) {
        return hit_sphere(ray, tmin, tmax, object_id);
    } else if (objects[object_id].object_type==1) {
        return hit_triangle(ray, tmin, tmax, object_id);
    } else if (objects[object_id].object_type==3) {
        return hit_mesh(ray, tmin, tmax, object_id);
    }
    return null_hit;
}

fn hit_triangle_from_vertices(ray: Ray, tmin: f32, tmax: f32, v1: Vertex, v2: Vertex, v3: Vertex, object_id: i32, triangle_id: i32) -> HitInfo {
    let p1 = v1.pos;
    let p2 = v2.pos;
    let p3 = v3.pos;

    let e1 = p2-p1;
    let e2 = p3-p1;
    let ray_cross_e2 = cross(normalize(ray.dir), e2);
    let det = dot(e1, ray_cross_e2);
    // if (det > -eps && det < eps) {
    //     return null_hit;
    // }

    let inv_det = 1.0/det;
    let s = ray.origin - p1;
    let u:f32 = inv_det * dot(s, ray_cross_e2);
    if (u < 0.0 || u > 1.0) {
        return null_hit;
    }
    let s_cross_e1 = cross(s, e1);
    let v:f32 = inv_det * dot(normalize(ray.dir), s_cross_e1);

    if (v < 0.0 || u + v > 1.0) {
         return null_hit;
    }
    let t = inv_det * dot(e2, s_cross_e1);
    if (t < tmin || t > tmax) {
        return null_hit;
    }


    // let uv = v1.uv + u * (v2.uv-v1.uv) + v * (v3.uv-v1.uv);
    let tbn = get_tbn_triangle_from_vertices(v1, v2, v3, ray.origin + t*ray.dir, vec2f(u, v));
    let uv = (1.-u-v)*v1.uv + u*v2.uv + v * v3.uv;

    return HitInfo(
        true,
        t,
        uv,
        tbn,
        object_id,
        triangle_id,
    );
}

fn hit_triangle(ray: Ray, tmin: f32, tmax: f32, object_id: i32) -> HitInfo {
    let object = objects[object_id];
    let p1 = vertices[object.vertex_start+0].pos;
    let p2 = vertices[object.vertex_start+1].pos;
    let p3 = vertices[object.vertex_start+2].pos;

    let e1 = p2-p1;
    let e2 = p3-p1;
    let ray_cross_e2 = cross(ray.dir, e2);
    let det = dot(e1, ray_cross_e2);
    // if (det > -eps && det < eps) {
    //     return null_hit;
    // }

    let inv_det = 1.0/det;
    let s = ray.origin - p1;
    let u = inv_det * dot(s, ray_cross_e2);
    if (u < 0 || u > 1) {
        return null_hit;
    }
    let s_cross_e1 = cross(s.xyz, e1.xyz);
    let v = inv_det * dot(ray.dir, s_cross_e1);

    if (v < 0 || u + v > 1) {
         return null_hit;
    }
    let t = inv_det * dot(e2, s_cross_e1);
    if t < tmin || t > tmax {
        return null_hit;
    }

    let uv = triangle_uv1(object) + u * (triangle_uv2(object)-triangle_uv1(object)) + v * (triangle_uv3(object) - triangle_uv1(object));
    let tbn = get_tbn_triangle(object, ray.origin + t*ray.dir, vec2f(u, v));

    return HitInfo(
        true,
        t,
        uv,
        tbn,
        object_id,
        0
    );
}

fn hit_mesh(ray: Ray, tmin:f32, tmax: f32, object_id :i32) -> HitInfo {
    let vertex_start = objects[object_id].vertex_start;
    let vertex_end = objects[object_id].vertex_end;
    var nearest = null_hit;
    nearest.t = tmax;
    for (var i = 0u; vertex_start+i*3u < vertex_end; i++) {
        let hitinfo = hit_triangle_from_vertices(
            ray, tmin, nearest.t,
            vertices[vertex_start+3u*i], 
            vertices[vertex_start+3u*i+1u],
            vertices[vertex_start+3u*i+2u], 
            object_id, i32(i)
            );
        // if (hitinfo.hit==false || hitinfo.t > nearest.t) {
        //     continue;
        // }
        if (hitinfo.hit==false) {
            continue;
        }
        nearest = hitinfo;

    }
    return nearest;
}



fn bsdf(wi: vec3f, wo: vec3f, uv:vec2f, material: Material) -> vec3f {
    if (material.material_type==1) {
        if (wi.z>0 && wo.z > 0) {
            return material.color/pi;
        } else {
            return vec3f();
        }
    } else if (material.material_type==4) {
        return bsdfGGX(wi, wo, uv, material);
    } else if (material.material_type==100) {
        return bsdf_debug(wi, wo, uv, material);
    }
    return vec3f();
}
fn bsdf_debug(wi: vec3f, wo: vec3f, uv: vec2f, material: Material) -> vec3f {
    if (wo.z < 0.0 || wi.z < 0.0) {
        return vec3f(0, 0, 0);
    }
    if (uv.x > 1 || uv.y > 1) {
        return vec3f(1, 0, 0);
    }
    let xint = i32(floor(5 * uv.x));
    let yint = i32(floor(5 * uv.y));
    if ((xint + yint)%2==0 ) {
        return vec3f(uv.x, uv.y, 0)/pi;
    } else {
        return 0.1*vec3f(uv.x, uv.y, 0)/pi;
        // return vec3f();
    }
    // return vec3f(uv.x, uv.y, 0)/pi;
}

fn pdf(wi: vec3f, wo: vec3f, uv:vec2f, material: Material) -> f32 {
    if (material.material_type==1) {
        return abs(wi.z)/pi;
    } else if (material.material_type==4) {
        return pdfGGX(wi, wo, uv, material);
    } else if (material.material_type==100) {
        if (wo.z < 0.0) {
            return 0;
        } else {
            return abs(wi.z)/pi;
        }
    } else {
        return 0.0;
    }
}

fn sampleF(wo: vec3f, uv: vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    if (material.material_type==1) {
        return sampleDiffuse(wo, uv, material, seed);
    } else if (material.material_type == 2) {
        return sampleSpecular(wo, uv, material, seed);
    } else if (material.material_type == 3) {
        return sampleDielectrics(wo, uv, material, seed);
    } else if (material.material_type == 4) {
        return sampleGGX(wo, uv, material, seed);
    } else if (material.material_type == 5) {
        return BSDFSample(true, -wo, vec3f(1, 1, 1), vec3f(1, 1, 1), 1);
    } else if (material.material_type==100) {
        return sampleDebug(wo, uv, material, seed);
    }
    return BSDFSample(false, vec3f(), vec3f(), vec3f(),  0);
}
fn sampleDiffuse(wo: vec3f, uv:vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    // 内側から侵入
    if (wo.z < 0) {
        return BSDFSample(false, vec3f(), vec3f(), vec3f(), 0.0);
    }
    let tmp = sample_points_on_hemishere_cosine_weighted(seed);
    let wi = tmp.xyz;
    let pdf = tmp.w;
    if (wi.z < 0) {
         return BSDFSample(false, vec3f(), vec3f(), vec3f(), 0.0);
    }

    return BSDFSample(true, vec3f(wi), material.color, material.color/pi, pdf);
}
fn sampleDebug(wo: vec3f, uv: vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    // 内側から侵入
    if (wo.z < 0) {
        return BSDFSample(false, vec3f(), vec3f(), vec3f(), 0);
    }
    let tmp = sample_points_on_hemishere_cosine_weighted(seed);
    let wi = vec3f(tmp.xyz);
    let pdf = tmp.w;
    if (wi.z < 0) {
         return BSDFSample(false, vec3f(), vec3f(), vec3f(), 0.0);
    }

    return BSDFSample(true, wi, bsdf_debug(wi, wo, uv, material)*pi, bsdf_debug(wi, wo, uv, material), 1/pi);
    // ここあっているか後で確認
}


fn sampleSpecular(wo: vec3f, uv: vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    // ここ本当はおかしいのでは？
    // if (wo.z < 0) {
    //     return BSDFSample(false, vec3f(), vec3f(1, 0, 0), vec3f(), 0);
    // }
    return BSDFSample(true, vec3f(-wo.xy, wo.z), material.color, material.color/abs(wo.z), 0);
}


fn sampleDielectrics(wo: vec3f,uv: vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    // let wo = vec3f(normalize(pwo.xyz), 0);
    // let wo = normalize(origwo);
    let parallel = vec3f(wo.x, wo.y, 0,);
    let vertical = vec3f(0, 0, wo.z,);
    let unit_parallel: vec3f = normalize(parallel);
    let unit_vertical: vec3f = normalize(vertical);
    let cos_thetai = abs(length(vertical));
    let sin_thetai = abs(length(parallel));

    if (wo.z >= 0.) {
        // let r0 = pow((1. - material.refraction_index)/(1. + material.refraction_index), 2);
        // let reflectance = r0 + (1. - r0) * pow(1-wo.z, 5);
        
        // let sin_thetai = sqrt(1-cos_thetai*cos_thetai);
        let cos_thetat = sqrt(1- (1/material.refraction_index * sin_thetai) * (1/material.refraction_index * sin_thetai));
        let sqrtrs = (cos_thetai - material.refraction_index * cos_thetat)/
        (cos_thetai + material.refraction_index * cos_thetat);
        let sqrtrp = (cos_thetat - material.refraction_index * cos_thetai) / 
        (cos_thetat + material.refraction_index * cos_thetai);
        let reflectance = 0.5 * (sqrtrs*sqrtrs + sqrtrp*sqrtrp);

        if (rand(seed) < reflectance) { // 外から外への反射成分
            let wi = normalize((-1. * parallel) + vertical);
            // let col = material.color;
            let col = vec3f(1, 1, 1);
            return BSDFSample(true, wi, col, col/abs(wi.z),  0);
        } else { // 外から内への屈折成分
            // let sin_thetat = length(parallel)/material.refraction_index;
            let sin_thetat = sin_thetai / material.refraction_index;
            let cos_thetat = sqrt(1.0 - sin_thetat*sin_thetat);
            let wi = normalize(-cos_thetat * unit_vertical  -sin_thetat * unit_parallel);
            // let col = material.color ;
            let col = material.color / (material.refraction_index*material.refraction_index);
            return BSDFSample(true, wi, col, col/abs(wi.z), 0);
        }
    } else {
        let sin_thetat = material.refraction_index * sin_thetai;
        
        if (sin_thetat > 1.) { // total refrlection
            let wi = normalize((-1. * parallel) + vertical);
            let col = vec3f(1, 1, 1);
            return BSDFSample(true, wi, col, col/abs(wi.z), 0);
        } else {
            let cos_thetat = sqrt(1.0-sin_thetat*sin_thetat);
            let sqrtrs = (material.refraction_index * cos_thetai - cos_thetat) /
            (material.refraction_index * cos_thetai +cos_thetat );
            let sqrtrp = (material.refraction_index * cos_thetat - cos_thetai) /
            (material.refraction_index * cos_thetat +cos_thetai );
            let reflectance = 0.5 * (sqrtrs*sqrtrs + sqrtrp*sqrtrp);

            
            if (rand(seed) < reflectance) { // 内から内への反射成分
                let wi = normalize((-1. * parallel) + vertical);
                let col = vec3f(1, 1, 1);
                return BSDFSample(true, wi, col, col/abs(wi.z), 0);
            } else { // 内から外への屈折成分
                let wi = normalize(-cos_thetat*unit_vertical -sin_thetat * unit_parallel);
                // let col = material.color ;
                let col = material.color * (material.refraction_index*material.refraction_index);
                return BSDFSample(true, wi, col, col/abs(wi.z), 0);
            }
        }
    }
}

fn reflect(incident: vec3f, normal: vec3f) -> vec3f {
    return incident - 2.0 * dot(incident, normal)*normal;
}
fn G1(dot: f32, k: f32) -> f32 {
    return dot/(dot*(1.0-k)+k);
}
fn sampleGGX(wo: vec3f, uv: vec2f, material: Material, seed: ptr<function, u32>) -> BSDFSample {
    let alpha = material.roughness * material.roughness;
    let e1 = rand(seed);
    let e2 = rand(seed);
    
    let phi = 2.0 * pi * e1;
    let cos_theta = sqrt((1.0-e2)/(1.0 + (alpha*alpha - 1.0)*e2));
    let sin_theta = sqrt(1.0-cos_theta*cos_theta);
    let h = vec3f(sin_theta*cos(phi), sin_theta * sin(phi), cos_theta);

    let wi = reflect(-wo, h);

    let dotNL = clamp(wi.z, 0.0, 1.0);
    let dotNV = clamp(wo.z, 0.0, 1.0);
    let dotNH = clamp(h.z, 0.0, 1.0);
    let dotVH = clamp(dot(wo, h), 0.0, 1.0);

    let alpha2 = alpha*alpha;
    let denom = dotNH * dotNH * (alpha2 - 1.0)+1.0;
    let D = alpha2 / (pi * denom*denom);

    let f0 = 1.0;
    let F = f0 + (1.0 - f0) * pow(1.0-dotVH, 5.0);
    let k = alpha/2.0;
   
    let G = G1(dotNL, k)*G1(dotNV, k);
    let bsdf = D * G * F / (4.0 * dotNL * dotNV + 0.0001);

    let pdf_denom = (dotNH * dotNH * (alpha2 - 1.0)) + 1.0;
    let pdf = D * dotNH / (4.0*dot(wo, h));

    let bsdf_cos_theta_i_over_pdf = bsdf*dotNL / pdf;
    return BSDFSample(
        true,
        wi,
        bsdf_cos_theta_i_over_pdf*material.color,
        bsdf*material.color,
        pdf,
    );
}
fn bsdfGGX(wi: vec3f, wo: vec3f, uv: vec2f, material: Material) -> vec3f {
    let alpha = material.roughness * material.roughness;
    let h = normalize(wo+wi);
    let dotNL = clamp(wi.z, 0.0, 1.0);
    let dotNV = clamp(wo.z, 0.0, 1.0);
    let dotNH = clamp(h.z, 0.0, 1.0);
    let dotVH = clamp(dot(wo, h), 0.0, 1.0);

    let alpha2 = alpha*alpha;
    let denom = dotNH * dotNH * (alpha2 - 1.0)+1.0;
    let D = alpha2 / (pi * denom*denom);

    let f0 = 1.0;
    let F = f0 + (1.0 - f0) * pow(1.0-dotVH, 5.0);
    let k = alpha/2.0;
   
    let G = G1(dotNL, k)*G1(dotNV, k);
    return material.color * D * G * F / (4.0 * dotNL * dotNV + 0.0001);
}
fn pdfGGX(wi: vec3f, wo: vec3f, uv: vec2f, material: Material) -> f32 {
    let alpha = material.roughness * material.roughness;
    let h = normalize(wo+wi);
    let dotNH = clamp(h.z, 0.0, 1.0);
    let dotHO = clamp(dot(h, wo), 0.0, 1.0);

    let alpha2 = alpha*alpha;
    let denom = dotNH * dotNH * (alpha2 - 1.0) + 1.0;
    let D = alpha2 / (pi * denom*denom);
    return D * dotNH / (4.0 * dotHO);
}
fn get_triangle_area_from_vertices(p1: vec3f, p2: vec3f, p3: vec3f) -> f32 {
    return 0.5 * length(cross(
        (p2 - p1).xyz,
        (p3 - p1).xyz,
    ));
}
fn get_triangle_area(object: Object) -> f32 {
    let p1 = vertices[object.vertex_start+0].pos;
    let p2 = vertices[object.vertex_start+1].pos;
    let p3 = vertices[object.vertex_start+2].pos;
    return 0.5 * length(cross(
        (p2 - p1).xyz,
        (p3 - p1).xyz,
    ));
}
fn get_area(object_id: i32) -> f32 {
    let object = objects[object_id];
    if (object.object_type==0) {
        return 4*pi * object.sphere_radius*object.sphere_radius;
    } else if (object.object_type==1) {
        return get_triangle_area(object);
    } else if (object.object_type==3) {
        var sum = 0.0;
        let triangle_count =(object.vertex_end-object.vertex_start)/3u; 
        for (var index = 0u; index < triangle_count; index+=1u) {
            sum += get_triangle_area_from_vertices(
                vertices[object.vertex_start+0].pos,
                vertices[object.vertex_start+1].pos,
                vertices[object.vertex_start+2].pos,
                // vertices[object.vertex_start + index*3].pos,
                // vertices[object.vertex_start + index*3+1].pos,
                // vertices[object.vertex_start + index*3+2].pos,
            );
        }
        return sum;
    }
    return 0.0;
}

fn phase_function(wo: vec3f, wi: vec3f, material: Material) -> vec3f {
    if (material.medium_type==0) {
        return vec3f();
    } else if (material.medium_type==1) {
        return uniform_phase(wo, wi, material);
    } else if (material.medium_type==2) {
        return hgphase(wo, wi, material);
    }
    return vec3f();
}
fn sample_phase_function(wo: vec3f, wi: ptr<function, vec3f>, pdf: ptr<function, f32>, material: Material, seed: ptr<function, u32>) {
    if (material.medium_type==0) {
    } else if (material.medium_type==1) {
        sample_uniform_phase(wo, wi, pdf, material, seed);
    } else if (material.medium_type==2) {
        sample_hgphase(wo, wi, pdf, material, seed);
    }
}

fn uniform_phase(wo: vec3f, wi: vec3f, material: Material) -> vec3f {
    return vec3f(1, 1, 1) * 1.0/(4*pi);
}
fn sample_uniform_phase(wo: vec3f, wi: ptr<function, vec3f>, pdf: ptr<function, f32>, material: Material, seed: ptr<function, u32>) {
    *wi = sample_points_on_sphere_uniform(seed).xyz;
    *pdf = 1.0/(4*pi);
}
fn hgphase(wo: vec3f, wi: vec3f, material: Material) -> vec3f {
    let cos_theta = dot(wo, wi);
    return vec3f(1, 1, 1) * (1.0/(4.*pi)) * (1-material.g * material.g) / pow(1 + material.g*material.g + 2 * material.g *cos_theta*cos_theta*cos_theta, 1.5);
}

fn sample_hgphase(wo: vec3f, wi: ptr<function, vec3f>, pdf: ptr<function, f32>, material: Material, seed: ptr<function, u32>) {
    let u = rand(seed);
    var cos_theta = 1.-2.*u;
    if (abs(material.g) > 0.001) {
        cos_theta = -1. / (2.*material.g) * (1+pow(material.g, 2) - pow((1-pow(material.g,2))/(1+material.g - 2 * material.g * u), 2));
    }
    let sin_theta = sqrt(1. - cos_theta*cos_theta);
    let phi = 2 * pi * rand(seed);
    let coordinate_system = create_coordinate_system_from_z(wo);

    let local_wi = vec3f(
        sin_theta * cos(phi),
        sin_theta * sin(phi),
        cos_theta
    );
    *wi = normalize(coordinate_system * local_wi);
    *pdf = (1-material.g * material.g) / pow(1 + material.g*material.g + 2 * material.g *cos_theta*cos_theta*cos_theta, 1.5);

}

fn sample_points_on_sphere_uniform(seed: ptr<function, u32>) -> vec4f {
    let e1 = rand(seed);
    let e2 = rand(seed);

    let theta = acos(1.-(2.0*e1));
    let phi = 2.*pi*e2;
    return vec4f(
        sin(theta)*cos(phi),
        sin(theta)*sin(phi),
        cos(theta),
        1/(4.*pi),
    );
}

fn sample_points_on_hemishere_cosine_weighted(seed: ptr<function, u32>) -> vec4f {
    let e1 = rand(seed);
    let e2 = rand(seed);
    let theta = acos(sqrt(1.-e1));
    let phi = 2.*pi * e2;

    return vec4f(
        sin(theta)*cos(phi),
        sin(theta)*sin(phi),
        cos(theta),
        abs(cos(theta))/pi,
    );
}

fn sample_point_on_object(object_id: u32, seed: ptr<function, u32>) -> AreaSample {
    if (objects[object_id].object_type==0) {
        // return sample_point_on_sphere(object, seed);
    } else if (objects[object_id].object_type==1) {
        return sample_point_on_triangle(object_id, seed);
    } else if (objects[object_id].object_type==3) {
        return sample_point_on_mesh(object_id, seed);
    }
    return AreaSample(
        vec3f(), vec2f(), mat4x4f(), 1.0
    );
}

fn sample_point_on_triangle(object_id: u32, seed: ptr<function, u32>) -> AreaSample {
    let object = objects[object_id];
    var u = rand(seed);
    var v = rand(seed);
    if (u+v > 1){
        u = 1-u;
        v = 1-v;
    }

    let p1 = vertices[object.vertex_start+0].pos;
    let p2 = vertices[object.vertex_start+1].pos;
    let p3 = vertices[object.vertex_start+2].pos;
    let point = p1 + u * (p2 - p1) + v * (p3 - p1);
    let uv = vec2f(u, v);
    return AreaSample(
        point,
        uv,
        get_tbn_triangle(object, point, uv),
        1.0/get_triangle_area(object)
    );
}

fn sample_point_on_sphere(object: Object, seed: ptr<function, u32>) -> AreaSample{
    let e1 = rand(seed);
    let e2 = rand(seed);
    let phi = 2.*pi*e2-pi;
    let theta = acos(1-(e1*e1));
    let p = vec3f(
        cos(2.*pi*e2)*2.*sqrt(e1*(1-e1)),
        sin(2.*pi*e2)*2.*sqrt(e1*(1-e1)),
        1-(2*e1),
    );


    let point = sphere_center(object) + p*object.sphere_radius;

    let uv = vec2f(
        phi/(2.*pi)+0.5,
        theta/pi,
    );

    return AreaSample(
        point,
        uv,
        get_tbn_sphere(object, point, uv),
        1/(4.*pi*object.sphere_radius*object.sphere_radius)
    );

}
fn sample_point_on_mesh(object_id: u32, seed: ptr<function, u32>) -> AreaSample{
    let object = objects[object_id];
    let triangle_count =(object.vertex_end-object.vertex_start)/3u; 
    let index = (*seed) % triangle_count;
    // 三角形からsamplingするためにdummyのtriangleを作る
    var u = rand(seed);
    var v = rand(seed);
    if (u+v > 1){
        u = 1-u;
        v = 1-v;
    }

    let p1 = vertices[object.vertex_start+0].pos;
    let p2 = vertices[object.vertex_start+1].pos;
    let p3 = vertices[object.vertex_start+2].pos;
    let point = p1 + u * (p2 - p1) + v * (p3 - p1);
    let uv = vec2f(u, v);
    let result= AreaSample(
        point,
        uv,
        get_tbn_triangle(object, point, uv),
        1.0/get_triangle_area(object)/f32(triangle_count)
    );
    // var result = sample_point_on_triangle(
        // Object(
        //     1,
        //     object.vertex_start + index * 3,
        //     object.vertex_start + index * 3+3,
        //     0.0,
        //     object.matrix_world,
        //     object.inv_matrix_world,
        //     object.normal_matrix,
        //     object.material,
        //     -1, -1, AABB(vec3f(), vec3f())

        // ),
        // xorshift32(seed)
    // );
    // result.pdf /= f32(triangle_count);
    return result;
}
// fn get_tbn_from_uv(object: Object, uv: vec2f) -> mat4x4f {
//     if (object.object_type==0u) {
//         return tbnSphere(object, uv);
//     } else if (object.object_type==1u) {
//         return tbnTriangle(object, uv);
//     }
//     return mat4x4f();
// }



fn create_coordinate_system_from_z(input: vec3f) -> mat3x3f {
    let z = normalize(input);
    var x = vec3f(0, 0, 0);
    if (abs(z.x) > abs(z.y)) {
        x = vec3f(-z.z, 0.0, z.x);
    } else {
        x = vec3f(0.0, -z.z, z.y);
    }
    x = normalize(x);
    let y = normalize(cross(z, x));
    return mat3x3f(x, y, z);

}
// fn get_tbn(object: Object, p: vec3f, uv: vec2f) -> mat4x4f {
//     if (object.object_type==0u) {
//         return get_tbn_sphere(object, p, uv);
//     } else if (object.object_type==1u) {
//         return get_tbn_triangle(object, p, uv);
//     }
//     return mat4x4f();
// }
fn get_tbn_sphere(object: Object, p: vec3f, uv: vec2f) -> mat4x4f {
    let n = normalize(p - sphere_center(object));
    let theta = acos(n.z);
    var phi = atan2(n.y, n.x);
    
    let tangent = vec4f(
        -sin(phi),
        cos(phi),
        0,
        0
    );
    let bitangent = -vec4f(
        cos(theta)*cos(phi),
        cos(theta)*sin(phi),
        -sin(theta),
        0
    );
    let tbn_normal = vec4f(cross(tangent.xyz, bitangent.xyz), 0);
    return mat4x4f(normalize(tangent), normalize(bitangent), normalize(tbn_normal), vec4f(p, 0));
}

fn get_tbn_triangle_from_vertices(v1: Vertex, v2: Vertex, v3: Vertex, p: vec3f, local_uv: vec2f) -> mat4x4f {
    let e1 = v2.pos - v1.pos;
    let e2 = v3.pos - v1.pos;
    let face_normal = normalize(cross(e1, e2));
    var normal = normalize(cross(e1, e2));
    var tangent = normalize(e1);
    var bitangent = normalize(cross(normal, tangent));
    normal = normalize(
        (1.0-local_uv.x - local_uv.y)*v1.normal + local_uv.x * v2.normal + local_uv.y * v3.normal
        // local_uv.x * v1.normal + local_uv.y * v2.normal + (1-local_uv.x - local_uv.y)*v3.normal
    );
    // if (dot(normal, face_normal)<0.0) {
    //     normal = -normal;
    // }
    tangent = normalize(cross(bitangent, normal));
    bitangent = normalize(cross(normal, tangent));
    return mat4x4f(vec4f(tangent, 0), vec4f(bitangent, 0), vec4f(normal, 0), vec4f(p, 1.));
}

// 注意！ここのuv座標は三角形ごとのuv座標!メッシュ単位でのuv座標ではない！！
fn get_tbn_triangle(object: Object, p: vec3f, uv: vec2f) -> mat4x4f {
    let p1 =  vertices[object.vertex_start+0].pos;
    let p2 =  vertices[object.vertex_start+1].pos;
    let p3 =  vertices[object.vertex_start+2].pos;
    let normal1 = triangle_normal1(object);
    let normal2 = triangle_normal2(object);
    let normal3 = triangle_normal3(object);

    let e1 = p2-p1;
    let e2 = p3-p1;
    let face_normal = normalize(cross(e1, e2));
    var normal = normalize(cross(e1, e2));
    var tangent = normalize(e1);
    var bitangent = cross(normal, tangent);
    normal = normalize((1.0-uv.x-uv.y)*normal1 + uv.x * normal2 + uv.y * normal3);
    if (dot(normal, face_normal)<0.0) {
        normal = -normal;
    }
    tangent = normalize(cross(bitangent, normal));
    bitangent = normalize(cross(normal, tangent));
    return mat4x4f(vec4f(tangent, 0), vec4f(bitangent, 0), vec4f(normal, 0), vec4f(p, 1.));
}



fn get_nearest(ray: Ray, tmin: f32, tmax: f32) -> HitInfo {
     var nearest = null_hit;
     nearest.t = tmax;
     for (var i = 0u; i < arrayLength(&object_ids); i = i + 1u) {
        let hitinfo = hit_object(ray, tmin, nearest.t, object_ids[i]);
        if (hitinfo.hit == false || hitinfo.t > nearest.t) {
            continue;
        }
        nearest = hitinfo;
    }
    return nearest;
}

fn pathtracing(initlal_ray: Ray, seed: ptr<function, u32>) -> vec3f {

    var throughput = vec3f(1., 1., 1.);

    var ray = initlal_ray;


    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {
        var nearest = get_nearest(ray, eps, inf);
        if (nearest.hit == false) {
            return vec3f();
        }
        let nearest_object = objects[nearest.object_id];
        let nearest_mat = materials[nearest_object.material_id];
        if (nearest_mat.material_type==0) {
            let light = objects[nearest.object_id];
            return throughput * nearest_mat.color;
        }
        let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));

        let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return vec3f();
        }

        let world_scattered = normalize(local_to_world_dir(sampled_bsdf.wi, nearest.tbn));
        throughput *= sampled_bsdf.f;
        ray = Ray(
            nearest.tbn[3].xyz,
            normalize(world_scattered)
        );

        var threshold = 1.0;
        if (depth > settings.mindepth) {
            threshold = 0.5;
        }
        if (rand(seed) < threshold){
            throughput /= threshold;
        } else {
            return vec3f();
        }
        
    }

    return vec3f();
}
fn nee(initlal_ray: Ray, seed: ptr<function, u32>) -> vec3f {

    var throughput = vec3f(1., 1., 1.);
    var color = vec3f(0, 0, 0);

    var ray = initlal_ray;

    // var was_last_material_specular = false;

    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {
        // seed = seed * (depth+1);
        var nearest = get_nearest(ray, eps, inf);
        if (nearest.hit==false) {
            return color;
        }

        let nearest_obj = objects[nearest.object_id];
        let nearest_mat = materials[nearest_obj.material_id];
        if (nearest_mat.material_type==0) {
            if (depth==0) {
                return nearest_mat.color;
            }
            // if (was_last_material_specular) {
            //     let distance = length(nearest.tbn[3]-last_tbn[3]);
            //     // let abscos1 = abs(dot(last_tbn[2], ray.dir));
            //     let abscos2 = abs(dot(normalize(nearest.tbn[2]), normalize(nearest.tbn[3] - last_tbn[3])));
            //     // color += throughput * abscos2 / (distance*distance) * nearest.material.color;
            //     // color += throughput *0.5 * abscos2 *nearest.material.color;
            //     was_last_material_specular = false;
            // }
            return color;
        }


        // light sampling (skip entirely if no visible Light objects)
        let shadow_rays_num = 1u;
        if (settings.light_count > 0u) {
        for (var shadow_i = 0u; shadow_i < shadow_rays_num; shadow_i += 1u) {
            let light_i = light_ids[*seed%settings.light_count];
            *seed = xorshift32(*seed);

            let light = objects[light_i];
            let light_mat = materials[light.material_id];
            let sampled_point = sample_point_on_object(light_i, seed);



            let shadow_ray = Ray(nearest.tbn[3].xyz, normalize(sampled_point.point - nearest.tbn[3].xyz));
            let distance = length(sampled_point.point - nearest.tbn[3].xyz);

            let shadow_hit = get_nearest(shadow_ray, eps, distance - eps, );
            if (shadow_hit.hit) {
                continue;
            }

            // let light_tbn = get_tbn(light, sampled_point.point);
            let light_tbn = sampled_point.tbn;
            let wo = normalize(world_to_local_dir(-ray.dir, nearest.tbn));
            let wi = normalize(world_to_local_dir(normalize(sampled_point.point - nearest.tbn[3].xyz), nearest.tbn));


            let bsdf_val = bsdf(wi, wo, nearest.uv, nearest_mat);

            let abscos1 = abs(wi.z);
            // let abscos2 = abs(dot(light_tbn[2], normalize(sampled_point.point - nearest.tbn[3])));
            let abscos2 = abs(dot(light_tbn[2].xyz, normalize(light_tbn[3].xyz - nearest.tbn[3].xyz)));
            let G = abscos1 * abscos2 / (distance*distance);
            let light_areapdf = sampled_point.pdf/f32(settings.light_count);

            color += throughput * bsdf_val * G * light_mat.color /light_areapdf / f32(shadow_rays_num);
        }
        }

        // scatter based on bsdf

        let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));

        let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return color;
        }
        let world_scattered = normalize(local_to_world_dir(sampled_bsdf.wi, nearest.tbn));
        throughput *= sampled_bsdf.f;

        // if (nearest.material.material_type==2 || nearest.material.material_type==3) {
        //     was_last_material_specular = true;
        // }

        ray = Ray(
            nearest.tbn[3].xyz,
            normalize(world_scattered)
        );



       if (nearest_mat.material_type==2 || nearest_mat.material_type==3) {
            let maybelight = get_nearest(ray, eps, inf);
            if (maybelight.hit==true) { 
                let maybelight_mat = materials[objects[maybelight.object_id].material_id];
                if (maybelight_mat.material_type==0) {
                let distance = length(maybelight.tbn[3]-nearest.tbn[3]);
                let abscos2 = abs(dot(normalize(maybelight.tbn[2]), normalize(maybelight.tbn[3] - nearest.tbn[3])));
                let vertex_start = i32(objects[maybelight.object_id].vertex_start);
                let vertex_end = i32(objects[maybelight.object_id].vertex_end);
                let triangle_count = f32(vertex_end-vertex_start)/f32(3);
                let light_pdf = 1.0/get_triangle_area_from_vertices(
                    vertices[vertex_start+maybelight.triangle_id*3].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+1].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+2].pos
                ) / f32(settings.light_count)/ f32(triangle_count);
                color += throughput *maybelight_mat.color/light_pdf/(distance*distance)*abscos2;
                return color;
            }
            }
        }

        if (depth > settings.maxdepth) {
            return color;
        }

        var threshold = 1.0;
        if (depth > settings.mindepth) {
            threshold = 0.5;
        }
        if (rand(seed) < threshold){
            throughput /= threshold;
        } else {
            return color;
        }
       
       
    }
    return vec3f();
}

fn mis(initial_ray: Ray, seed: ptr<function, u32>) -> vec3f {
    // var light_counts:u32 = 0u;
    // var light_indices = array<u32, 512>();


    // for (var i = 0u; i < arrayLength(&objects); i = i + 1u) {
    //     if (objects[i].material.material_type==0 && objects[i].left==-1 && objects[i].right==-1) {
    //         light_indices[light_counts] = i;
    //         light_counts += 1u;
    //     }
    // }

    var throughput = vec3f(1., 1., 1.);
    var color = vec3f(0, 0, 0);

    var ray = initial_ray;

    // var last_hitpoint = vec3f();


    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {
        // seed = seed * (depth+1);
        var nearest = get_nearest(ray, eps, inf);
        if (nearest.hit==false) {
            return color;
        }
        let nearest_obj = objects[nearest.object_id];
        let nearest_mat = materials[nearest_obj.material_id];

        if (nearest_mat.material_type==0) {
            if (depth==0) {
                return nearest_mat.color;
            }
            return color;
        }


        // estimate direct lighting using mis
        let num_direct_lighting_samples = 1u;
        for (var i = 0u; i < num_direct_lighting_samples; i += 1u) {

            if (settings.light_count==0) {
                break;
            }
            // sampling based on light
            {
            
            let light_i = light_ids[*seed%settings.light_count];
            *seed = xorshift32(*seed);

            let light = objects[light_i];
            let light_mat = materials[light.material_id];
            let sampled_point = sample_point_on_object(light_i, seed);



            let shadow_ray = Ray(nearest.tbn[3].xyz, normalize(sampled_point.point - nearest.tbn[3].xyz));
            let distance = length(sampled_point.point - nearest.tbn[3].xyz);

            let shadow_hit = get_nearest(shadow_ray, eps, distance - eps, );
            if (shadow_hit.hit) {
                continue;
            }
            
            let light_tbn = sampled_point.tbn;
            let wo = normalize(world_to_local_dir(-ray.dir, nearest.tbn));
            let wi = normalize(world_to_local_dir(normalize(sampled_point.point - nearest.tbn[3].xyz), nearest.tbn));


            let bsdf_val = bsdf(wi, wo, nearest.uv, nearest_mat);

            let abscos1 = abs(wi.z);
            let abscos2 = abs(dot(light_tbn[2].xyz, normalize(sampled_point.point - nearest.tbn[3].xyz)));

            let light_pdf = sampled_point.pdf/f32(settings.light_count);
            let bsdf_pdf = pdf(wi, wo, nearest.uv, nearest_mat) * abscos2 / (distance*distance);
            let mis_weight = light_pdf/(light_pdf + bsdf_pdf);
            let G = abscos1*abscos2 / (distance*distance);
            color += throughput * mis_weight *  bsdf_val * G * light_mat.color/ light_pdf/f32(num_direct_lighting_samples) ;

            }


            // sampling based on bsdf
            {
                let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));
                let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
                if (sampled_bsdf.scattered==false) {
                    continue;
                }

                let local_scattered = normalize(sampled_bsdf.wi);
                let world_scattered = normalize(local_to_world_dir(local_scattered, nearest.tbn));

                // bsdf samplingして作ったrayがlightに当たるかをチェック。
                let bsdf_ray = Ray(nearest.tbn[3].xyz, world_scattered);
                let maybelight = get_nearest(bsdf_ray, eps, inf);


                //bsdf samplingしたrayが当たらなかった場合
                if (maybelight.hit == false) {
                    continue;
                }
                let maybelight_mat = materials[objects[maybelight.object_id].material_id];
                if (maybelight_mat.material_type != 0) {
                    continue;
                }
                // let cos2 = abs(dot(maybelight.tbn[2], normalize(maybelight.tbn[3] - nearest.tbn[3])));

                // bsdf samplingしたrayがlightに当たった場合。
                // if (nearest.material.material_type==2 || nearest.material.material_type==3 || (nearest.material.material_type==4 && nearest.material.roughness < 1.0)) {
                let vertex_start = i32(objects[maybelight.object_id].vertex_start);
                let vertex_end = i32(objects[maybelight.object_id].vertex_end);
                let triangle_count = f32(vertex_end-vertex_start)/f32(3);
                let light_areapdf = 1.0/get_triangle_area_from_vertices(
                vertices[vertex_start+maybelight.triangle_id*3].pos,
                vertices[vertex_start+maybelight.triangle_id*3+1].pos,
                vertices[vertex_start+maybelight.triangle_id*3+2].pos
                )  / f32(settings.light_count) * f32(triangle_count);
                let abscos1 = abs(sampled_bsdf.wi.z);
                let abscos2 = abs(dot(maybelight.tbn[2].xyz, normalize(maybelight.tbn[3] - nearest.tbn[3]).xyz));
                let distance = length(maybelight.tbn[3].xyz - nearest.tbn[3].xyz);
                let light_dirpdf=light_areapdf /(distance * distance) / abscos2;
                if (nearest_mat.material_type==2 || nearest_mat.material_type==3) {
                    // specular bsdfの場合はbsdf pdfが無限大なのでmis weightは1になる。
                    // specular bsdfの時にbsdf samplingしたrayのlight pdfは？
                    color += throughput * sampled_bsdf.f * maybelight_mat.color/f32(num_direct_lighting_samples);
                } else {
                    


                    let bsdf_pdf = sampled_bsdf.pdf;

// ここなおす！！！！　litht_pdfの計算でmesh中のtriangle_countsとlight_countsの取り扱いを考える。

                    let mis_weight = bsdf_pdf / (bsdf_pdf + light_dirpdf);
                    color += throughput * mis_weight * sampled_bsdf.f*maybelight_mat.color/f32(num_direct_lighting_samples);
                    
                }
            }
        }

        // scatter based on bsdf

        let wo = normalize(world_to_local_dir(-ray.dir, nearest.tbn));
        let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return color;
            // return vec3f(1, 0, 0);
        }

        let local_scattered = sampled_bsdf.wi;
        let world_scattered = normalize(local_to_world_dir(local_scattered, nearest.tbn));
        throughput = throughput*sampled_bsdf.f;

   

        ray = Ray(nearest.tbn[3].xyz, world_scattered);

        var threshold = 1.0;
        if (depth > settings.mindepth) {
            // threshold = min(0.1+(color.x+color.y+color.z)/3, 0.5);
            threshold = 0.5;
        }
        if (rand(seed) < threshold){
            throughput /= threshold;
        } else {
            return color;
        }
    }
    return vec3f();
}


// fn integrate_empty_volume(ray: Ray) -> VolumeIntegrationResult {
// }

fn top_medium_stack(stack: ptr<function, MediumStack>, material_id: ptr<function, i32>) {
    if (empty_medium_stack(stack)) {
        *material_id = -1;
    } else {
        *material_id = (*stack).ids[(*stack).top - 1];
    }
}
fn empty_medium_stack(stack: ptr<function, MediumStack>) -> bool {
    return ((*stack).top == 0);
}
fn push_medium_stack(stack: ptr<function, MediumStack>, id: i32)  {
    (*stack).ids[(*stack).top] = id;
    (*stack).top++;
}
fn pop_medium_stack(stack: ptr<function, MediumStack>) {
    if ((*stack).top > 0) {
        (*stack).top--;
    }
}
fn integrate_volume(medium_stack: ptr<function, MediumStack>, ray: Ray, transmittance: ptr<function, vec3f>, weight: ptr<function, vec3f>, L: ptr<function, vec3f>, wo: ptr<function, Ray>, seed: ptr<function, u32>) -> bool {


    var medium_id = 0;
    top_medium_stack(medium_stack, &medium_id);
    let material = materials[medium_id];
    if (materials[medium_id].medium_type==0) {
        let nearest = get_nearest(ray, eps, inf);
        if (!nearest.hit) {
            return false;
        }
        *transmittance = vec3f(1, 1, 1);
        *weight = vec3f(1, 1, 1);
        *L = vec3f(0, 0, 0);
        *wo = Ray(ray.origin + nearest.t * ray.dir, ray.dir);
        return true;
    } else if (materials[medium_id].medium_type==1) {
        let nearest = get_nearest(ray, eps, inf);
        if (!nearest.hit) {
            return false;
        }
        let sigma_t = material.sigma_a + material.sigma_s;
        
        let xi = rand(seed);
        let t = -log(1.0-xi) / sigma_t;
        if (t < nearest.t) {
            *transmittance = vec3f(1, 1, 1)*exp(-sigma_t*t);
            let pdf = *transmittance * sigma_t;
            *weight = sigma_t / pdf;
            *L = vec3f(0, 0, 0);
            *wo = Ray(ray.origin + t * ray.dir, ray.dir);
            return true;
        } else {
            *transmittance = vec3f(1, 1, 1)*exp(-sigma_t * nearest.t);
            let pdf = *transmittance;
            *weight = 1.0/ pdf;
            *L = vec3f(0, 0, 0);
            *wo = Ray(ray.origin + nearest.t * ray.dir, ray.dir);
            return true;

        }
    }

    //     // return VolumeIntegrationResult(
    //     //     true,
    //     //     vec3f(1, 1, 1),
    //     //     vec3f(1, 1, 1),
    //     //     vec3f(0, 0, 0),
    //     //     Ray(ray.origin + nearest.t * ray.dir, ray.dir)
    //     // );
    //     return true;
    // } else if (materials[medium_id].medium_type==1) {
    //     let transmitence = calc_transmitence(ray, ray.origin+nearest.t * ray.dir, medium_id);      

    //     // return VolumeIntegrationResult(
    //     //     true,
    //     //     vec3f(1, 1, 1),
    //     //     vec3f(1, 1, 1),
    //     //     vec3f(0, 0, 0),
    //     //     Ray(ray.origin + nearest.t * ray.dir, ray.dir)
    //     // );
    //     return true;
    // }
    return false;
   
}

fn calc_transmitence(initial_ray: Ray, p: vec3f, medium_stack_ptr: ptr<function, MediumStack>) -> vec3f {

    var transmitence = vec3f(1, 1, 1);
    var medium_stack = array<i32, 8>();
    var medium_start_stack = array<vec3f, 8>();
    var medium_stack_index = 0;
    var ray = initial_ray;

    for (var i = 0; i < (*medium_stack_ptr).top; i++) {
        medium_stack[i] = (*medium_stack_ptr).ids[i];
        medium_start_stack[i] = initial_ray.origin;
        medium_stack_index ++;
    }

    
    for (var i = 0; i < 32; i++) {
        var nearest = get_nearest(ray, eps, length(p-ray.origin)-eps);
        if (!nearest.hit) {
            break;
        }
        let nearest_obj = objects[nearest.object_id];
        let nearest_mat = materials[nearest_obj.material_id];

        // smoke以外のsurfaceに衝突したらocclusionとみなして0を返す。
        if (nearest_mat.material_type!=5 && nearest_mat.material_type != 3) {
            return vec3f(0, 0, 0);
        }

        let hit_point = ray.origin + nearest.t * ray.dir;

        if (dot(ray.dir, nearest.tbn[2].xyz) < 0.0) {

            medium_stack[medium_stack_index] = nearest_obj.material_id;
            medium_start_stack[medium_stack_index] = hit_point;
            medium_stack_index++;
        } else {
            
            if (medium_stack_index > 0) {
                let medium = materials[medium_stack[medium_stack_index - 1]];
                let last_hitpoint = medium_start_stack[medium_stack_index - 1];
                let dist = length(hit_point - last_hitpoint);
                let sigma_t = medium.sigma_a+medium.sigma_s;
                transmitence *= exp(-sigma_t*dist);
                medium_stack_index--;
            } 
            // else {
            //     // 最初のrayのoriginがmedium中の時の考慮
            //     if (first_medium_id == -1) {
            //         continue;
            //     }
            //     let medium = materials[first_medium_id];
            //     let dist = length(hit_point - initial_ray.origin);
            //     let sigma_t = medium.sigma_a+medium.sigma_s;
            //     transmitence *= exp(-sigma_t*dist);
            // }
        }
        ray.origin += nearest.t * ray.dir;
    }
    // if (medium_stack_index > 0) {
    // let first_medium = materials[first_medium_id];
    for (var i = 0; i < medium_stack_index; i++) {
        let medium = materials[medium_stack[i]];
        let dist = length(p - initial_ray.origin);
        let sigma_t = medium.sigma_a+medium.sigma_s;
        transmitence *= exp(-sigma_t*dist);
    }
    // }
    return transmitence;
}



/*
fn volumepathtracing(initial_ray: Ray, seed: ptr<function ,u32>) -> vec3f {
    var medium_stack  = MediumStack();
    var throughput = vec3f(1., 1., 1.);
    var color = vec3f(0, 0, 0);
    var ray = initial_ray;

    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {

        var nearest = get_nearest(ray, eps, inf);
        if (nearest.hit==false) {
            return color;
        }
        let nearest_mat = &materials[objects[nearest.object_id].material_id];
        if ((*nearest_mat).material_type==0) {
            if (depth==0) {
                return throughput * (*nearest_mat).color;
            }
            return color;
        }


        // light sampling (skip entirely if no visible Light objects)
        let shadow_rays_num = 1u;
        if (settings.light_count > 0u) {
        for (var shadow_i = 0u; shadow_i < shadow_rays_num; shadow_i += 1u) {
            let light_i = light_ids[*seed%settings.light_count];
            *seed = xorshift32(*seed);

            let light = objects[light_i];
            let light_mat = materials[light.material_id];
            let sampled_point = sample_point_on_object(light_i, seed);



            let shadow_ray = Ray(nearest.tbn[3].xyz, normalize(sampled_point.point - nearest.tbn[3].xyz));

            let distance = length(sampled_point.point - nearest.tbn[3].xyz);

            let shadow_hit = get_nearest(shadow_ray, eps, distance - eps, );
            if (shadow_hit.hit) {
                continue;
            }
            var cur_medium_id = -1;
            top_medium_stack(&medium_stack, &cur_medium_id);
            let transmitence = calc_transmitence(shadow_ray, sampled_point.point, cur_medium_id);
            // let transmitence = vec3f(1, 1, 1);

            // let light_tbn = get_tbn(light, sampled_point.point);
            let light_tbn = sampled_point.tbn;
            let wo = normalize(world_to_local_dir(-ray.dir, nearest.tbn));
            let wi = normalize(world_to_local_dir(normalize(sampled_point.point - nearest.tbn[3].xyz), nearest.tbn));


            let bsdf_val = bsdf(wi, wo, nearest.uv, *nearest_mat);

            let abscos1 = abs(wi.z);
            // let abscos2 = abs(dot(light_tbn[2], normalize(sampled_point.point - nearest.tbn[3])));
            let abscos2 = abs(dot(light_tbn[2].xyz, normalize(light_tbn[3].xyz - nearest.tbn[3].xyz)));
            let G = abscos1 * abscos2 / (distance*distance);
            let light_areapdf = sampled_point.pdf/f32(settings.light_count);

            color += throughput * transmitence * bsdf_val * G * light_mat.color /light_areapdf / f32(shadow_rays_num);
        }
        }


        let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));
        let sampled_bsdf = sampleF(wo, nearest.uv, *nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return color;
        }

        let world_scattered = normalize(local_to_world_dir(sampled_bsdf.wi, nearest.tbn));
        throughput *= sampled_bsdf.f;

        ray = Ray(
            nearest.tbn[3].xyz,
            normalize(world_scattered)
        );

        // smokeのboundaryに衝突
        if (nearest_mat.material_type==5) {
            if (dot(ray.dir, nearest.tbn[2].xyz) < 0.0) {
                let medium_material_id = objects[nearest.object_id].material_id;
                push_medium_stack(&medium_stack, medium_material_id);
            } else {
                pop_medium_stack(&medium_stack);
            }
        }
        if (!empty_medium_stack(&medium_stack)) {
            var weight = vec3f();
            var L = vec3f();
            var transmittance = vec3f();
            var wo = Ray();
            let result = integrate_volume(&medium_stack, ray, &transmittance, &weight, &L, &wo, seed);
            if (!result) {
                break;
            }
            color += weight * throughput * L;
            throughput *= transmittance;
            ray = wo;
        }

        if (nearest_mat.material_type==2 || nearest_mat.material_type==3) {
            let maybelight = get_nearest(ray, eps, inf);
            if (maybelight.hit==true) { 
                let maybelight_mat = materials[objects[maybelight.object_id].material_id];
                if (maybelight_mat.material_type==0) {
                let distance = length(maybelight.tbn[3]-nearest.tbn[3]);
                let abscos2 = abs(dot(normalize(maybelight.tbn[2]), normalize(maybelight.tbn[3] - nearest.tbn[3])));
                let vertex_start = i32(objects[maybelight.object_id].vertex_start);
                let vertex_end = i32(objects[maybelight.object_id].vertex_end);
                let triangle_count = f32(vertex_end-vertex_start)/f32(3);
                let light_pdf = 1.0/get_triangle_area_from_vertices(
                    vertices[vertex_start+maybelight.triangle_id*3].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+1].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+2].pos
                ) / f32(settings.light_count)/ f32(triangle_count);
                color += throughput *maybelight_mat.color/light_pdf/(distance*distance)*abscos2;
                return color;
            }
            }
        }

        var threshold = 1.0;
        if (depth > settings.mindepth) {
            threshold = 0.5;
        }
        if (rand(seed) < threshold){
            throughput /= threshold;
        } else {
            return color;
        }
    }
    return vec3f();

}
*/

fn volumepathtracing(initial_ray: Ray, seed: ptr<function ,u32>) -> vec3f {

    var medium_stack = MediumStack();

    var color = vec3f();
    var throughput = vec3f(1., 1., 1.);
    var ray = initial_ray;


    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {

        var nearest = get_nearest(ray, eps, inf);
        var scattered = false;
        var terminated = false;
        // medium中にいるとき
        if (!empty_medium_stack(&medium_stack)) {
            var medium_id = 0;
            top_medium_stack(&medium_stack, &medium_id);
            let medium_material = materials[medium_id];
            let sigma_majorant = medium_material.sigma_a + medium_material.sigma_s; // ここは後できちんと計算するように変える
            let u = rand(seed);

            let dist = -log(1-u)/sigma_majorant;

            if (nearest.hit == true && nearest.t < dist) { // サンプリング距離よりsurfaceの方が近い
                
                ray.origin += nearest.t * ray.dir;
            } else {

                let xi = rand(seed);


                if (xi < medium_material.sigma_a/sigma_majorant) { // absorption
                    terminated = true;
                } else if (xi < (medium_material.sigma_a+medium_material.sigma_s)/sigma_majorant) { // in scattering
                    scattered = true;
                    ray.origin += dist * ray.dir;
                    var wo = vec3f();
                    var pdf = 0.0;
                    sample_phase_function(-ray.dir, &wo, &pdf, medium_material, seed);
                    ray.dir = wo;
                    // ray.dir = sample_points_on_sphere_uniform(seed).xyz;

                } else { // null scattering

                }
            }
            
            // if (nearest.hit == false || nearest.t > dist) { // サンプリングした距離を移動してもsurfaceに衝突しない
            //     let transmittance = exp(-sigma_t * dist);
            //     let trans_pdf = exp(-sigma_t * dist);
            //     throughput *= (transmittance/trans_pdf);
            //     volume_scattered = true;
            //     ray.origin = ray.origin + ray.dir * dist;
            //     ray.dir = sample_points_on_sphere_uniform(seed).xyz;
            // } else { // サンプリングした距離を移動する前にsurfaceに衝突する
            //     // throughput *= transmitence;
            //     let transmittance = exp(-sigma_t * dist);
            //     let trans_pdf = exp(-sigma_t * dist);
            //     throughput *= (transmittance/trans_pdf);
            //     ray.origin = ray.origin + ray.dir * nearest.t;

            //     let nearest_mat = materials[ objects[nearest.object_id].material_id ];
            //     // //　衝突先がlightだった場合、
            //     // if (nearest_mat.type==0) {

            //     // }

            // }
            // seed = xorshift32(xorshift32(seed));
        }

        if (terminated) {
            return color;
        }
        if (scattered) {
            continue;
        }
        
        if (nearest.hit == false) {
            return color;
        }
        let nearest_mat = materials[objects[nearest.object_id].material_id];


        if (nearest_mat.material_type==0) {
            // let light = objects[nearest.object_id];
            return throughput * nearest_mat.color;
        }

      

        let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));
        let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return vec3f();
        }

        let world_scattered = normalize(local_to_world_dir(sampled_bsdf.wi, nearest.tbn));
        throughput *= sampled_bsdf.f;
        ray = Ray(
            nearest.tbn[3].xyz,
            normalize(world_scattered)
        );

          // smokeのboundaryに衝突
        if (nearest_mat.medium_type!=0) {
            if (dot(ray.dir, nearest.tbn[2].xyz) < 0.0) {
                let medium_material_id = objects[nearest.object_id].material_id;
                push_medium_stack(&medium_stack, medium_material_id);

            } else {
                pop_medium_stack(&medium_stack);
                // medium_stack内にこのmediumがあるかどうかを検出してからpopするべき
                // volumeを内包したdielectricsでそのまま反射する場合にもpopされてしまう
            }
        }
        
    }
    return vec3f();
}













// fn calc_transmitence(initial_ray: Ray, p: vec3f, first_medium_id: i32) -> vec3f {
//     let first_origin = initial_ray.origin;
//     var transmitence = vec3f(1, 1, 1);
//     var medium_stack = array<Material, 8>();
//     var medium_start_stack = array<vec3f, 8>();
//     var medium_stack_index = 0;
//     // let nearest = get_nearest(initial_ray, eps, length(p - initial_ray.origin)-eps);
//     var ray = initial_ray;
//     for (var i = 0; i < 32; i++) {
//         // ray.origin += ray.dir;
//         let nearest = get_nearest(ray, eps, length(p - ray.origin)-eps);
//         // if (!nearest.hit) {
//         //     break;
//         // }
//         // let nearest_obj = &(objects[nearest.object_id]);
//         // let nearest_mat = &(materials[(*nearest_obj).material_id]);

//         // // smoke以外のsurfaceに衝突したらocclusionとみなして0を返す。
//         // if ((*nearest_mat).material_type!=5) {
//         //     return vec3f(0, 0, 0);
//         // }
//     }
//     return vec3f(1, 1, 1);
// }




fn volumenee(initial_ray: Ray, seed: ptr<function, u32>) -> vec3f {

    var medium_stack = MediumStack();

    var throughput = vec3f(1., 1., 1.);
    var color = vec3f(0, 0, 0);

    var ray = initial_ray;


    // // // mediumを介した直接光の寄与を加える
    // // let transmittance = vec3f(1, 1, 1);
    // for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {
    //     let nearest = get_nearest(ray, eps, inf);
    //     if (!nearest.hit) {
    //         break;
    //     }
    //     let material = materials[objects[nearest.object_id].material_id];
    //     if (material.material_type==0) {
    //         let hit_point = ray.origin + nearest.t * ray.dir;
    //         return calc_transmitence(initial_ray, hit_point, &medium_stack) * material.color;
    //     } else if (material.material_type==5) {
    //         ray.origin += nearest.t *ray.dir;
    //     }
    // }

    ray = initial_ray;


    for (var depth = 0u; depth < settings.maxdepth; depth = depth + 1u) {
        // seed = seed * (depth+1);
        var nearest = get_nearest(ray, eps, inf);

        var scattered = false;
        var terminated = false;
        // medium中にいるとき
        if (!empty_medium_stack(&medium_stack)) {
            var medium_id: i32 = 0;
            top_medium_stack(&medium_stack, &medium_id);
            let medium_material = materials[medium_id];
            let sigma_t = medium_material.sigma_a + medium_material.sigma_s;
            let u = rand(seed);

            let dist = -log(1-u)/(sigma_t);

            if (nearest.hit && nearest.t < dist) {
                let trans_pdf = exp(-sigma_t * nearest.t);
                let transmittance = exp(-sigma_t * nearest.t);
                ray.origin += nearest.t * ray.dir;
                throughput *= (transmittance/trans_pdf);

            } else {
            let xi = rand(seed);

            if (xi < medium_material.sigma_a/sigma_t) {
                terminated = true;
            } else if (xi < (medium_material.sigma_a+medium_material.sigma_s)/sigma_t) {
            

                let trans_pdf = exp(-sigma_t * dist) * sigma_t;
                let transmittance = exp(-sigma_t * dist);
                // throughput *= medium_material.color * exp(-(medium_material.sigma_a + medium_material.sigma_s) * dist);
                scattered = true;
                let scattered_point = ray.origin + ray.dir * dist;
                // throughput *= (transmittance/trans_pdf);


                // // direct lighting (skip if no visible Light objects)
                if (settings.light_count > 0u) {
                let light_i = light_ids[*seed%settings.light_count];
                *seed = xorshift32(*seed);
                let light = objects[light_i];
                let light_mat = materials[light.material_id];
                let sampled_point = sample_point_on_object(light_i, seed);
                let light_areapdf = sampled_point.pdf/ f32(settings.light_count);

                let shadow_ray = Ray(scattered_point, normalize(sampled_point.point - scattered_point));
                let shadow_transmittance = calc_transmitence(shadow_ray, sampled_point.point, &medium_stack);
                let distance = length(sampled_point.point - scattered_point);
                let abscos2 = abs(dot(normalize(scattered_point - sampled_point.point), sampled_point.tbn[2].xyz));


                // color += throughput * transmitence *light_mat.color / light_areapdf / (distance*distance) ;


                // phase functionの値を考慮する方法
                let phase_val = phase_function(-ray.dir, normalize(sampled_point.point - scattered_point), medium_material);
                color += throughput * phase_val * shadow_transmittance * light_mat.color *abscos2/( light_areapdf * (distance * distance));
                }
                // color += throughput * shadow_transmittance * medium_material.sigma_s * light_mat.color *abscos2/( light_areapdf * (distance * distance));

                ray.origin = scattered_point;

                var wo = vec3f();
                var pdf = 0.0;
                sample_phase_function(-ray.dir, &wo, &pdf, medium_material, seed);
                ray.dir = wo;
                // ray.dir = sample_points_on_sphere_uniform(seed).xyz;

            } else {

            }
            }
        }

        if (nearest.hit==false) {
            return color;
        }
        if (terminated) {
            return color;
        }
        if (scattered) {
            continue;
        }
        let nearest_obj = objects[nearest.object_id];
        let nearest_mat = materials[nearest_obj.material_id];
        if (nearest_mat.material_type==0) {
            if (depth==0) {
                return nearest_mat.color;
            }
            return color;
        }

            


        // light sampling (skip entirely if no visible Light objects)
        let shadow_rays_num = 1u;
        if (settings.light_count > 0u) {
        for (var shadow_i = 0u; shadow_i < shadow_rays_num; shadow_i += 1u) {
            let light_i = light_ids[*seed%settings.light_count];
            *seed = xorshift32(*seed);

            let light = objects[light_i];
            let light_mat = materials[light.material_id];
            let sampled_point = sample_point_on_object(light_i, seed);



            let shadow_ray = Ray(nearest.tbn[3].xyz, normalize(sampled_point.point - nearest.tbn[3].xyz));

            let distance = length(sampled_point.point - nearest.tbn[3].xyz);

            // let shadow_hit = get_nearest(shadow_ray, eps, distance - eps, );
            // if (shadow_hit.hit) {
            //     continue;
            // }
            var cur_medium_id = -1;
            top_medium_stack(&medium_stack, &cur_medium_id);
            let transmitence = calc_transmitence(shadow_ray, sampled_point.point, &medium_stack);

            // let light_tbn = get_tbn(light, sampled_point.point);
            let light_tbn = sampled_point.tbn;
            let wo = normalize(world_to_local_dir(-ray.dir, nearest.tbn));
            let wi = normalize(world_to_local_dir(normalize(sampled_point.point - nearest.tbn[3].xyz), nearest.tbn));


            let bsdf_val = bsdf(wi, wo, nearest.uv, nearest_mat);

            let abscos1 = abs(wi.z);
            // let abscos2 = abs(dot(light_tbn[2], normalize(sampled_point.point - nearest.tbn[3])));
            let abscos2 = abs(dot(light_tbn[2].xyz, normalize(light_tbn[3].xyz - nearest.tbn[3].xyz)));
            let G = abscos1 * abscos2 / (distance*distance);
            let light_areapdf = sampled_point.pdf/f32(settings.light_count);

            color += throughput * transmitence * bsdf_val * G * light_mat.color /light_areapdf / f32(shadow_rays_num);
        }
        }

        // scatter based on bsdf

        let wo = normalize(world_to_local_dir(-normalize(ray.dir), nearest.tbn));
        
        let sampled_bsdf = sampleF(wo, nearest.uv, nearest_mat, seed);
        if (sampled_bsdf.scattered==false) {
            return color;
        }

        let world_scattered = normalize(local_to_world_dir(sampled_bsdf.wi, nearest.tbn));
        throughput *= sampled_bsdf.f;

        ray = Ray(
            nearest.tbn[3].xyz,
            normalize(world_scattered)
        );

        // smokeのboundaryに衝突
        if (nearest_mat.medium_type!=0) {
            // smoke内に透過する場合
            if (dot(ray.dir, nearest.tbn[2].xyz) < 0.0) {
                let medium_material_id = objects[nearest.object_id].material_id;
                // medium_stack[medium_stack_index] = medium_material_id;
                // medium_stack_index++;
                push_medium_stack(&medium_stack, medium_material_id);
            } else { // smoke外に行く場合
                pop_medium_stack(&medium_stack);
            }
        }

        
      
       if (nearest_mat.material_type==2 || nearest_mat.material_type==3 || nearest_mat.material_type==5) {
            let maybelight = get_nearest(ray, eps, inf);
            if (maybelight.hit==true) { 
                let maybelight_mat = materials[objects[maybelight.object_id].material_id];
                if (maybelight_mat.material_type==0) {
                let distance = length(maybelight.tbn[3]-nearest.tbn[3]);
                let abscos2 = abs(dot(normalize(maybelight.tbn[2]), normalize(maybelight.tbn[3] - nearest.tbn[3])));
                let vertex_start = i32(objects[maybelight.object_id].vertex_start);
                let vertex_end = i32(objects[maybelight.object_id].vertex_end);
                let triangle_count = f32(vertex_end-vertex_start)/f32(3);
                let light_pdf = 1.0/get_triangle_area_from_vertices(
                    vertices[vertex_start+maybelight.triangle_id*3].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+1].pos,
                    vertices[vertex_start+maybelight.triangle_id*3+2].pos
                ) / f32(settings.light_count)/ f32(triangle_count);
                color += throughput *maybelight_mat.color/light_pdf/(distance*distance)*abscos2;
                return color;
            }
            }
        }

        if (depth > settings.maxdepth) {
            return color;
        }

        var threshold = 1.0;
        if (depth > settings.mindepth) {
            threshold = 0.5;
        }
        if (rand(seed) < threshold){
            throughput /= threshold;
        } else {
            return color;
        }
    }
    return vec3f();
}




 
@compute @workgroup_size(16, 16, 1)
fn main(@builtin (global_invocation_id) global_id: vec3<u32>, @builtin(local_invocation_id) local_id: vec3<u32>, @builtin(workgroup_id) workgroup_id: vec3<u32>) {
    let width = textureDimensions(outputTex).x;
    let height = textureDimensions(outputTex).y;


    // ===============================
    // インターリーブドレンダリングの座標計算
    // ===============================
    // 
    // 【目的】画像全体が徐々に詳細になるプログレッシブレンダリング
    // タイル全体を順番に処理するのではなく、全タイルの同じ相対位置を同時に処理
    //
    // 【具体例】4x4タイル、600x600画像の場合：
    // - Step 1 (tilex=0, tiley=0): 位置 0,4,8,12,16,20... をレンダリング
    // - Step 2 (tilex=1, tiley=0): 位置 1,5,9,13,17,21... をレンダリング
    // - Step 3 (tilex=2, tiley=0): 位置 2,6,10,14,18,22... をレンダリング
    // - ...16回の実行で1SPP完了
    //
    // 【計算式】
    // base_x/y: ワークグループ内での基本位置 (0〜149 in 600/4=150の範囲)
    // global_x = base_x * numtilesx + tilex
    //          = base_x * 4 + (0〜3)
    // これにより、タイル間隔(4ピクセル)でインターリーブされた座標を生成
    //
    // 【重要】WORKGROUP_SIZE_X/Y定数は@workgroup_size(16, 16, 1)の値と一致していること！
    
    let base_x = workgroup_id.x * WORKGROUP_SIZE_X + local_id.x;
    let base_y = workgroup_id.y * WORKGROUP_SIZE_Y + local_id.y;
    
    // タイル内での相対位置を加算してグローバル座標を計算
    var global_x = base_x * settings.numtilesx + settings.tilex;
    var global_y = base_y * settings.numtilesy + settings.tiley;
    
    if (settings.resolution > 1u) {
        // 低解像度プレビューモード：通常の座標計算
        global_x = (workgroup_id.x * WORKGROUP_SIZE_X + local_id.x) * settings.resolution;
        global_y = (workgroup_id.y * WORKGROUP_SIZE_Y + local_id.y) * settings.resolution;
    }

    // ===============================
    // 境界チェック（重要！）
    // ===============================
    //
    // 【なぜ境界超過が起こるのか】
    // 1. ワークグループは16x16単位でディスパッチされる
    // 2. 画面サイズがワークグループサイズで割り切れない場合、
    //    Math.ceil()により余分なワークグループが作られる
    // 3. インターリーブ計算 (base_x * numtilesx) により座標が拡大される
    //
    // 【具体例】600x600画像、4x4タイル、WORKGROUP_SIZE_X/Y=16の場合：
    // - baseWidth = ceil(600/4) = 150
    // - workgroupsX = ceil(150/16) = 10
    // - 実際のスレッド数: 10*16 = 160 (150を超過)
    // - base_x最大値: 159
    // - global_x最大値: 159*4+3 = 639 (600を超過！)
    //
    // → 境界チェックなしではメモリ破損やクラッシュの原因となる
    
    if (global_x >= width || global_y >= height) {
        return;
    }

    let pixelIndex = global_y * width + global_x;

    var seed = xorshift32(xorshift32(xorshift32(1 + pixelIndex)*(settings.spp+1))+settings.spp+1);

    let pixel_coord = vec2f(f32(global_x) + rand(&seed), f32(global_y)+rand(&seed));
    let ndc = (pixel_coord/vec2f(f32(width), f32(height))*2.0) - vec2f(1.0, 1.0);

    let clipspace = vec4f(ndc.x, -ndc.y, 1.0, 1.0);
    let viewspace = invCameraMat * clipspace;
    let worldspace = vec4f(viewspace.xyz/viewspace.w, 0.0);
    let ray = Ray(vec3f(camerapos), normalize(worldspace.xyz));


    

    seed = xorshift32(xorshift32(seed));
    let prev_color = imgBuffer[pixelIndex].xyz;
    var new_color = vec3f();
    if (settings.algorithm==0) {
        new_color = pathtracing(ray, &seed);
    } else if (settings.algorithm ==1) {
        new_color = nee(ray, &seed);
    } else if (settings.algorithm==2) {
        new_color = mis(ray, &seed);
    } else if (settings.algorithm==3) {
        new_color = volumepathtracing(ray, &seed);
    } else if (settings.algorithm==4) {
        new_color = volumenee(ray, &seed);
    }
    var color = (prev_color * f32(settings.spp)/f32(settings.spp+1) + new_color/f32(settings.spp+1));

    if (settings.resolution==1u) {
        imgBuffer[pixelIndex] = vec4f(color,1.0);
    }


    // gamma correction
    // for (var i = 0; i < 3; i = i + 1) {
    //     if (color[i] < 0) {
    //         color[i] = 0;
    //     }
    // }
    // color = sqrt(color);

    // gamma correction using 2.2
    for (var i = 0; i < 3; i = i + 1) {
        if (color[i] < 0) {
            color[i] = 0;
        } else {
            color[i] = pow(color[i], 1./2.2);
        }
    }

    // blender gamma correction
    // for (var i = 0; i < 3; i = i + 1) {
    //     if (color[i] < 0.0031308) {
    //         if (color[i] < 0) {
    //             color[i] = 0;
    //         } else {
    //             color[i] = color[i] * 12.92;
    //         }
    //         continue;
    //     }
    //     color[i] = (1.055 * pow(color[i], 1./2.4));
    //     color[i] -= 0.055;
    // }
    

    if (settings.resolution==1u) {
        textureStore(outputTex, vec2<i32>(i32(global_x), i32(global_y)), vec4f(color, 1.0));
    } else {
        // 低解像度モードでは複数ピクセルに同じ色を書き込む
        let base_x = (workgroup_id.x * WORKGROUP_SIZE_X + local_id.x) * settings.resolution;
        let base_y = (workgroup_id.y * WORKGROUP_SIZE_Y + local_id.y) * settings.resolution;
        for (var i = 0u; i < settings.resolution; i++) {
            for (var j = 0u; j < settings.resolution; j++) {
                let write_x = base_x + i;
                let write_y = base_y + j;
                if (write_x < width && write_y < height) {
                    textureStore(outputTex, vec2<i32>(i32(write_x), i32(write_y)), vec4f(color, 1.0));
                }
            }
        }
    }
}