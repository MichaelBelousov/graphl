import * as graphl from "@graphl/ide";

const customNodes: Record<string, graphl.UserFuncJson> = {
  "VisibleInViewport": {
    inputs: [{ name: "element", type: "u64" }],
    outputs: [{ name: "", type: "bool" }],
    kind: "pure",
    tags: ["iTwin"],
    description: "true if the viewport has this element visible at export time",
  },

  "ProjectCenter": {
    inputs: [],
    outputs: [{ name: "", type: "vec3" }],
    kind: "pure",
    tags: ["iTwin"],
    description: "get the center of the project extents in iTwin coordinates",
  },

  "Category": {
    inputs: [{ name: "element", type: "u64" }],
    outputs: [{ name: "", type: "u64" }],
    tags: ["iTwin"],
    description: "get the id of the category for a geometric element",
    kind: "pure",
  },

  "Parent": {
    inputs: [{ name: "element", type: "u64" }],
    outputs: [{ name: "", type: "u64" }],
    tags: ["iTwin"],
    description: "get the id of the parent of an element",
    kind: "pure",
  },

  "UserLabel": {
    inputs: [{ name: "element", type: "u64" }],
    outputs: [{ name: "", type: "string" }],
    kind: "pure",
    tags: ["iTwin"],
    description: "get the user label of an element",
  },
};



const defaultPrimitives = [
  {
    type: 'sphere',
    params: { radius: 1 },
    position: [-2, 0, 0],
    color: 0xff4444
  },
  {
    type: 'cube',
    params: { width: 1.5, height: 1.5, depth: 1.5 },
    position: [2, 0, 0],
    color: 0x4444ff
  }
];

class ThreeJSViewer {
  constructor() {
    this.scene = null;
    this.camera = null;
    this.renderer = null;
    this.controls = null;
    this.currentObjects = [];
    this.primitives = [...defaultPrimitives];

    this.init();
    this.animate();
  }

  init() {
    const canvas = document.getElementById('three-canvas');
    const rightPanel = canvas.parentElement;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x222222);

    this.camera = new THREE.PerspectiveCamera(
      75, 
      rightPanel.clientWidth / rightPanel.clientHeight, 
      0.1, 
      1000
    );
    this.camera.position.set(5, 5, 5);
    this.camera.lookAt(0, 0, 0);

    this.renderer = new THREE.WebGLRenderer({ 
      canvas: canvas,
      antialias: true 
    });
    this.renderer.setSize(rightPanel.clientWidth, rightPanel.clientHeight);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    const ambientLight = new THREE.AmbientLight(0x404040, 0.6);
    this.scene.add(ambientLight);

    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight.position.set(10, 10, 5);
    directionalLight.castShadow = true;
    directionalLight.shadow.mapSize.width = 2048;
    directionalLight.shadow.mapSize.height = 2048;
    this.scene.add(directionalLight);

    this.controls = new THREE.OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.05;
    this.controls.enableZoom = true;
    this.controls.enableRotate = true;
    this.controls.enablePan = true;

    window.addEventListener('resize', () => this.onWindowResize());
  }

  onWindowResize() {
    const rightPanel = document.querySelector('.right-panel');
    this.camera.aspect = rightPanel.clientWidth / rightPanel.clientHeight;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(rightPanel.clientWidth, rightPanel.clientHeight);
  }

  clearScene() {
    this.currentObjects.forEach(obj => {
      this.scene.remove(obj);
      if (obj.geometry) obj.geometry.dispose();
      if (obj.material) obj.material.dispose();
    });
    this.currentObjects = [];
  }

  drawScene() {
    this.clearScene();

    this.primitives.forEach(primitive => {
      const mesh = this.createMeshFromPrimitive(primitive);
      if (mesh) {
        this.scene.add(mesh);
        this.currentObjects.push(mesh);
      }
    });
  }

  createMeshFromPrimitive(primitive) {
    let geometry;
    const { type, params = {}, position = [0, 0, 0], rotation = [0, 0, 0], scale = [1, 1, 1], color = 0x00ff88 } = primitive;

    switch (type.toLowerCase()) {
      case 'sphere':
        geometry = new THREE.SphereGeometry(
          params.radius || 1,
          params.widthSegments || 32,
          params.heightSegments || 16
        );
        break;
      case 'cube':
      case 'box':
        geometry = new THREE.BoxGeometry(
          params.width || 1,
          params.height || 1,
          params.depth || 1
        );
        break;
      case 'cylinder':
        geometry = new THREE.CylinderGeometry(
          params.radiusTop || 1,
          params.radiusBottom || 1,
          params.height || 1,
          params.radialSegments || 8
        );
        break;
      case 'cone':
        geometry = new THREE.ConeGeometry(
          params.radius || 1,
          params.height || 1,
          params.radialSegments || 8
        );
        break;
      case 'plane':
        geometry = new THREE.PlaneGeometry(
          params.width || 1,
          params.height || 1
        );
        break;
      case 'torus':
        geometry = new THREE.TorusGeometry(
          params.radius || 1,
          params.tube || 0.4,
          params.radialSegments || 8,
          params.tubularSegments || 6
        );
        break;
      default:
        console.warn(`Unknown primitive type: ${type}`);
        return null;
    }

    const material = new THREE.MeshLambertMaterial({ color: color });
    const mesh = new THREE.Mesh(geometry, material);

    mesh.position.set(...position);
    mesh.rotation.set(...rotation);
    mesh.scale.set(...scale);
    mesh.castShadow = true;
    mesh.receiveShadow = true;

    return mesh;
  }

  animate() {
    requestAnimationFrame(() => this.animate());

    this.controls.update();

    // NOTE: this was generated, but no need really
    // this.currentObjects.forEach((obj, index) => {
    //     obj.rotation.x += 0.01;
    //     obj.rotation.y += 0.01 * (index % 2 === 0 ? 1 : -1);
    // });

    this.renderer.render(this.scene, this.camera);
  }
}

let viewer: HTMLCanvasElement;

window.addEventListener('DOMContentLoaded', () => {
  viewer = new ThreeJSViewer();

  const ideCanvas = document.getElementById("left-canvas")
  void graphl.Ide(ideCanvas, {
    allowRunning: false,
    userFuncs: customNodes,
    menus: [
      {
        // FIXME: add "templates" and "recents" for common stuff
        name: "Sync",
        onClick() {

        },
      },
    ],
    graphs: {
      geometry: {
        fixedSignature: true,
        inputs: [],
        outputs: [
          {
            name: "geometry",
            type: "extern",
            description: "resulting geometry output",
          },
        ],
        nodes: [
          {
            id: 1,
            type: "return",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { bool: false },
            },
          }
        ],
      },
    }
  });
});

window.drawScene = function(primitives) {
  if (viewer) {
    viewer.drawScene(primitives);
  } else {
    console.error('ThreeJS viewer not initialized yet');
  }
};
