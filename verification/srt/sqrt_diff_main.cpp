#include "Vsqrt_srt_diff_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
static uint64_t rng_state = 1;
static uint64_t rnd64(){uint64_t x=rng_state;x^=x>>12;x^=x<<25;x^=x>>27;rng_state=x;return x*0x2545F4914F6CDD1DULL;}
static uint32_t rnd32(){return (uint32_t)(rnd64()>>32);}
struct Op { uint64_t a; uint32_t rm; };
int main(int argc,char**argv){
  if(argc<3){fprintf(stderr,"usage: %s W_EXP W_MANT [N] [seed]\n",argv[0]);return 2;}
  const int wexp=atoi(argv[1]), wmant=atoi(argv[2]);
  const uint64_t N=(argc>3)?strtoull(argv[3],nullptr,0):500000;
  rng_state=(argc>4)?strtoull(argv[4],nullptr,0):0x123456789abcdefULL;
  const int w=1+wexp+wmant;
  const uint64_t mask=(w>=64)?~0ull:((1ull<<w)-1);
  const int emaxf=(1<<wexp)-2;
  const uint64_t mmask=(wmant>0)?((1ull<<wmant)-1):0;
  auto enc=[&](int sign,int exp,uint64_t mant)->uint64_t{
    int e=exp<0?0:(exp>emaxf?emaxf:exp);
    return ((uint64_t)(sign&1)<<(w-1))|((uint64_t)e<<wmant)|(mant&mmask);};
  const int bias=(1<<(wexp-1))-1, exp_all=(1<<wexp)-1;
  auto rand_op=[&]()->uint64_t{
    const uint32_t s=rnd32()&1; const uint32_t pick=rnd32()%100; int e;
    if(pick<8) return enc(s,exp_all,(rnd32()%3==0)?0:1);
    if(pick<16) return enc(s,0,(rnd32()%3==0)?0:rnd64());
    if(pick<30) e=0;
    else if(pick<45) e=1;
    else if(pick<60) e=bias+(int)(rnd32()%4)-2;
    else if(pick<80) e=(int)(rnd32()%(emaxf+1));
    else e=emaxf-(int)(rnd32()%4);
    return enc(s,e,rnd64());};
  Verilated::commandArgs(argc,argv);
  Vsqrt_srt_diff_top* t=new Vsqrt_srt_diff_top;
  t->clk=0;t->rst_n=0;t->start=0;t->a=0;t->rm=0;t->eval();
  for(int i=0;i<4;i++){t->clk=1;t->eval();t->clk=0;t->eval();}
  t->rst_n=1;t->eval();
  std::deque<Op> q; uint64_t mism=0;
  for(uint64_t i=0;i<N+64;i++){
    Op cur{0,0};
    if(i<N){cur.a=rand_op()&mask;cur.rm=rnd32()%5;q.push_back(cur);
            t->a=cur.a;t->rm=cur.rm;t->start=1;}
    else t->start=0;
    t->clk=1;t->eval();t->clk=0;t->eval();
    if(t->pipe_valid && !q.empty()){
      Op e=q.front();q.pop_front();
      t->a=e.a;t->rm=e.rm;t->eval();
      const uint64_t yp=t->y_pipe&mask, yc=t->y_comb&mask;
      if(yp!=yc||t->flags_pipe!=t->flags_comb){
        if(mism<10)fprintf(stderr,"MISMATCH start=%llu a=%0*llx rm=%u: srt y=%0*llx f=%02x, comb y=%0*llx f=%02x\n",
          (unsigned long long)i,(w+3)/4,(unsigned long long)e.a,e.rm,
          (w+3)/4,(unsigned long long)yp,t->flags_pipe,(w+3)/4,(unsigned long long)yc,t->flags_comb);
        mism++;}
      if(i<N){t->a=cur.a;t->rm=cur.rm;}
      t->eval();
    }
  }
  t->final(); delete t;
  fprintf(stderr,"SQRT_SRT W_EXP=%d W_MANT=%d N=%llu: %s (%llu mismatches)\n",
          wexp,wmant,(unsigned long long)N,mism?"FAIL":"PASS",(unsigned long long)mism);
  return mism?1:0;
}
