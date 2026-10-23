import sys, os, random, struct, subprocess, run_blit as rb
def run(r, c, show=True):
    rng=random.Random(0)
    mem=bytearray(rng.randrange(256) for _ in range(rb.REGION)); mem+=bytearray(rb.MEMB-rb.REGION)
    with open(os.path.join(rb.BUILD,"blit_init.hex"),"w") as f:
        for i in range(0,rb.REGION,4): f.write("%08x\n"%struct.unpack_from("<I",mem,i)[0])
    with open(os.path.join(rb.BUILD,"blit_cmds.txt"),"w") as f:
        for i in range(1,14): f.write("W %02x %08x\n"%(i*4,r[i]))
        f.write("W 38 %08x\n"%c)
    m=rb.Model(mem); m.run(r,c)
    p=subprocess.run(["vvp","-n",os.path.join(rb.BUILD,"tb_blit.vvp"),"+cmds=blit_cmds.txt","+init=blit_init.hex","+dump=blit_dump.hex"],cwd=rb.BUILD,capture_output=True,text=True)
    got=bytearray()
    for line in open(os.path.join(rb.BUILD,"blit_dump.hex")):
        line=line.strip()
        if not line or line[0] in "/@": continue
        got+=struct.pack("<I",int(line,16))
    bad=[i for i in range(rb.REGION) if got[i]!=m.m[i]]
    print(len(bad), [ (hex(b), got[b], m.m[b]) for b in bad[:6]])
def cmd(dst=0x40000,dstr=640,clip=(0,0,640,480),src=0x1000,sstr=256,dx=0,dy=0,w=16,h=1,col=0,u0=0,v0=0,du=0x10000,dv=0x10000,op=1,fl=0):
    r=[0]*14
    r[1]=dst; r[2]=dstr; r[3]=(clip[0]&0xffff)|(clip[1]<<16); r[4]=(clip[2]&0xffff)|(clip[3]<<16)
    r[5]=src; r[6]=sstr; r[7]=(dx&0xffff)|((dy&0xffff)<<16); r[8]=(w&0xffff)|((h&0xffff)<<16); r[9]=col
    r[10]=u0&0xffffffff; r[11]=v0&0xffffffff; r[12]=du&0xffffffff; r[13]=dv&0xffffffff
    return r, op|fl
