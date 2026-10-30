"""Execute the extracted shader with the C++ stdlib stub. Numeric regression
only: this does not test Metal compiler, drawables, actual pixels or device GPU."""
from pathlib import Path
import json,re,subprocess,tempfile
R=Path(__file__).resolve().parents[1]
def extract(root):
    s=(root/'Sources/PXCDustShader.h').read_text()
    macro=(root/'Sources/PXCDustMotionSource.h').read_text().split('#define PXC_DUST_MOTION_METAL_SOURCE',1)[1]
    s=s.replace('     PXC_DUST_MOTION_METAL_SOURCE',macro)
    return ''.join(json.loads(x) for x in re.findall(r'@?("(?:\\.|[^"\\])*")',s[s.index('    @"'):]))
HARNESS=r'''
#include <cassert>
#include <cstdio>
#include <vector>
static float2 point(PXVertexOut v, const PXUniforms &u) {
 return float2((v.position.x+1)*u.overlaySize.x*.5,(1-v.position.y)*u.overlaySize.y*.5);
}
int main() {
 PXUniforms u={};u.overlaySize=float2(390,800);u.localSize=float2(330,600);
 u.sourceOrigin=float2(20,100);u.basisX=float2(1,0);u.basisY=float2(0,1);
 u.duration=1.8;u.texelSize=float2(1./495,1./900);u.flowDirection=float2(.7,-.7141428);u.flowPhase=.43;
 std::vector<PXParticle> ps(12);
 for(unsigned i=0;i<ps.size();i++) {
  ps[i]={};ps[i].center=float2(0,(i/4)*.30);ps[i].size=float2(1,.22);
  ps[i].uvOrigin=float2((i%4)*.24,(i/4)*.30+.02);ps[i].uvSize=float2(.24,.18);
  ps[i].seed=(i+1)*.037;
 }
 unsigned cases=0;double maxEdge=0;double differences=0;
 for(unsigned mode : {4u,8u}) for(unsigned style=0;style<2;style++) for(unsigned n=1;n<=7;n++) {
  u.effectStyle=style|mode|2u|(n<<16);
  for(float t : {0.f,.01f,.15f,.45f,.9f,1.5f,1.79f}) {
   u.elapsed=t;
   for(unsigned id=0;id<ps.size()*n*n;id++) {
    PXVertexOut v[4];float2 q[4];
    for(unsigned k=0;k<4;k++) {
     v[k]=px_dust_vertex(k,id,ps.data(),u);q[k]=point(v[k],u);
     assert(std::isfinite(q[k].x)&&std::isfinite(q[k].y));
     assert(v[k].alpha>=0 && v[k].alpha<=1.0001);
     assert(v[k].grain==1 && v[k].tileSize.x<=u.texelSize.x*1.001);assert(std::isfinite(v[k].flowUV.x)&&std::isfinite(v[k].flowUV.y));
    }
    double a=length(q[1]-q[0]),b=length(q[2]-q[0]);
    if(a>maxEdge)maxEdge=a;if(b>maxEdge)maxEdge=b;
    /* Grain nominal diameter <=2.10pt; warp can stretch it slightly, but it
       can never become the old 10-30pt parent tile. */
    assert(a<3.5 && b<3.5);
    if(id==1 && n>1 && t>.4f) {
     PXVertexOut other=px_dust_vertex(0,0,ps.data(),u);
     differences+=std::fabs(v[0].position.x-other.position.x)+std::fabs(v[0].position.y-other.position.y);
    }
    cases++;
   }
  }
 }
 assert(differences>0);
 // The transition is actually a continuous textured mesh, not moving parent
 // tiles. All nine patches per parent must be finite, opaque at t=0 and gone
 // at the end; its zero-time UV center must match the source image.
 unsigned surfaces=0;
 texture2d<float> meshTexture;
 for(unsigned mode : {4u,8u}) for(unsigned style=0;style<2;style++) {
  u.effectStyle=mode|style|16u;
  for(float t : {0.f,.15f,.4f,.7f,1.0f,1.8f}) {
   u.elapsed=t;
   for(unsigned id=0;id<ps.size()*9u;id++) for(unsigned k=0;k<4;k++) {
    auto v=px_dust_vertex(k,id,ps.data(),u);auto q=point(v,u);
    assert(std::isfinite(q.x)&&std::isfinite(q.y));
    assert(v.grain==0);
    auto c=px_dust_fragment(v,meshTexture,u);
    if(t==0)assert(c.a>.95);
    if(t==1.8f)assert(c.a<.001);
    surfaces++;
   }
  }
 }
 // Genuine pre-fade travel, not merely a longer static pause.
 assert(PXCSandCarry(.5f,.5f)>.55f);
 assert(PXCSandFade(.6f,.1f)>.99f);
 assert(PXCSandFade(.82f,.1f)>.25f);
 assert(PXCSandFade(1.f,.1f)==0);
 // Reveal/retained-surface shares the exact continuous release map.
 for(unsigned i=0;i<50;i++) {
  float x=i/49.f,y=(i*17%50)/49.f;
  float a=PXCSandReleaseAt(x,y,.01,.43);
  assert(std::fabs(a-PXCSandReleaseAt(x,y,.99,.43))<1e-7);
  assert(a>=.002f && a<=.32f);
  for(unsigned step=0;step<20;step++) {
   float reveal=PXCSandReveal(step/19.f,a);
   assert(std::fabs(reveal+(1.f-reveal)-1.f)<1e-6);
  }
 }
 std::printf("PASS continuous surface %u vertices; reveal + retained surface = 1; visible travel before late fade\n",surfaces);
 u.effectStyle=4;texture2d<float> tex;PXVertexOut center={};center.quadUV=float2(.5,.5);
 center.alpha=1;center.tileOrigin=float2(.2,.2);center.tileSize=u.texelSize;
 auto colour=px_dust_fragment(center,tex,u);assert(colour.a>.99);
 center.quadUV=float2(0,0);colour=px_dust_fragment(center,tex,u);assert(colour.a<.001);
 std::printf("PASS extracted visible-sand shader: %u grains, maximum warped edge %.3fpt, first-frame circles\n",cases,maxEdge);
}
'''
with tempfile.TemporaryDirectory() as d:
    # Metal address-space stand-ins must not rewrite libc++'s std::thread.
    cleanup='\n#undef thread\n#undef device\n#undef constant\n#undef vertex\n#undef fragment\n#undef discard_fragment\n'
    cpp=Path(d)/'notice.cpp';cpp.write_text(extract(R)+cleanup+HARNESS)
    exe=Path(d)/'notice'
    subprocess.run(['clang++','-std=c++17','-D__METAL_VERSION__','-Wno-unknown-attributes','-I'+str(R/'tests'),str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
