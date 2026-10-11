// The site's hero: the app icon's mascot (Design/render-mascot.swift, rebuilt here in three.js) bobbing on the water at
// the pier, with the boxes its agents run on floating around it. Every few seconds an agent on a box needs you: its dot
// turns orange, a bubble asks, the answer sends it back to work and the mascot hops. The lantern on its hat sweeps
// like a lighthouse at night. `npm run build` bundles this into site/assets/hero.js; without WebGL, or before it is
// ready, the page shows the picture of the mascot instead.
import {
  AdditiveBlending, BackSide, CanvasTexture, Color, CubicBezierCurve3, CurvePath, CylinderGeometry, DirectionalLight,
  DoubleSide, Fog, Group, HemisphereLight, MathUtils, Mesh, MeshStandardMaterial, NeutralToneMapping, PCFShadowMap, Plane,
  PerspectiveCamera, PlaneGeometry, PMREMGenerator, PointLight, Raycaster, RingGeometry, Scene, ShaderMaterial,
  SphereGeometry, SRGBColorSpace, TorusGeometry, TubeGeometry, Vector2, Vector3, WebGLRenderer,
  BufferGeometry, Float32BufferAttribute, Points, PointsMaterial,
} from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

// Light is a peach sunrise over a teal sea (the icon's background); dark is the harbour at night.
const PALETTES = {
  light: {
    skyTop: '#f6c09a', skyHorizon: '#ffeedc', sun: '#fff4dc', sunDir: [0.55, 0.16, -1], glow: 0.5,
    seaDeep: '#2f8f8c', seaShallow: '#86cfc6', seaSpec: 0.85,
    hemiSky: '#ffe6cf', hemiGround: '#7cc3b9', hemi: 1.15, key: '#fff4e8', keyI: 2.3, rim: '#ffd7b3', rimI: 1.4,
    env: 0.5, lantern: 1.6, pomGlow: 1.1, beam: 0.1, stars: 0,
  },
  dark: {
    skyTop: '#050913', skyHorizon: '#1c2b47', sun: '#dbe6ff', sunDir: [0.5, 0.22, -1], glow: 0.35,
    seaDeep: '#071526', seaShallow: '#1a3a58', seaSpec: 0.7,
    hemiSky: '#43577f', hemiGround: '#0b1828', hemi: 0.75, key: '#c8d6ff', keyI: 0.7, rim: '#86a8ff', rimI: 1.1,
    env: 0.16, lantern: 5.5, pomGlow: 1.6, beam: 0.5, stars: 1,
  },
};

// The app's agent states (Theme.swift): orange needs you, blue working, green done.
const STATE = { needs: '#f5a35c', working: '#4a99fa', done: '#4cc38a', idle: '#5d6470' };

const ASKS = [
  { agent: 'Claude', cmd: 'Bash(npm test)' },
  { agent: 'Codex', cmd: 'Edit(src/api.ts)' },
  { agent: 'Claude', cmd: 'Bash(git push)' },
  { agent: 'Codex', cmd: 'Bash(pnpm build)' },
];

function clay(color, roughness = 0.85) {
  return new MeshStandardMaterial({ color, roughness, metalness: 0 });
}

// The sea's swell, the same in JavaScript (things floating on it) and in the sea's shader.
function swell(x, z, t) {
  return 0.06 * Math.sin(x * 0.9 + t * 1.1) + 0.045 * Math.sin(z * 1.3 - t * 0.9)
    + 0.025 * Math.sin((x + z) * 2.1 + t * 1.7) + 0.012 * Math.sin((x - z) * 3.3 - t * 2.3);
}
const SWELL_GLSL = `
  float swell(vec2 p, float t) {
    return 0.06 * sin(p.x * 0.9 + t * 1.1) + 0.045 * sin(p.y * 1.3 - t * 0.9)
      + 0.025 * sin((p.x + p.y) * 2.1 + t * 1.7) + 0.012 * sin((p.x - p.y) * 3.3 - t * 2.3);
  }`;

function stripes(red) {
  const c = document.createElement('canvas');
  c.width = 4; c.height = 14 * 32;
  const g = c.getContext('2d');
  for (let i = 0; i < 14; i++) { g.fillStyle = i % 2 ? red : '#ffffff'; g.fillRect(0, i * 32, 4, 32); }
  const t = new CanvasTexture(c);
  t.colorSpace = SRGBColorSpace;
  t.anisotropy = 4;
  return t;
}

