import * as graphl from "@graphl/ide";

// FIXME: types
type GraphlVec3 = {x: number, y: number, z: number};

const customNodes: Record<string, graphl.UserFuncJson> = {
  // FIXME: why is this not in the base lang?
  "Point": {
    inputs: [
      { name: "x", type: "f64" },
      { name: "y", type: "f64" },
      { name: "z", type: "f64" },
    ],
    outputs: [{ name: "", type: "vec3", }],
    kind: "pure",
    tags: ["geom"],
    description: "create a sphere",
    impl: (x: number, y: number, z: number) => ({ x, y, z }),
  },
  "Sphere": {
    inputs: [
      { name: "center", type: "vec3", desc: "point to place the sphere" },
      { name: "radius", type: "f64" },
      { name: "color", type: "string", desc: "color in RGB Hex e.g. ff00ff" },
    ],
    outputs: [],
    //kind: "pure",
    tags: ["geom"],
    description: "create a sphere",
    impl(center: GraphlVec3, radius: number, color: string) {
      viewer.primitives.push({
        type: 'sphere',
        params: { radius },
        position: [center.x, center.y, center.z],
        color: parseInt(color ?? "ffffff", 16)
      });
    },
  },
  "Box": {
    inputs: [
      { name: "position", type: "vec3", desc: "point to place the box" },
      { name: "dimensions", type: "vec3", desc: "width, height, depth" },
      { name: "color", type: "string", desc: "color in RGB Hex e.g. ff00ff" },
    ],
    outputs: [],
    //kind: "pure",
    tags: ["geom"],
    description: "create a sphere",
    impl(position: GraphlVec3, dimensions: GraphlVec3, color: string) {
      viewer.primitives.push({
        type: 'cube',
        params: { width: dimensions.x, height: dimensions.y, depth: dimensions.z },
        position: [position.x, position.y, position.z],
        color: parseInt(color ?? "ffffff", 16)
      });
    },
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
    this.updateScene();
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

  updateScene() {
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

let viewer: ThreeJSViewer;

window.addEventListener('DOMContentLoaded', () => {
  viewer = new ThreeJSViewer();

  const ideCanvas = document.getElementById("left-canvas")

  /** @type {graphl.Ide} */
  let ide;
  const idePromise = graphl.Ide(ideCanvas, {
    allowRunning: false,
    userFuncs: customNodes,
    menus: [
      {
        // FIXME: add "templates" and "recents" for common stuff
        name: "Sync",
        async onClick() {
          // FIXME: use a declarative impl instead of this mutable state stuff
          viewer.primitives = [];
          const program = await ide.compile();
          console.log(program);
          const _result = program.functions.geometry();
          console.log(result);
          viewer.updateScene();
        },
      },
    ],
    // FIXME: must be synced with the default primitives!
    graphs: {
      geometry: {
        fixedSignature: true,
        inputs: [],
        outputs: [
          // {
          //   name: "geometry",
          //   type: "extern",
          //   description: "resulting geometry output",
          // },
        ],
        nodes: [
          {
            id: 1,
            type: "Point",
            inputs: {
              0: { float: -2 },
              1: { float: 0 },
              2: { float: 0 },
            },
          },
          {
            id: 2,
            type: "Point",
            inputs: {
              0: { float: 2 },
              1: { float: 0 },
              2: { float: 0 },
            },
          },
          {
            id: 3,
            type: "Point",
            inputs: {
              0: { float: 1.5 },
              1: { float: 1.5 },
              2: { float: 1.5 },
            },
          },
          {
            id: 4,
            type: "Sphere",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { node: 1, outPin: 0 },
              2: { float: 1 },
              3: { string: "FF4444" },
            },
          },
          {
            id: 5,
            type: "Box",
            inputs: {
              0: { node: 4, outPin: 0 },
              1: { node: 2, outPin: 0 },
              2: { node: 3, outPin: 0 },
              3: { string: "4444FF" },
            },
          },
          {
            id: 6,
            type: "return",
            inputs: {
              0: { node: 5, outPin: 0 },
            },
          }
        ],
      },
    }
  });

  idePromise.then(_ide => ide = _ide);
});

window.updateScene = function(primitives) {
  if (viewer) {
    viewer.updateScene(primitives);
  } else {
    console.error('ThreeJS viewer not initialized yet');
  }
};
