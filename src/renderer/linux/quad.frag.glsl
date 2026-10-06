#version 330 core
in vec2 uv; out vec4 fragColor;
uniform sampler2D image; uniform sampler1D gammaRamp;
uniform vec4 color; uniform int mode; uniform int present;
void main() {
 vec4 c=mode==1 ? color : texture(image,uv);
 if(present!=0) { ivec3 i=ivec3(clamp(c.rgb,0.0,1.0)*255.0+0.5); c=vec4(texelFetch(gammaRamp,i.r,0).r,texelFetch(gammaRamp,i.g,0).g,texelFetch(gammaRamp,i.b,0).b,1.0); }
 fragColor=c;
}