// The mascot, part for part as Design/render-mascot.swift builds it for the app icon.
function mascot() {
  const cream = '#faf2e3', red = '#e64d45', blush = '#f79994', ink = '#17171c', yellow = '#ffd14d';
  const group = new Group();
  const body = new Mesh(new RoundedBoxGeometry(2.2, 1.8, 1.9, 10, 0.8), clay(cream));
  body.castShadow = body.receiveShadow = true;
  group.add(body);

  const eyes = [], sparkles = [];
  for (const x of [-0.42, 0.42]) {
    const e = new Mesh(new SphereGeometry(0.11, 32, 24), clay(ink, 0.35));
    e.position.set(x, 0.14, 0.93); e.scale.set(1, 1.15, 0.6);
    group.add(e); eyes.push(e);
    const h = new Mesh(new SphereGeometry(0.03, 16, 12), clay('#ffffff', 0.2));
    h.position.set(x + 0.035, 0.19, 0.99);
    group.add(h); sparkles.push(h);
  }
  for (const x of [-0.66, 0.66]) {
    const b = new Mesh(new SphereGeometry(0.17, 32, 16), clay(blush));
    b.position.set(x, -0.08, 0.9); b.scale.set(1.25, 0.7, 0.25);
    group.add(b);
  }
  // the "w" mouth
  const at = (x, y) => new Vector3(x, -0.1 + y, 0.935);
  const path = new CurvePath();
  path.add(new CubicBezierCurve3(at(-0.2, 0.04), at(-0.17, -0.11), at(-0.03, -0.11), at(0, 0.02)));
  path.add(new CubicBezierCurve3(at(0, 0.02), at(0.03, -0.11), at(0.17, -0.11), at(0.2, 0.04)));
  const mouthMat = clay(ink, 0.4);
  group.add(new Mesh(new TubeGeometry(path, 64, 0.027, 8, false), mouthMat));
  for (const p of [at(-0.2, 0.04), at(0.2, 0.04)]) {
    const cap = new Mesh(new SphereGeometry(0.027, 12, 8), mouthMat);
    cap.position.copy(p); group.add(cap);
  }

  // the beanie in lighthouse colours; the pompom is its lit lantern
  const hat = new Group();
  const cap = new Mesh(new SphereGeometry(1, 96, 64), new MeshStandardMaterial({ map: stripes(red), roughness: 0.9 }));
  cap.scale.set(0.9, 0.82, 0.86); cap.position.set(0, 0.5, 0);
  cap.castShadow = cap.receiveShadow = true;
  hat.add(cap);
  const brimTilt = new Group();
  brimTilt.position.set(0, 0.56, 0); brimTilt.scale.set(1.03, 1, 0.98); brimTilt.rotation.x = 0.1;
  const brim = new Mesh(new TorusGeometry(0.86, 0.13, 24, 96), clay(red));
  brim.rotation.x = Math.PI / 2; brim.castShadow = true;
  brimTilt.add(brim); hat.add(brimTilt);
  const pomMat = new MeshStandardMaterial({ color: yellow, roughness: 0.5, emissive: '#ffcc40', emissiveIntensity: 0.7 });
  const pom = new Mesh(new SphereGeometry(0.21, 32, 24), pomMat);
  pom.position.set(0, 1.38, 0);
  hat.add(pom);
  hat.rotation.set(0.1, 0, -0.14); hat.position.set(0.08, 0.02, 0.02);
  group.add(hat);

  const flippers = [];
  for (const s of [-1, 1]) {
    const f = new Mesh(new SphereGeometry(0.3, 32, 16), clay(cream));
    f.position.set(s * 1.1, -0.45, 0.25); f.scale.set(0.55, 0.32, 0.75); f.rotation.z = s * 0.5;
    f.castShadow = true;
    group.add(f); flippers.push(f);
  }

  // Squash and hop around the bottom of the body.
  const rig = new Group();
  group.position.y = 0.9;
  rig.add(group);
  return { rig, group, body, eyes, sparkles, pom, pomMat, flippers };
}

// A box (a dev box pierd runs on): a rounded block with a screen and one dot per agent.
function box(color, screen) {
  const group = new Group();
  const body = new Mesh(new RoundedBoxGeometry(1.15, 0.86, 0.86, 6, 0.22), clay(color, 0.75));
  body.castShadow = body.receiveShadow = true;
  group.add(body);
  const panel = new Mesh(new RoundedBoxGeometry(0.86, 0.42, 0.08, 4, 0.04), clay(screen, 0.45));
  panel.position.set(0, 0.06, 0.405);
  group.add(panel);
  const dots = [];
  for (let i = 0; i < 3; i++) {
    const mat = new MeshStandardMaterial({ color: STATE.idle, roughness: 0.35, emissive: STATE.idle, emissiveIntensity: 0 });
    const d = new Mesh(new SphereGeometry(0.068, 20, 14), mat);
    d.position.set(-0.24 + i * 0.24, 0.06, 0.45); d.scale.z = 0.55;
    group.add(d);
    dots.push({ mesh: d, mat, state: 'idle', since: 0 });
  }
  // a little antenna with a lamp, so a box reads as a machine from far away
  const mast = new Mesh(new CylinderGeometry(0.018, 0.018, 0.26, 8), clay('#2b2b33', 0.6));
  mast.position.set(0.36, 0.55, -0.1);
  group.add(mast);
  const lampMat = new MeshStandardMaterial({ color: '#ffffff', roughness: 0.4, emissive: STATE.working, emissiveIntensity: 0.6 });
  const lamp = new Mesh(new SphereGeometry(0.05, 16, 12), lampMat);
  lamp.position.set(0.36, 0.7, -0.1);
  group.add(lamp);
  return { group, body, dots, lampMat };
}

