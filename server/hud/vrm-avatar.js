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
  canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;z-index:4';
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
    const gltf = await loader.loadAsync('./models/jarvis-avatar.vrm');
    vrm = gltf.userData.vrm;
    if(!vrm) throw new Error('no VRM payload');
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    // VRM 1.0 models face +Z; rotate so the avatar faces the camera (-Z)
    vrm.scene.rotation.y = Math.PI;
    scene.add(vrm.scene);
  }catch(err){
    console.warn('VRM load failed, falling back to static mask', err);
    canvas.remove(); renderer.dispose();
    return;                       // PNG stays visible
  }

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

  // idle breathing sway + state tilt + mouth lip-sync
  // NOTE: the model is rotated PI to face the camera, so positive yaw appears
  // as a turn to the viewer's LEFT — negate to make "listening" lean toward
  // the user's right (the mic side).
  const TILT = {listening:-.45, thinking:.32, tool:-.38, speaking:0, standby:0, error:0}; // radians of body yaw
  let curTilt = 0, t = 0;
  const clock = new THREE.Clock();
  const audioBuf = new Uint8Array(512);
  renderer.setAnimationLoop(()=>{
    const dt = clock.getDelta(); t += dt;
    const st = window.jarvisState || 'standby';

    // smooth yaw toward target tilt
    const want = TILT[st] ?? 0;
    curTilt += (want - curTilt) * Math.min(1, dt*3);
    const spine = vrm.humanoid.getNormalizedBoneNode('spine');
    const neck  = vrm.humanoid.getNormalizedBoneNode('neck');
    if(spine){ spine.rotation.y = curTilt * .7 + Math.sin(t*.6)*.05; }
    if(neck){ neck.rotation.y = curTilt * .3; }

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
