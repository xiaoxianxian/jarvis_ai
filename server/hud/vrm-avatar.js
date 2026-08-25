/* ===================== JARVIS VRM avatar (three.js + @pixiv/three-vrm) ===================== */
/* Replaces the static PNG in .character-rig with a live 3D avatar:
   - natural random blinking (expression preset "blink")
   - listening: leans/turns slightly toward the speaker (head+body yaw)
   - speaking: mouth opens with real audio RMS (expression preset "aa")
   Falls back to the static PNG if WebGL is unavailable or the model fails. */
(async function(){
  const rig = document.querySelector('.character-rig');
  const png = document.querySelector('.helmet-character');
  if(!rig || !png) return;
  const THREE = await import('three');   // via importmap
  let renderer;
  try{
    renderer = new THREE.WebGLRenderer({antialias:true, alpha:true});
  }catch(e){ return; }   // no WebGL: keep the PNG
  renderer.setPixelRatio(Math.min(window.devicePixelRatio||1, 1.5));
  renderer.setSize(2,2,false);
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const canvas = renderer.domElement;
  // No background clear color (transparent), and no outline/border: the HUD
  // look comes from the surrounding rings, a hard canvas edge reads as a
  // "white frame" screenshot artifact.
  canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;z-index:4;border:none;outline:none;background:transparent';
  rig.appendChild(canvas);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(22, 1, 0.1, 20);

  // lighting: cool key light matching the HUD cyan accent
  const amb = new THREE.AmbientLight(0x9fd8ff, 1.6);
  const key = new THREE.DirectionalLight(0x66e0ff, 1.4); key.position.set(-1, 2, 3);
  const rim = new THREE.DirectionalLight(0x00e5ff, 0.9); rim.position.set(2, 1, -3);
  scene.add(amb, key, rim);

  const { GLTFLoader } = await import('./vendor/GLTFLoader.js');
  const { VRMLoaderPlugin, VRMUtils } = await import('./vendor/three-vrm.module.min.js');
  const loader = new GLTFLoader();
  loader.register(p => new VRMLoaderPlugin(p));

  let vrm = null;
  try{
    // cache-bust: bump v= when swapping the model file (browsers hard-cache .vrm)
    const gltf = await loader.loadAsync('./models/jarvis-avatar.vrm?v=3');
    vrm = gltf.userData.vrm;
    if(!vrm) throw new Error('no VRM payload');
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    // Orientation: VRM1 models natively face +Z — i.e. straight at our camera.
    // Only legacy VRM0 models face away and need the PI flip; rotateVRM0()
    // applies it conditionally. (Blindly adding rotation.y=PI here turned the
    // avatar around — the infamous "Sadako" build.)
    VRMUtils.rotateVRM0(vrm);
    scene.add(vrm.scene);
  }catch(err){
    console.warn('VRM load failed, falling back to static mask', err);
    canvas.remove(); renderer.dispose();
    return;                       // PNG stays visible
  }

  // Relax the bind-pose T-pose into a natural A-pose: rotate upper arms
  // down by ~70deg (Z-axis, mirrored) and slightly forward. Without this
  // the avatar looks like it's doing jumping jacks in frame.
  for(const side of ['left','right']){
    const arm = vrm.humanoid.getNormalizedBoneNode(side+'UpperArm');
    if(arm){ arm.rotation.z = (side==='left' ? 1.22 : -1.22); arm.rotation.x = 0.12; }
    const fore = vrm.humanoid.getNormalizedBoneNode(side+'LowerArm');
    if(fore){ fore.rotation.z = (side==='left' ? 0.10 : -0.10); }
  }
  vrm.humanoid.update();

  // hide the static PNG once the model is actually on screen
  png.style.display = 'none';

  /* ---- framing: head-and-shoulders shot ---- */
  const head = vrm.humanoid.getNormalizedBoneNode('head');
  function frame(){
    const r = rig.getBoundingClientRect();
    renderer.setSize(r.width, r.height, false);
    camera.aspect = r.width / r.height;
    camera.updateProjectionMatrix();
    if(head){
      const hp = new THREE.Vector3(); head.getWorldPosition(hp);
      camera.position.set(hp.x, hp.y - 0.12, hp.z + 1.55);
      camera.lookAt(hp.x, hp.y - 0.04, hp.z);
    }
  }
  frame();
  new ResizeObserver(frame).observe(rig);

  /* ---- animation state (driven by the same signals as before) ---- */
  const expr = vrm.expressionManager;
  const blink = () => { try{expr.setValue('blink',1)}catch{} };
  const unblink = () => { try{expr.setValue('blink',0)}catch{} };

  // natural blink loop
  (function scheduleBlink(){
    if(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    blink();
    setTimeout(unblink, 90 + Math.random()*70);
    setTimeout(scheduleBlink, 2200 + Math.random()*3800);
  })();

  // idle breathing sway + state tilt + mouth lip-sync + mouse tracking
  // NOTE: the model is rotated PI to face the camera, so positive yaw appears
  // as a turn to the viewer's LEFT — negate to make "listening" lean toward
  // the user's right (the mic side).
  const TILT = {listening:-.45, thinking:.32, tool:-.38, speaking:0, standby:0, error:0}; // radians of body yaw
  let curTilt = 0, t = 0;
  const clock = new THREE.Clock();
  const audioBuf = new Uint8Array(512);

  /* ---- mouse tracking: eyes + head follow the cursor while it moves,
     ease back to center after the cursor rests ---- */
  const LOOK_MAX = .5;            // max head yaw (rad)
  const LOOK_MAX_PITCH = .25;     // max head pitch
  let lookX = 0, lookY = 0;       // smoothed -1..1
  let targetX = 0, targetY = 0;
  let lastMove = 0;
  addEventListener('mousemove', e => {
    const r = rig.getBoundingClientRect();
    // normalized offset from avatar center, clamped to [-1,1]
    const cx = r.left + r.width/2, cy = r.top + r.height/2;
    targetX = Math.max(-1, Math.min(1, (e.clientX - cx) / (r.width)));
    targetY = Math.max(-1, Math.min(1, -(e.clientY - cy) / (r.height)));   // screen Y is down
    lastMove = performance.now();
  });

  renderer.setAnimationLoop(()=>{
    const dt = clock.getDelta(); t += dt;
    const st = window.jarvisState || 'standby';

    // cursor idle >1s -> gaze returns to the user
    if(performance.now() - lastMove > 1000){ targetX = 0; targetY = 0; }
    lookX += (targetX - lookX) * Math.min(1, dt*6);
    lookY += (targetY - lookY) * Math.min(1, dt*6);

    // smooth yaw toward state tilt
    const want = TILT[st] ?? 0;
    curTilt += (want - curTilt) * Math.min(1, dt*3);
    const spine = vrm.humanoid.getNormalizedBoneNode('spine');
    const neck  = vrm.humanoid.getNormalizedBoneNode('neck');
    const head  = vrm.humanoid.getNormalizedBoneNode('head');
    if(spine){ spine.rotation.y = curTilt * .7 + Math.sin(t*.6)*.05; }
    // head carries most of the mouse-follow; neck a fraction
    if(neck){ neck.rotation.y = curTilt * .3 + lookX * LOOK_MAX * .35; }
    if(head){
      head.rotation.y = lookX * LOOK_MAX * .65;
      head.rotation.x = -lookY * LOOK_MAX_PITCH;   // three.js pitch: positive looks down
    }

    // subtle idle bob
    vrm.scene.position.y = Math.sin(t*1.4) * .006;

    // mouth: RMS of actually-played audio -> "aa" expression
    let rms = 0;
    const an = window.speechAnalyser;
    if(an){ an.getByteTimeDomainData(audioBuf);
      let s=0; for(let i=0;i<audioBuf.length;i++){const v=(audioBuf[i]-128)/128; s+=v*v;}
      rms = Math.sqrt(s/audioBuf.length); }
    const aa = st==='speaking' ? Math.min(.95, rms*14) : 0;
    try{ expr.setValue('aa', aa); }catch{}
    try{ expr.setValue('blinkLeft', st==='listening' ? .25 : 0); }catch{}   // slight attentive squint
    try{ expr.setValue('blinkRight', st==='listening' ? .25 : 0); }catch{}

    vrm.update(dt);
    renderer.render(scene, camera);
  });

  window.__vrmAvatar = vrm;   // debug handle
})();