// A soft band of foam (or a ripple) lying on the water, from radius r0 out to r1.
function foamMaterial(opacity) {
  return new ShaderMaterial({
    transparent: true, depthWrite: false,
    uniforms: { uColor: { value: new Color('#ffffff') }, uOpacity: { value: opacity }, uMid: { value: 0.35 }, uWidth: { value: 0.22 } },
    vertexShader: `
      varying vec2 vP;
      void main() { vP = position.xy; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: `
      uniform vec3 uColor; uniform float uOpacity, uMid, uWidth;
      varying vec2 vP;
      void main() {
        float r = length(vP);
        float a = exp(-pow((r - uMid) / uWidth, 2.0)) * uOpacity;
        gl_FragColor = vec4(uColor, a);
        #include <colorspace_fragment>
      }`,
  });
}

// `manual`: no loop of its own; the caller renders the moment it wants with renderAt(t) (the launch film, frame by frame).
export function start(stage, { manual = false, asks = true, portrait: forcePortrait } = {}) {
  const motion = manual || !matchMedia('(prefers-reduced-motion: reduce)').matches;
  // the stylesheet's narrow layout (the words on top, the scene in a band of --band pixels under them)
  const narrow = matchMedia('(max-width: 900px)');
  const small = Math.min(innerWidth, innerHeight) < 600;

  const renderer = new WebGLRenderer({ antialias: true, alpha: false, powerPreference: 'high-performance', preserveDrawingBuffer: manual });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, small ? 1.6 : 2));
  renderer.toneMapping = NeutralToneMapping;
  renderer.outputColorSpace = SRGBColorSpace;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = PCFShadowMap;
  const canvas = renderer.domElement;
  canvas.setAttribute('aria-hidden', 'true');
  stage.prepend(canvas);
  canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); stage.classList.add('is-fallback'); });

  const scene = new Scene();
  scene.fog = new Fog('#ffffff', 16, 70);
  const pmrem = new PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

  const camera = new PerspectiveCamera(28, 1, 0.1, 400);

  // sky: a dome with the horizon's glow and the sun (or the moon) behind the scene
  const skyMat = new ShaderMaterial({
    side: BackSide, depthWrite: false,
    uniforms: {
      uTop: { value: new Color() }, uHorizon: { value: new Color() }, uSun: { value: new Color() },
      uSunDir: { value: new Vector3() }, uGlow: { value: 0.5 },
    },
    vertexShader: `
      varying vec3 vDir;
      void main() { vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: `
      uniform vec3 uTop, uHorizon, uSun, uSunDir; uniform float uGlow;
      varying vec3 vDir;
      void main() {
        vec3 d = normalize(vDir);
        vec3 col = mix(uHorizon, uTop, smoothstep(-0.02, 0.5, d.y));
        float s = max(dot(d, normalize(uSunDir)), 0.0);
        col += uSun * (pow(s, 48.0) * 0.6 + pow(s, 6.0) * 0.18) * uGlow;
        gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`,
  });
  const sky = new Mesh(new SphereGeometry(200, 48, 24), skyMat);
  sky.renderOrder = -1;
  scene.add(sky);

  // stars, for the night
  const starGeo = new BufferGeometry();
  const starPos = [];
  for (let i = 0; i < 320; i++) {
    const a = Math.random() * Math.PI * 2, el = MathUtils.lerp(0.06, 1.2, Math.pow(Math.random(), 0.7));
    starPos.push(Math.cos(a) * Math.cos(el) * 180, Math.sin(el) * 180, Math.sin(a) * Math.cos(el) * 180);
  }
  starGeo.setAttribute('position', new Float32BufferAttribute(starPos, 3));
  const starMat = new PointsMaterial({ color: '#fff6e6', size: 1.6, sizeAttenuation: false, transparent: true, opacity: 0, depthWrite: false });
  scene.add(new Points(starGeo, starMat));

  // the sea
  const seaMat = new ShaderMaterial({
    uniforms: {
      uTime: { value: 0 }, uDeep: { value: new Color() }, uShallow: { value: new Color() },
      uHorizon: { value: new Color() }, uSun: { value: new Color() }, uSunDir: { value: new Vector3() },
      uSpec: { value: 0.8 }, uFog: { value: new Vector2(16, 70) },
    },
    vertexShader: `
      uniform float uTime;
      varying vec3 vWorld; varying vec3 vNormal;
      ${SWELL_GLSL}
      void main() {
        vec3 p = position;
        float e = 0.05;
        float dx = (swell(p.xz + vec2(e, 0.0), uTime) - swell(p.xz - vec2(e, 0.0), uTime)) / (2.0 * e);
        float dz = (swell(p.xz + vec2(0.0, e), uTime) - swell(p.xz - vec2(0.0, e), uTime)) / (2.0 * e);
        p.y += swell(p.xz, uTime);
        vWorld = p;
        vNormal = normalize(vec3(-dx, 1.0, -dz));
        gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);
      }`,
    fragmentShader: `
      uniform vec3 uDeep, uShallow, uHorizon, uSun, uSunDir; uniform float uSpec; uniform vec2 uFog;
      varying vec3 vWorld; varying vec3 vNormal;
      void main() {
        vec3 n = normalize(vNormal);
        vec3 v = normalize(cameraPosition - vWorld);
        float facing = max(dot(n, v), 0.0);
        float fres = pow(1.0 - facing, 4.0);
        vec3 col = mix(uShallow, uDeep, smoothstep(0.15, 0.95, facing));
        col = mix(col, uHorizon, fres * 0.75);
        vec3 h = normalize(normalize(uSunDir) + v);
        float spec = pow(max(dot(n, h), 0.0), 220.0) * 1.4 + pow(max(dot(n, h), 0.0), 24.0) * 0.08;
        col += uSun * spec * uSpec;
        float d = length(cameraPosition - vWorld);
        col = mix(col, uHorizon, smoothstep(uFog.x, uFog.y, d));
        gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`,
  });
  const segs = small ? [150, 110] : [220, 160];
  const seaGeo = new PlaneGeometry(150, 110, segs[0], segs[1]);
  seaGeo.rotateX(-Math.PI / 2);
  seaGeo.translate(0, 0, -25);
  scene.add(new Mesh(seaGeo, seaMat));

  // light
  const hemi = new HemisphereLight('#ffffff', '#ffffff', 1);
  scene.add(hemi);
  const key = new DirectionalLight('#ffffff', 2);
  key.position.set(-4.5, 7, 6);
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  key.shadow.camera.left = -3; key.shadow.camera.right = 3; key.shadow.camera.top = 3.5; key.shadow.camera.bottom = -2;
  key.shadow.camera.near = 1; key.shadow.camera.far = 20;
  key.shadow.radius = 4; key.shadow.bias = -0.0008; key.shadow.normalBias = 0.02;
  scene.add(key);
  const rim = new DirectionalLight('#ffffff', 1);
  rim.position.set(3.5, 4, -6);
  scene.add(rim);

  // the mascot
  const m = mascot();
  scene.add(m.rig);
  key.target = m.rig;
  const lantern = new PointLight('#ffc95a', 2, 6, 2);
  scene.add(lantern);

  // the lighthouse beam from the lantern
  const beamGeo = new CylinderGeometry(0.05, 1.7, 13, 48, 1, true);
  beamGeo.translate(0, -6.5, 0);
  beamGeo.rotateZ(Math.PI / 2);
  const beamMat = new ShaderMaterial({
    transparent: true, depthWrite: false, blending: AdditiveBlending, side: DoubleSide,
    uniforms: { uColor: { value: new Color('#ffd36b') }, uIntensity: { value: 0 } },
    vertexShader: `
      varying float vAlong; varying float vFacing;
      void main() {
        vAlong = clamp(position.x / 13.0, 0.0, 1.0);
        vec3 n = normalize(normalMatrix * normal);
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vFacing = abs(dot(n, normalize(-mv.xyz)));
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      uniform vec3 uColor; uniform float uIntensity;
      varying float vAlong; varying float vFacing;
      void main() {
        float a = pow(1.0 - vAlong, 1.8) * pow(vFacing, 1.5) * uIntensity;
        gl_FragColor = vec4(uColor * a, a);
        #include <colorspace_fragment>
      }`,
  });
  const beam = new Group();
  const beamMesh = new Mesh(beamGeo, beamMat);
  beamMesh.rotation.z = -0.07;
  beam.add(beamMesh);
  scene.add(beam);

  // foam where the mascot meets the water
  const foam = new Mesh(new RingGeometry(0.4, 2.2, 64, 1), foamMaterial(0.55));
  foam.material.uniforms.uMid.value = 1.12; foam.material.uniforms.uWidth.value = 0.2;
  foam.rotation.x = -Math.PI / 2; foam.scale.set(1, 0.86, 1);
  scene.add(foam);

  // the boxes (placed on screen by frame(), so they keep clear of the words at any size)
  const boxes = [
    { ...box('#e64d45', '#26161a'), yaw: 0.25, phase: 0.0 },
    { ...box('#2a2a33', '#121217'), yaw: -0.45, phase: 1.7 },
    { ...box('#f4ead9', '#1d1d24'), yaw: -0.4, phase: 3.1 },
  ];
  for (const b of boxes) {
    b.x = 0; b.z = -4; b.scale = 1;
    b.group.rotation.y = b.yaw;
    b.foam = new Mesh(new RingGeometry(0.2, 1.5, 48, 1), foamMaterial(0.4));
    b.foam.material.uniforms.uMid.value = 0.66; b.foam.material.uniforms.uWidth.value = 0.14;
    b.foam.rotation.x = -Math.PI / 2;
    scene.add(b.group, b.foam);
  }
  const initial = [['working', 'working', 'done'], ['done', 'working', 'idle'], ['working', 'done', 'done']];
  boxes.forEach((b, i) => b.dots.forEach((d, j) => setDot(d, initial[i][j], 0)));

  // ripples: rings that spread from a box asking for you, or from the mascot when tapped
  const ripples = [];
  function ripple(x, z, size = 1) {
    const r = new Mesh(new RingGeometry(0.1, 1.6, 48, 1), foamMaterial(0));
    r.rotation.x = -Math.PI / 2;
    r.position.set(x, 0.02, z);
    r.userData = { born: clock, size };
    scene.add(r);
    ripples.push(r);
  }

  function setDot(d, state, now) {
    d.state = state; d.since = now;
    const c = new Color(STATE[state]);
    d.mat.color.copy(c); d.mat.emissive.copy(c);
  }

  // palette (follows the system's light/dark)
  const dark = matchMedia('(prefers-color-scheme: dark)');
  let pal;
  function applyPalette() {
    pal = PALETTES[dark.matches ? 'dark' : 'light'];
    const u = skyMat.uniforms;
    u.uTop.value.set(pal.skyTop); u.uHorizon.value.set(pal.skyHorizon); u.uSun.value.set(pal.sun);
    u.uSunDir.value.set(...pal.sunDir); u.uGlow.value = pal.glow;
    const s = seaMat.uniforms;
    s.uDeep.value.set(pal.seaDeep); s.uShallow.value.set(pal.seaShallow); s.uHorizon.value.set(pal.skyHorizon);
    s.uSun.value.set(pal.sun); s.uSunDir.value.set(...pal.sunDir); s.uSpec.value = pal.seaSpec;
    hemi.color.set(pal.hemiSky); hemi.groundColor.set(pal.hemiGround); hemi.intensity = pal.hemi;
    key.color.set(pal.key); key.intensity = pal.keyI;
    rim.color.set(pal.rim); rim.intensity = pal.rimI;
    scene.environmentIntensity = pal.env;
    scene.fog.color.set(pal.skyHorizon);
    starMat.opacity = pal.stars * 0.85;
    const foamColor = dark.matches ? '#9fc3e6' : '#ffffff';
    foam.material.uniforms.uColor.value.set(foamColor);
    for (const b of boxes) b.foam.material.uniforms.uColor.value.set(foamColor);
    if (ready && !running) render();
  }
  dark.addEventListener('change', applyPalette);

  // framing: the mascot right of the text on wide screens, under it on narrow ones
  const target = new Vector3(0, 1.05, 0);
  let portrait = false, distance = 9, elevation = 0.1, nx = 0, band = 400;
  const water = new Plane(new Vector3(0, 1, 0), 0), aim = new Raycaster(), hit = new Vector3(), spot = new Vector2();
  // Each box where it should appear on screen ([x, y] from -1 to 1, and its size): beside the mascot, never under
  // the words. Its place on the water is found from there.
  function placeBoxes() {
    const up = (px) => -1 + 2 * px / stage.clientHeight;   // px above the bottom, as a screen y
    const spots = portrait
      ? [[-0.68, up(band * 0.3), 0.78], [0.66, up(band * 0.24), 0.82], null]
      : [[Math.max(nx + 0.5, 0.86), 0.05, 0.8], [nx + 0.5, -0.36, 0.92], [nx + 0.33, -0.7, 0.66]];
    boxes.forEach((b, i) => {
      const at = spots[i];
      b.group.visible = b.foam.visible = !!at;
      if (!at) return;
      spot.set(Math.min(at[0], 0.88), at[1]);
      aim.setFromCamera(spot, camera);
      if (!aim.ray.intersectPlane(water, hit) || hit.distanceTo(camera.position) > 42) {
        aim.ray.at(42, hit); hit.y = 0;
      }
      b.x = hit.x; b.z = hit.z; b.scale = at[2];
      b.group.scale.setScalar(b.scale);
    });
  }
  function frame() {
    const w = stage.clientWidth, h = stage.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    const aspect = w / h;
    portrait = forcePortrait ?? narrow.matches;
    band = Math.min(parseFloat(getComputedStyle(stage).getPropertyValue('--band')) || 400, h * 0.7);
    camera.aspect = aspect;
    camera.fov = portrait ? 32 : 26;
    const tan = Math.tan(MathUtils.degToRad(camera.fov / 2));
    // how much of the height (and width) the mascot takes; on narrow screens it sits in the band under the words
    const fh = portrait ? band * 0.6 / h : 0.44, fw = portrait ? 0.58 : 0.27;
    distance = Math.max(2.4 / fh / (2 * tan), 2.8 / fw / (2 * tan * aspect));
    nx = portrait ? 0 : MathUtils.clamp(0.3 + (aspect - 1.3) * 0.1, 0.28, 0.46);
    const ny = portrait ? -1 + band * 0.98 / h : -0.12;
    camera.setViewOffset(w, h, -nx * w / 2, ny * h / 2, w, h);
    camera.updateProjectionMatrix();
    camera.position.set(target.x, target.y + Math.sin(elevation) * distance, target.z + Math.cos(elevation) * distance);
    camera.lookAt(target);
    camera.updateMatrixWorld();
    placeBoxes();
    if (ready && !running) render();
  }

  // pointer: the mascot looks where you point; a tap makes it hop
  const pointer = { x: 0, y: 0, active: false };
  const look = { yaw: 0, pitch: 0 };
  addEventListener('pointermove', (e) => {
    const r = stage.getBoundingClientRect();
    pointer.x = (e.clientX - r.left) / r.width * 2 - 1;
    pointer.y = -((e.clientY - r.top) / r.height * 2 - 1);
    pointer.active = true;
  }, { passive: true });
  const raycaster = new Raycaster();
  let hop = { at: -10, power: 0 }, flash = -10;
  stage.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect();
    const p = new Vector2((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height * 2 - 1));
    raycaster.setFromCamera(p, camera);
    if (raycaster.intersectObject(m.rig, true).length) {
      hop = { at: clock, power: 1 }; flash = clock;
      ripple(m.rig.position.x, m.rig.position.z, 1.4);
    }
  });

  // the bubble: an agent asks, and it answers itself after a moment (or when you tap Allow)
  const bubble = stage.querySelector('[data-hero-bubble]');
  let asking = null, nextAsk = motion && asks ? 2.2 : Infinity, askIndex = 0;
  function ask(now) {
    const shown = boxes.filter((x) => x.group.visible);
    const b = shown[[1, 2, 0][askIndex % 3] % shown.length];
    const d = b.dots[askIndex % 3];
    const q = ASKS[askIndex % ASKS.length];
    askIndex++;
    setDot(d, 'needs', now);
    asking = { box: b, dot: d, at: now, answerAt: now + 3.2, lastRing: -10 };
    if (bubble) {
      bubble.querySelector('[data-agent]').textContent = q.agent;
      bubble.querySelector('[data-cmd]').textContent = q.cmd;
      bubble.classList.remove('is-answered');
      bubble.classList.add('is-open');
    }
  }
  function answer(now) {
    if (!asking) return;
    setDot(asking.dot, 'working', now);
    hop = { at: now, power: 0.8 }; flash = now;
    if (bubble) {
      bubble.classList.add('is-answered');
      setTimeout(() => bubble.classList.remove('is-open'), 450);
    }
    asking = null;
    nextAsk = now + 3.4 + Math.random() * 1.6;
  }
  if (bubble) {
    bubble.addEventListener('pointerdown', (e) => { e.stopPropagation(); if (asking) answer(clock); });
  }
  if (!motion && bubble) {
    // still: one question, asked and left there
    ask(0);
    asking.answerAt = Infinity;
  }

  // the loop
  let clock = 0, last = performance.now(), running = false, visible = true, raf = 0, ready = false;
  const tmp = new Vector3(), toCam = new Vector3();

  function update(dt) {
    const t = clock;
    seaMat.uniforms.uTime.value = t;

    // the mascot floats, breathes and looks around
    const bob = swell(0, 0, t) * 0.8;
    m.rig.position.set(0, bob, 0);
    const sinceHop = t - hop.at;
    const hopY = sinceHop < 0.7 ? Math.sin(Math.min(sinceHop / 0.7, 1) * Math.PI) * 0.45 * hop.power : 0;
    const squash = sinceHop < 1.0 ? Math.sin(sinceHop * 14) * Math.exp(-sinceHop * 5) * 0.12 * hop.power : 0;
    m.group.position.y = 0.9 + hopY;
    const breathe = Math.sin(t * 2.1) * 0.012;
    m.rig.scale.set(1 + squash * 0.6, 1 - squash + breathe, 1 + squash * 0.6);

    let wantYaw = Math.sin(t * 0.35) * 0.18, wantPitch = 0.02;
    if (asking) {
      tmp.copy(asking.box.group.position).sub(m.rig.position);
      wantYaw = MathUtils.clamp(Math.atan2(tmp.x, tmp.z + 4), -0.6, 0.6);
      wantPitch = -0.05;
    } else if (pointer.active) {
      tmp.copy(target).project(camera);
      wantYaw = MathUtils.clamp((pointer.x - tmp.x) * 0.5, -0.5, 0.5);
      wantPitch = MathUtils.clamp(-(pointer.y - tmp.y) * 0.35, -0.22, 0.22);
    }
    const k = 1 - Math.exp(-dt * 4);
    look.yaw += (wantYaw - look.yaw) * k;
    look.pitch += (wantPitch - look.pitch) * k;
    m.group.rotation.set(look.pitch + Math.sin(t * 0.9) * 0.02, look.yaw, Math.sin(t * 1.1) * 0.035);
    m.flippers.forEach((f, i) => { f.rotation.z = (i ? 1 : -1) * (0.5 + Math.sin(t * 3 + i) * 0.12); });

    // blink every few seconds
    const blinkT = (t % 4.3);
    const lid = blinkT < 0.12 ? 0.12 : (t % 9.7 < 0.12 ? 0.12 : 1);
    m.eyes.forEach((e) => { e.scale.y = 1.15 * lid; });
    m.sparkles.forEach((s) => { s.visible = lid > 0.5; });

    // the lantern: a steady glow, brighter when it notices something
    const sinceFlash = t - flash;
    const pulse = 1 + Math.sin(t * 2.4) * 0.08 + (sinceFlash < 1.2 ? Math.exp(-sinceFlash * 3) * 1.6 : 0);
    m.pomMat.emissiveIntensity = pal.pomGlow * pulse;
    m.pom.getWorldPosition(tmp);
    lantern.position.copy(tmp);
    lantern.intensity = pal.lantern * pulse;
    beam.position.copy(tmp);
    beam.rotation.y = t * 0.55;
    // dim the beam when it points at the camera, so it never floods the view
    toCam.copy(camera.position).sub(tmp).setY(0).normalize();
    const facing = Math.cos(beam.rotation.y) * toCam.x - Math.sin(beam.rotation.y) * toCam.z;
    beamMat.uniforms.uIntensity.value = pal.beam * MathUtils.smoothstep(-facing, -0.97, -0.55) * (motion ? 1 : 0);

    foam.position.set(0, swell(0, 0, t) + 0.015, 0.05);
    foam.material.uniforms.uMid.value = 1.12 + Math.sin(t * 1.6) * 0.04;

    // the boxes bob on the swell
    for (const b of boxes) {
      const x = b.x, z = b.z;
      const y = swell(x, z, t + b.phase * 0.2);
      const dx = (swell(x + 0.1, z, t) - swell(x - 0.1, z, t)) / 0.2;
      const dz = (swell(x, z + 0.1, t) - swell(x, z - 0.1, t)) / 0.2;
      b.group.position.set(x, y + 0.26 * b.scale, z);
      b.group.rotation.set(-dz * 0.9, b.yaw + Math.sin(t * 0.3 + b.phase) * 0.06, dx * 0.9);
      b.foam.position.set(x, y + 0.012, z);
      b.foam.scale.setScalar(b.scale * (1 + Math.sin(t * 1.4 + b.phase) * 0.03));
      for (const d of b.dots) {
        let glow = 0.9;
        if (d.state === 'working') glow = 0.7 + Math.sin(t * 4 + d.mesh.position.x * 9) * 0.35;
        else if (d.state === 'needs') glow = (Math.sin((t - d.since) * 9) > -0.2) ? 1.8 : 0.4;
        else if (d.state === 'idle') glow = 0.05;
        d.mat.emissiveIntensity = glow;
      }
      b.lampMat.emissiveIntensity = 0.5 + Math.max(0, Math.sin(t * 2 + b.phase * 3)) * 0.9;
    }

    // agents finish work now and then, and start more
    if (motion && Math.random() < dt * 0.25) {
      const b = boxes[Math.floor(Math.random() * boxes.length)];
      const d = b.dots[Math.floor(Math.random() * 3)];
      if (!asking || d !== asking.dot) {
        if (d.state === 'working') setDot(d, 'done', t);
        else if (d.state === 'done' || d.state === 'idle') setDot(d, 'working', t);
      }
    }

    // questions
    if (!asking && t >= nextAsk) ask(t);
    if (asking) {
      if (motion && t - asking.lastRing > 0.9) { ripple(asking.box.x, asking.box.z, asking.box.scale); asking.lastRing = t; }
      if (t >= asking.answerAt) answer(t);
    }

    for (let i = ripples.length - 1; i >= 0; i--) {
      const r = ripples[i];
      const age = (t - r.userData.born) / 1.8;
      if (age >= 1) { scene.remove(r); r.geometry.dispose(); r.material.dispose(); ripples.splice(i, 1); continue; }
      const s = r.userData.size * (0.7 + age * 1.6);
      r.scale.set(s, s, s);
      r.position.y = swell(r.position.x, r.position.z, t) + 0.02;
      r.material.uniforms.uMid.value = 0.9;
      r.material.uniforms.uWidth.value = 0.06 + age * 0.08;
      r.material.uniforms.uOpacity.value = (1 - age) * 0.6;
    }

    // the camera drifts a little with the pointer and the scroll
    const scroll = Math.min(Math.max(-stage.getBoundingClientRect().top / Math.max(stage.clientHeight, 1), 0), 1);
    const orbit = (pointer.active ? pointer.x * 0.06 : 0) + Math.sin(t * 0.12) * 0.03;
    const el = elevation + scroll * 0.12 + (pointer.active ? -pointer.y * 0.015 : 0);
    camera.position.set(
      target.x + Math.sin(orbit) * Math.cos(el) * distance,
      target.y + Math.sin(el) * distance + scroll * 0.6,
      target.z + Math.cos(orbit) * Math.cos(el) * distance,
    );
    camera.lookAt(target);
  }

  function placeBubble() {
    if (!bubble || !asking) return;
    bubble.classList.toggle('is-banner', portrait);
    if (portrait) {
      // narrow screens: a notification banner at the top of the scene, as the iPhone shows it
      bubble.style.transform = `translate3d(${(stage.clientWidth / 2).toFixed(1)}px, ${(stage.clientHeight - band + 10).toFixed(1)}px, 0)`;
      return;
    }
    tmp.copy(asking.box.group.position);
    tmp.y += 0.75 * asking.box.scale;
    tmp.project(camera);
    const w = stage.clientWidth, half = Math.min(120, w / 2 - 8);
    const x = MathUtils.clamp((tmp.x + 1) / 2 * w, half + 8, w - half - 8), y = (1 - tmp.y) / 2 * stage.clientHeight;
    bubble.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
  }

  function render() {
    if (!pal) return;
    update(0);
    renderer.render(scene, camera);
    placeBubble();
  }

  function loop(now) {
    raf = 0;
    if (!running) return;
    // rAF's timestamp can be older than the moment the loop started: never step back in time
    const dt = MathUtils.clamp((now - last) / 1000, 0, 0.05);
    last = now;
    clock += dt;
    update(dt);
    renderer.render(scene, camera);
    placeBubble();
    raf = requestAnimationFrame(loop);
  }
  function setRunning() {
    const want = motion && visible && !document.hidden;
    if (want === running) return;
    running = want;
    if (running) { last = performance.now(); raf = requestAnimationFrame(loop); }
    else if (raf) { cancelAnimationFrame(raf); raf = 0; }
  }

  if (manual) {
    applyPalette();
    frame();
    ready = true;
    stage.classList.add('is-ready');
    return {
      renderAt(t) {
        const dt = MathUtils.clamp(t - clock, 0, 0.05);
        clock = t;
        update(dt);
        renderer.render(scene, camera);
        placeBubble();
      },
      hop(at, power = 1) { hop = { at, power }; flash = at; ripple(m.rig.position.x, m.rig.position.z, 1.4 * power); },
    };
  }

  new IntersectionObserver((entries) => {
    visible = entries[entries.length - 1].isIntersecting;
    setRunning();
  }).observe(stage);
  document.addEventListener('visibilitychange', setRunning);
  new ResizeObserver(frame).observe(stage);
  narrow.addEventListener('change', frame);

  if (!motion) clock = 2.6;
  applyPalette();
  frame();
  ready = true;
  render();
  stage.classList.remove('is-fallback');
  stage.classList.add('is-ready');
  setRunning();
}

// Last, once everything above is defined.
const stage = document.querySelector('[data-hero-stage]');
if (stage && !stage.hasAttribute('data-manual')) {
  try { start(stage); } catch (e) { stage.classList.add('is-fallback'); }
}
