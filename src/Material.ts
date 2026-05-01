import * as THREE from 'three';

export interface MaterialProperties {
    materialType: MaterialType;
    color: [number, number, number];
    refractionIndex?: number;
    roughness?: number;
    intensity?: number;
    sigmaA?: number;
    sigmaS?: number;
    anisotropyParameter?: number;
}

const MATERIAL_CONSTANTS = {
    DEFAULT_COLOR: [1, 1, 1] as const,
    DEFAULT_LIGHT_INTENSITY: 10,
    DEFAULT_REFRACTION_INDEX: 2.4,
    DEFAULT_ROUGHNESS: 0.5,
    DEFAULT_ANISOTROPY: 0.0,

    TRANSPARENT_OPACITY: 0.5,
    SPECULAR_ROUGHNESS: 0,
};

export type MaterialType = 'Diffuse' | 'Specular' | 'Dielectrics' | 'GGX' | 'Smoke' | 'Light';
// HG = Henyey-Greenstein 位相関数
export type MediumType = 'None' | 'HG';

export type RGBColor = [number, number, number];

export class Material {
    materialType: MaterialType;
    mediumType: MediumType;
    lightIntensity: number;
    baseColor: RGBColor;
    refractionIndex: number;
    surfaceRoughness: number;
    absorptionCoefficient: number;
    scatteringCoefficient: number;
    anisotropyParameter: number;

    private constructor(type: MaterialType) {
        this.materialType = type;
        this.mediumType = 'None';
        this.baseColor = [...MATERIAL_CONSTANTS.DEFAULT_COLOR];
        this.lightIntensity = MATERIAL_CONSTANTS.DEFAULT_LIGHT_INTENSITY;
        this.refractionIndex = MATERIAL_CONSTANTS.DEFAULT_REFRACTION_INDEX;
        this.surfaceRoughness = MATERIAL_CONSTANTS.DEFAULT_ROUGHNESS;
        this.absorptionCoefficient = 0.0;
        this.scatteringCoefficient = 0.0;
        this.anisotropyParameter = MATERIAL_CONSTANTS.DEFAULT_ANISOTROPY;
    }

    static createDiffuse(color: RGBColor): Material {
        const material = new Material('Diffuse');
        material.baseColor = [...color];
        return material;
    }

    static createSpecular(color: RGBColor): Material {
        const material = new Material('Specular');
        material.baseColor = [...color];
        return material;
    }

    static createDielectrics(color: RGBColor, refractionIndex: number): Material {
        const material = new Material('Dielectrics');
        material.baseColor = [...color];
        material.refractionIndex = refractionIndex;
        return material;
    }

    static createGGX(color: RGBColor, roughness: number): Material {
        const material = new Material('GGX');
        material.baseColor = [...color];
        material.surfaceRoughness = roughness;
        return material;
    }

    static createLight(color: RGBColor, lightIntensity: number): Material {
        const material = new Material('Light');
        material.baseColor = [...color];
        material.lightIntensity = lightIntensity;
        return material;
    }

    static createSmoke(color: RGBColor, absorptionCoeff: number, scatteringCoeff: number): Material {
        const material = new Material('Smoke');
        material.mediumType = 'HG';
        material.baseColor = [...color];
        material.absorptionCoefficient = absorptionCoeff;
        material.scatteringCoefficient = scatteringCoeff;
        material.anisotropyParameter = MATERIAL_CONSTANTS.DEFAULT_ANISOTROPY;
        return material;
    }

    static fromProperties(props: MaterialProperties): Material {
        switch (props.materialType) {
            case 'Diffuse':     return Material.createDiffuse(props.color);
            case 'Specular':    return Material.createSpecular(props.color);
            case 'Dielectrics': return Material.createDielectrics(props.color, props.refractionIndex ?? 1.5);
            case 'GGX':         return Material.createGGX(props.color, props.roughness ?? 0.5);
            case 'Light':       return Material.createLight(props.color, props.intensity ?? 1.0);
            case 'Smoke': {
                const m = Material.createSmoke(props.color, props.sigmaA ?? 0.1, props.sigmaS ?? 0.1);
                if (props.anisotropyParameter !== undefined) m.anisotropyParameter = props.anisotropyParameter;
                return m;
            }
            default: throw new Error(`Unknown material type: ${(props as MaterialProperties).materialType}`);
        }
    }

    getShaderDefinitions() {
        let finalColor = [...this.baseColor];
        if (this.materialType === 'Light') {
            finalColor = [
                this.baseColor[0] * this.lightIntensity,
                this.baseColor[1] * this.lightIntensity,
                this.baseColor[2] * this.lightIntensity
            ];
        }

        // shader 側 enum と一致させること
        const materialTypeMap: Record<MaterialType, number> = {
            "Light": 0,
            "Diffuse": 1,
            "Specular": 2,
            "Dielectrics": 3,
            "GGX": 4,
            "Smoke": 5
        };

        const mediumTypeMap: Record<MediumType, number> = {
            "None": 0,
            "HG": 2
        };

        return {
            material_type: materialTypeMap[this.materialType],
            color: finalColor,
            refraction_index: this.refractionIndex,
            roughness: this.surfaceRoughness,
            medium_type: mediumTypeMap[this.mediumType],
            sigma_a: this.absorptionCoefficient,
            sigma_s: this.scatteringCoefficient,
            g: this.anisotropyParameter,
        };
    }

    getThreeMaterial(): THREE.Material {
        const threeColor = new THREE.Color(this.baseColor[0], this.baseColor[1], this.baseColor[2]);

        switch (this.materialType) {
            case "Light":
                return new THREE.MeshStandardMaterial({
                    emissive: threeColor,
                    emissiveIntensity: this.lightIntensity
                });

            case "Diffuse":
                return new THREE.MeshStandardMaterial({
                    color: threeColor
                });

            case "Specular":
                return new THREE.MeshStandardMaterial({
                    color: threeColor,
                    roughness: MATERIAL_CONSTANTS.SPECULAR_ROUGHNESS
                });

            case "Dielectrics":
                const dielectricMaterial = new THREE.MeshStandardMaterial({
                    color: threeColor,
                    roughness: MATERIAL_CONSTANTS.SPECULAR_ROUGHNESS
                });
                dielectricMaterial.transparent = true;
                dielectricMaterial.opacity = MATERIAL_CONSTANTS.TRANSPARENT_OPACITY;
                return dielectricMaterial;

            case "Smoke":
                const smokeMaterial = new THREE.MeshStandardMaterial({
                    color: threeColor
                });
                smokeMaterial.transparent = true;
                smokeMaterial.opacity = MATERIAL_CONSTANTS.TRANSPARENT_OPACITY;
                return smokeMaterial;

            case "GGX":
                return new THREE.MeshStandardMaterial({
                    color: threeColor,
                    roughness: this.surfaceRoughness
                });

            default:
                return new THREE.MeshStandardMaterial({ color: threeColor });
        }
    }
}
